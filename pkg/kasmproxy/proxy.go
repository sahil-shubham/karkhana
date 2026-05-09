// Package kasmproxy is a same-origin reverse proxy that fronts
// each worker's KasmVNC URL. Three responsibilities:
//
//  1. HTTP Basic auth injection. Bhatti's published KasmVNC URLs
//     require kasm_user:<per-sandbox-pass>. Modern browsers strip
//     `user:pass@host` from cross-origin subresource fetches
//     (WHATWG Fetch §authentication-entries), so iframe `src`
//     can't embed credentials. The proxy adds the auth header
//     server-side. Iframe loads /proxy/{agentID}/.
//
//  2. Origin rewrite. Cloudflare (which fronts bhatti's published
//     URLs) rejects WebSocket upgrades with cross-origin Origin
//     headers. We rewrite Origin to match the upstream host.
//
//  3. Path rewrite via injected shim. noVNC dials its WebSocket
//     at *root-absolute* `/websockify`, not relative to the page
//     URL. With the iframe at /proxy/agent_xxx/, root-absolute
//     bypasses our prefix and the WS hits Karkhana root instead
//     of the proxy. The fix: inject a tiny <script> into the
//     upstream HTML that monkey-patches window.WebSocket to
//     rewrite root paths to /proxy/agent_xxx/<path>. Surgical;
//     only affects the iframe content, never user code.
//
// We force HTTP/1.1 because WebSocket-over-HTTP/2 needs extended
// CONNECT (RFC 8441) which Cloudflare doesn't reliably proxy
// through to arbitrary upstreams.
package kasmproxy

import (
	"bytes"
	"compress/gzip"
	"crypto/tls"
	"encoding/base64"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Resolver returns the upstream KasmVNC URL + Basic-auth creds
// for a given agent ID. Implemented by the Karkhana server's
// agent state.
type Resolver interface {
	Resolve(agentID string) (upstream string, user string, pass string, ok bool)
}

// httpsHTTP1Transport is a Transport that explicitly disables
// HTTP/2. Required for WS upgrades to work through Cloudflare.
var httpsHTTP1Transport = &http.Transport{
	Proxy:                 http.ProxyFromEnvironment,
	ForceAttemptHTTP2:     false,
	MaxIdleConns:          100,
	IdleConnTimeout:       90 * time.Second,
	TLSHandshakeTimeout:   10 * time.Second,
	ExpectContinueTimeout: 1 * time.Second,
	TLSClientConfig: &tls.Config{
		NextProtos: []string{"http/1.1"},
	},
}

// Handler returns an http.HandlerFunc mounted at a prefix (e.g.
// "/proxy/"). Expects URLs of the shape /proxy/{agentID}/<rest>
// and forwards <rest> to the upstream KasmVNC URL with auth +
// Origin + path rewrites applied.
func Handler(prefix string, r Resolver) http.HandlerFunc {
	// One ReverseProxy per agent (cache key: agentID, since each
	// agent has a unique upstream). Each proxy's ModifyResponse
	// closure captures the agentID for the script-injection step.
	var (
		mu      sync.Mutex
		proxies = map[string]*httputil.ReverseProxy{}
	)

	getProxy := func(upstreamURL, agentID string) (*httputil.ReverseProxy, error) {
		mu.Lock()
		defer mu.Unlock()
		if p, ok := proxies[agentID]; ok {
			return p, nil
		}
		u, err := url.Parse(upstreamURL)
		if err != nil {
			return nil, err
		}
		p := httputil.NewSingleHostReverseProxy(u)
		p.Transport = httpsHTTP1Transport

		upstreamOrigin := u.Scheme + "://" + u.Host
		origDirector := p.Director
		p.Director = func(req *http.Request) {
			origDirector(req)
			req.Host = u.Host
			req.Header.Set("Origin", upstreamOrigin)
			// Discourage gzip so we can text-mangle HTML responses.
			// Cloudflare may still gzip; ModifyResponse handles that.
			req.Header.Set("Accept-Encoding", "identity")
			req.Header.Del("X-Forwarded-Host")
			req.Header.Del("X-Forwarded-For")
		}

		p.ModifyResponse = makeHTMLShimInjector(agentID, prefix)

		p.ErrorHandler = func(w http.ResponseWriter, req *http.Request, err error) {
			if isClientGone(err) {
				slog.Debug("kasmproxy client gone",
					"path", req.URL.Path, "err", err)
				return
			}
			slog.Warn("kasmproxy upstream error",
				"path", req.URL.Path, "err", err)
			http.Error(w, "kasmproxy: "+err.Error(), http.StatusBadGateway)
		}

		proxies[agentID] = p
		return p, nil
	}

	return func(w http.ResponseWriter, req *http.Request) {
		// /proxy/{agentID}/<rest>
		path := strings.TrimPrefix(req.URL.Path, prefix)
		parts := strings.SplitN(path, "/", 2)
		if len(parts) == 0 || parts[0] == "" {
			http.NotFound(w, req)
			return
		}
		agentID := parts[0]
		rest := "/"
		if len(parts) == 2 {
			rest = "/" + parts[1]
		}

		upstream, user, pass, ok := r.Resolve(agentID)
		if !ok || upstream == "" {
			slog.Debug("kasmproxy resolve miss", "agent", agentID)
			http.NotFound(w, req)
			return
		}

		isWS := strings.EqualFold(req.Header.Get("Upgrade"), "websocket")
		slog.Debug("kasmproxy",
			"agent", agentID,
			"method", req.Method,
			"path", rest,
			"ws", isWS)

		proxy, err := getProxy(upstream, agentID)
		if err != nil {
			http.Error(w, "kasmproxy: parse upstream: "+err.Error(), 502)
			return
		}

		req.URL.Path = rest
		auth := base64.StdEncoding.EncodeToString(
			[]byte(fmt.Sprintf("%s:%s", user, pass)))
		req.Header.Set("Authorization", "Basic "+auth)

		proxy.ServeHTTP(w, req)
	}
}

// makeHTMLShimInjector returns a ModifyResponse hook that injects
// a <script> tag immediately after <head> in HTML responses.
// The script monkey-patches window.WebSocket to rewrite root-
// absolute paths (which noVNC uses for /websockify) to be scoped
// under /proxy/<agentID>/.
//
// Non-HTML responses pass through unchanged. Gzipped responses
// are decompressed, modified, and re-served as identity (drop
// Content-Encoding). Content-Length is updated.
func makeHTMLShimInjector(agentID, proxyPrefix string) func(*http.Response) error {
	prefix := proxyPrefix + agentID + "/"
	shim := buildShim(prefix)
	shimBytes := []byte("\n<script>" + shim + "</script>\n")
	headTag := []byte("<head>")
	headTagAlt := []byte("<head ") // <head ...attrs...>

	return func(resp *http.Response) error {
		ct := resp.Header.Get("Content-Type")
		if !strings.HasPrefix(ct, "text/html") {
			return nil
		}

		// Read upstream body (decompress if gzip)
		body, err := readMaybeGzipped(resp)
		if err != nil {
			return err
		}

		// Find <head> (or <head ...>) and inject after it
		insertAt := bytes.Index(body, headTag)
		if insertAt >= 0 {
			insertAt += len(headTag)
		} else if i := bytes.Index(body, headTagAlt); i >= 0 {
			// <head with attrs> — find the closing >
			if end := bytes.IndexByte(body[i:], '>'); end > 0 {
				insertAt = i + end + 1
			}
		}
		var modified []byte
		if insertAt > 0 {
			modified = make([]byte, 0, len(body)+len(shimBytes))
			modified = append(modified, body[:insertAt]...)
			modified = append(modified, shimBytes...)
			modified = append(modified, body[insertAt:]...)
		} else {
			// No <head> found; prepend (unusual, but better than failing)
			modified = append(shimBytes, body...)
		}

		resp.Body = io.NopCloser(bytes.NewReader(modified))
		resp.ContentLength = int64(len(modified))
		resp.Header.Set("Content-Length", strconv.Itoa(len(modified)))
		resp.Header.Del("Content-Encoding") // we served identity now
		// Drop integrity-related caching headers — modified body must not
		// be cached as if it were the upstream original.
		resp.Header.Del("ETag")
		resp.Header.Del("Last-Modified")
		return nil
	}
}

// buildShim returns the JS source we inject. Kept compact, no
// dependencies, defensive against edge cases (URL parse errors,
// already-prefixed paths, blob/wss URLs we don't want to touch).
func buildShim(prefix string) string {
	// Single-line return so we don't accidentally break newline-
	// sensitive HTML parsers somewhere. JS minified by hand.
	return `(function(){var P=` + jsString(prefix) + `;` +
		`var W=window.WebSocket;if(!W)return;` +
		`function rewrite(u){try{` +
		`var x=new URL(u, document.location.href);` +
		`if(x.host!==document.location.host)return u;` +
		`if(x.pathname.indexOf(P)===0)return u;` +
		`x.pathname=P.replace(/\/$/,"")+x.pathname;` +
		`return x.toString();` +
		`}catch(e){return u;}}` +
		`function PWS(u,p){return new W(rewrite(u),p);}` +
		`PWS.prototype=W.prototype;` +
		`PWS.CONNECTING=W.CONNECTING;PWS.OPEN=W.OPEN;` +
		`PWS.CLOSING=W.CLOSING;PWS.CLOSED=W.CLOSED;` +
		`window.WebSocket=PWS;` +
		`})();`
}

// jsString returns a JS-safe string literal for s.
func jsString(s string) string {
	b := make([]byte, 0, len(s)+2)
	b = append(b, '"')
	for _, r := range s {
		switch r {
		case '"', '\\':
			b = append(b, '\\', byte(r))
		case '\n':
			b = append(b, '\\', 'n')
		case '\r':
			b = append(b, '\\', 'r')
		case '<':
			// </script> in a string would terminate the script tag.
			// Escape '<' to be safe.
			b = append(b, '\\', 'u', '0', '0', '3', 'c')
		default:
			b = append(b, []byte(string(r))...)
		}
	}
	b = append(b, '"')
	return string(b)
}

// readMaybeGzipped returns the response body, decompressing if
// Content-Encoding is gzip. Closes the original body.
func readMaybeGzipped(resp *http.Response) ([]byte, error) {
	defer resp.Body.Close()
	enc := strings.ToLower(strings.TrimSpace(resp.Header.Get("Content-Encoding")))
	if enc == "gzip" {
		gz, err := gzip.NewReader(resp.Body)
		if err != nil {
			return nil, fmt.Errorf("gzip reader: %w", err)
		}
		defer gz.Close()
		return io.ReadAll(gz)
	}
	return io.ReadAll(resp.Body)
}

func isClientGone(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "context canceled") ||
		strings.Contains(msg, "connection reset by peer") ||
		strings.Contains(msg, "broken pipe") ||
		strings.Contains(msg, "use of closed network connection")
}
