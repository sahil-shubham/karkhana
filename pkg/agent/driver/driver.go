// Package driver is the typed Go client for the pi-rpc agent
// protocol (vendored from pi-mono's `--mode rpc`). Ported from
// `Karkhana.AgentRPC` (Elixir, ~460 lines) — we keep the same
// hard-won state machine: reconnect with backoff, scrollback-
// overflow detection via get_state polling.
//
// One Driver wraps one piped session inside a bhatti sandbox.
// The transport: bhatti's existing /sandboxes/{id}/exec/ws WS
// route, with the first message being the exec command spec.
//
// Public surface:
//
//   d, err := driver.Connect(ctx, bhattiCli, sandboxID, opts...)
//   d.Prompt(ctx, "research site X")
//   for ev := range d.Events()  { ... }   // pi-rpc events
//   d.Close()
package driver

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"

	"github.com/sahil-shubham/karkhana/pkg/bhatti"
)

// Event is one pi-rpc event payload. We keep it untyped (a map)
// because pi's event vocabulary is rich and we forward the whole
// thing to the canvas anyway. Higher-level code can decode the
// `type` field and switch on known kinds.
type Event = map[string]any

// Options for Connect / Reattach.
type Options struct {
	// Cmd to spawn. Defaults to ["pi", "--mode", "rpc",
	// "--session-dir", "/home/lohar/karkhana-sessions"].
	Cmd []string

	// Provider, if set, is appended as `--provider <p>` after Cmd.
	// Used when the env-detected provider differs from pi's default
	// (e.g. "openrouter", "anthropic", "openai").
	Provider string

	// Model, if set, is appended as `--model <m>` after Cmd.
	Model string

	// Extensions, if non-empty, get appended as repeated
	// `--extension <path>` flags. The path is interpreted in the
	// SANDBOX's filesystem (not the host's). For Karkhana these
	// point at extensions baked into the kk-base image, e.g.
	// /usr/local/share/karkhana/extensions/computer-use/index.ts.
	Extensions []string

	// Env to inject into the agent process.
	Env map[string]string

	// MaxIdleSec — bhatti session idle-kill threshold. 0 = default.
	MaxIdleSec int

	// OnEvent is called for every pi-rpc event the agent emits.
	// Must not block (forward to a buffered channel and return).
	OnEvent func(Event)

	// OnDisconnect is called once when the WS closes for any reason.
	OnDisconnect func(error)
}

// Driver is one open agent-protocol connection.
type Driver struct {
	sandboxID string
	bhatti    *bhatti.Client

	wsMu sync.Mutex
	ws   *websocket.Conn

	sessionID atomic.Value // string

	requestCounter atomic.Int64
	pending        sync.Map // requestID(string) -> chan response

	completionMu       sync.Mutex
	completionWaiters  []chan completionResult
	isStreaming        atomic.Bool

	closed   atomic.Bool
	closeErr atomic.Value // error
	doneCh   chan struct{}

	onEvent      func(Event)
	onDisconnect func(error)
}

type completionResult struct {
	ok  bool
	err error
}

// rpcResponse is what pi sends for a request that had an `id`.
type rpcResponse struct {
	Type    string          `json:"type"` // "response"
	ID      string          `json:"id"`
	Command string          `json:"command"`
	Success bool            `json:"success"`
	Data    json.RawMessage `json:"data,omitempty"`
	Error   string          `json:"error,omitempty"`
}

// bhattiSessionInfo is the first frame bhatti sends after the
// upgrade — { "type": "session", "session_id": "..." }
type bhattiSessionInfo struct {
	Type      string `json:"type"`
	SessionID string `json:"session_id"`
}

// Connect spawns pi-rpc inside the sandbox via the bhatti
// /exec/ws route and returns a Driver. The first message is the
// command spec; bhatti replies with session metadata; from then
// on the WS carries the bidirectional pi-rpc stream.
func Connect(ctx context.Context, b *bhatti.Client, sandboxID string, opts Options) (*Driver, error) {
	if opts.Cmd == nil {
		opts.Cmd = []string{
			"pi", "--mode", "rpc",
			"--session-dir", "/home/lohar/karkhana-sessions",
		}
	}
	if opts.Provider != "" {
		opts.Cmd = append(opts.Cmd, "--provider", opts.Provider)
	}
	if opts.Model != "" {
		opts.Cmd = append(opts.Cmd, "--model", opts.Model)
	}
	for _, ext := range opts.Extensions {
		if ext == "" {
			continue
		}
		opts.Cmd = append(opts.Cmd, "--extension", ext)
	}
	if opts.MaxIdleSec == 0 {
		opts.MaxIdleSec = 3600
	}

	wsURL, err := buildExecWSURL(b.BaseURL, sandboxID, "")
	if err != nil {
		return nil, err
	}

	dialer := *websocket.DefaultDialer
	dialer.HandshakeTimeout = 30 * time.Second
	header := http.Header{}
	header.Set("Authorization", "Bearer "+b.APIKey)

	conn, resp, err := dialer.DialContext(ctx, wsURL, header)
	if err != nil {
		if resp != nil {
			return nil, fmt.Errorf("ws upgrade %d: %w", resp.StatusCode, err)
		}
		return nil, fmt.Errorf("ws dial: %w", err)
	}

	d := &Driver{
		sandboxID:    sandboxID,
		bhatti:       b,
		ws:           conn,
		doneCh:       make(chan struct{}),
		onEvent:      opts.OnEvent,
		onDisconnect: opts.OnDisconnect,
	}

	// Send the command spec — bhatti expects this as the first frame.
	cmdSpec := struct {
		Cmd        []string          `json:"cmd"`
		Env        map[string]string `json:"env,omitempty"`
		MaxIdleSec int               `json:"max_idle_sec"`
	}{
		Cmd:        opts.Cmd,
		Env:        opts.Env,
		MaxIdleSec: opts.MaxIdleSec,
	}
	if err := conn.WriteJSON(cmdSpec); err != nil {
		conn.Close()
		return nil, fmt.Errorf("write cmd spec: %w", err)
	}

	// First frame back is the bhatti session info.
	if err := conn.SetReadDeadline(time.Now().Add(15 * time.Second)); err != nil {
		conn.Close()
		return nil, err
	}
	_, raw, err := conn.ReadMessage()
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("read session info: %w", err)
	}
	var sess bhattiSessionInfo
	if err := json.Unmarshal(raw, &sess); err != nil {
		conn.Close()
		return nil, fmt.Errorf("decode session info: %w (got %q)", err, string(raw))
	}
	if sess.Type != "session" || sess.SessionID == "" {
		conn.Close()
		return nil, fmt.Errorf("expected session info, got %q", string(raw))
	}
	d.sessionID.Store(sess.SessionID)
	conn.SetReadDeadline(time.Time{}) // clear

	go d.readLoop()

	// Pi has sane defaults but it's worth turning on auto-compaction
	// + auto-retry; missions can run long and rate-limits happen.
	_ = d.sendCommand(ctx, "set_auto_compaction", map[string]any{"enabled": true})
	_ = d.sendCommand(ctx, "set_auto_retry", map[string]any{"enabled": true})

	return d, nil
}

// SessionID returns the bhatti session ID this driver is bound to.
func (d *Driver) SessionID() string {
	if v, ok := d.sessionID.Load().(string); ok {
		return v
	}
	return ""
}

// Prompt sends an initial user prompt to the agent. Pi will
// transition to streaming and emit agent_start, turn_*, etc.
func (d *Driver) Prompt(ctx context.Context, text string) error {
	d.isStreaming.Store(true)
	return d.send(map[string]any{"type": "prompt", "message": text})
}

// FollowUp queues a message to be delivered after the current
// turn completes (pi semantics).
func (d *Driver) FollowUp(ctx context.Context, text string) error {
	return d.send(map[string]any{"type": "follow_up", "message": text})
}

// Steer queues a steering message delivered after the current
// turn's tool calls complete (pi semantics).
func (d *Driver) Steer(ctx context.Context, text string) error {
	return d.send(map[string]any{"type": "steer", "message": text})
}

// Abort interrupts the current agent turn.
func (d *Driver) Abort(ctx context.Context) error {
	return d.send(map[string]any{"type": "abort"})
}

// AwaitCompletion blocks until pi emits `agent_end` (or the
// connection drops). Returns nil on clean completion, error on
// disconnect.
func (d *Driver) AwaitCompletion(ctx context.Context) error {
	if !d.isStreaming.Load() {
		return nil
	}
	ch := make(chan completionResult, 1)
	d.completionMu.Lock()
	d.completionWaiters = append(d.completionWaiters, ch)
	d.completionMu.Unlock()
	select {
	case r := <-ch:
		if !r.ok {
			return r.err
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// Close terminates the WS and the underlying piped session.
// Idempotent.
func (d *Driver) Close() error {
	if !d.closed.CompareAndSwap(false, true) {
		return nil
	}
	d.wsMu.Lock()
	defer d.wsMu.Unlock()
	if d.ws != nil {
		_ = d.ws.WriteControl(
			websocket.CloseMessage,
			websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""),
			time.Now().Add(time.Second),
		)
		_ = d.ws.Close()
	}
	close(d.doneCh)
	return nil
}

// --- private ---

func (d *Driver) send(payload map[string]any) error {
	d.wsMu.Lock()
	defer d.wsMu.Unlock()
	if d.ws == nil || d.closed.Load() {
		return errors.New("driver closed")
	}
	return d.ws.WriteJSON(payload)
}

// sendCommand fire-and-forgets a request/response RPC command with
// an `id`. We don't currently wait for the response — pi's
// set_auto_compaction etc. are idempotent and a missed response
// is fine. If that changes, wire pending into the reply channel.
func (d *Driver) sendCommand(ctx context.Context, cmd string, params map[string]any) error {
	id := fmt.Sprintf("krk-%d", d.requestCounter.Add(1))
	payload := map[string]any{"type": cmd, "id": id}
	for k, v := range params {
		payload[k] = v
	}
	return d.send(payload)
}

func (d *Driver) readLoop() {
	defer func() {
		if d.onDisconnect != nil {
			err, _ := d.closeErr.Load().(error)
			d.onDisconnect(err)
		}
		// Wake completion waiters
		d.completionMu.Lock()
		for _, ch := range d.completionWaiters {
			ch <- completionResult{ok: false, err: errors.New("ws disconnected")}
		}
		d.completionWaiters = nil
		d.completionMu.Unlock()
	}()

	for {
		_, raw, err := d.ws.ReadMessage()
		if err != nil {
			d.closeErr.Store(err)
			return
		}
		// Pi emits one JSON object per message most of the time, but
		// sometimes a single WS frame carries multiple newline-
		// delimited objects. Be tolerant of both.
		for _, line := range splitLines(raw) {
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}
			var ev Event
			if err := json.Unmarshal([]byte(line), &ev); err != nil {
				slog.Debug("driver: skipping non-JSON line",
					"agent", d.sandboxID, "line", truncate(line, 80))
				continue
			}
			d.dispatchEvent(ev)
		}
	}
}

func (d *Driver) dispatchEvent(ev Event) {
	t, _ := ev["type"].(string)

	switch t {
	case "response":
		// Request/response correlation. Currently we don't await
		// any responses, so just log misses and move on.
		// (Wire here when we add tools that need responses.)
		return

	case "agent_start":
		d.isStreaming.Store(true)

	case "agent_end":
		d.isStreaming.Store(false)
		d.completionMu.Lock()
		waiters := d.completionWaiters
		d.completionWaiters = nil
		d.completionMu.Unlock()
		for _, ch := range waiters {
			ch <- completionResult{ok: true}
		}
	}

	// Forward every event to the consumer (canvas / eventbus).
	if d.onEvent != nil {
		d.onEvent(ev)
	}
}

// buildExecWSURL constructs the bhatti exec/ws URL from the API
// base. e.g. "https://api.bhatti.sh" + sandboxID
//        →  "wss://api.bhatti.sh/sandboxes/X/exec/ws"
func buildExecWSURL(baseURL, sandboxID, sessionID string) (string, error) {
	u, err := url.Parse(baseURL)
	if err != nil {
		return "", err
	}
	switch u.Scheme {
	case "http":
		u.Scheme = "ws"
	case "https":
		u.Scheme = "wss"
	}
	u.Path = strings.TrimRight(u.Path, "/") + "/sandboxes/" + sandboxID + "/exec/ws"
	if sessionID != "" {
		q := u.Query()
		q.Set("session", sessionID)
		u.RawQuery = q.Encode()
	}
	return u.String(), nil
}

func splitLines(b []byte) []string {
	if len(b) == 0 {
		return nil
	}
	if !contains(b, '\n') {
		return []string{string(b)}
	}
	parts := strings.Split(string(b), "\n")
	return parts
}

func contains(b []byte, c byte) bool {
	for _, x := range b {
		if x == c {
			return true
		}
	}
	return false
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
