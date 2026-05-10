// Transport abstraction for the pi-rpc protocol. Lets the same
// Driver state machine drive a pi-rpc session over either:
//
//   1. bhatti's /sandboxes/:id/exec/ws WebSocket route — used for
//      WORKER agents that run pi inside a microVM (the v0 path);
//   2. plain stdio pipes to a local subprocess — used for DRIVER
//      agents that run pi on the Karkhana host (no sandbox).
//
// Both transports look the same from above: ReadJSON one frame
// at a time, WriteJSON one frame at a time, Close once.
//
// Why two transports: drivers need full Karkhana credentials to
// orchestrate workers, so they can't run in a sandbox without
// creating a credential cycle. Workers need a sandbox because
// they're untrusted/exposed. Same protocol, different containers.

package driver

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// transport is the duplex JSON-line connection a Driver runs
// over. ReadJSON returns one logical pi-rpc frame; WriteJSON
// sends one. Close cleanly tears down (idempotent).
type transport interface {
	ReadJSON(v any) error
	WriteJSON(v any) error
	Close() error
}

// --- WebSocket transport (bhatti exec/ws) ---

// wsTransport wraps a gorilla websocket.Conn. Pi-rpc emits one
// JSON object per WS frame most of the time, but some frames
// carry several newline-delimited objects; we buffer those so
// callers see one record per ReadJSON.
type wsTransport struct {
	conn *websocket.Conn

	pendingMu sync.Mutex
	pending   [][]byte // queued lines from prior multi-line frames
}

func (t *wsTransport) ReadJSON(v any) error {
	for {
		// Drain any buffered lines from a prior multi-line frame
		// before reading more.
		t.pendingMu.Lock()
		if len(t.pending) > 0 {
			line := t.pending[0]
			t.pending = t.pending[1:]
			t.pendingMu.Unlock()
			if tryDecodeJSON(line, v) {
				return nil
			}
			continue
		}
		t.pendingMu.Unlock()

		_, raw, err := t.conn.ReadMessage()
		if err != nil {
			return err
		}
		lines := bytes.Split(raw, []byte("\n"))
		first := lines[0]
		if len(lines) > 1 {
			t.pendingMu.Lock()
			t.pending = append(t.pending, lines[1:]...)
			t.pendingMu.Unlock()
		}
		if tryDecodeJSON(first, v) {
			return nil
		}
	}
}

// tryDecodeJSON tolerantly decodes one line into v. Returns
// true if it was a JSON object that decoded cleanly; false on
// empty / whitespace / non-JSON-object / malformed-JSON lines
// (pi occasionally interleaves diagnostic banners on the WS
// stream; the original driver loop logged+skipped these and we
// preserve that to avoid disconnecting the agent over a stray
// log line).
func tryDecodeJSON(line []byte, v any) bool {
	trimmed := bytes.TrimSpace(line)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		return false
	}
	return json.Unmarshal(trimmed, v) == nil
}

func (t *wsTransport) WriteJSON(v any) error {
	return t.conn.WriteJSON(v)
}

func (t *wsTransport) Close() error {
	_ = t.conn.WriteControl(
		websocket.CloseMessage,
		websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""),
		time.Now().Add(time.Second),
	)
	return t.conn.Close()
}

// dialBhattiWS opens the bhatti exec/ws WebSocket and returns a
// wsTransport ready for the bhatti session-info handshake.
func dialBhattiWS(ctx context.Context, baseURL, apiKey, sandboxID string) (*wsTransport, error) {
	wsURL, err := buildExecWSURL(baseURL, sandboxID, "")
	if err != nil {
		return nil, err
	}
	dialer := *websocket.DefaultDialer
	dialer.HandshakeTimeout = 30 * time.Second
	header := http.Header{}
	header.Set("Authorization", "Bearer "+apiKey)
	conn, resp, err := dialer.DialContext(ctx, wsURL, header)
	if err != nil {
		if resp != nil {
			return nil, fmt.Errorf("ws upgrade %d: %w", resp.StatusCode, err)
		}
		return nil, fmt.Errorf("ws dial: %w", err)
	}
	return &wsTransport{conn: conn}, nil
}

// --- Stdio transport (local pi subprocess) ---

// stdioTransport drives a `pi --mode rpc` subprocess on the
// Karkhana host. Pi reads commands from stdin one JSON line at
// a time and writes events to stdout the same way.
//
// Exit handling: when pi exits cleanly, ReadJSON returns
// io.EOF; the Driver's readLoop translates that into
// onDisconnect. We also kill the process on Close.
type stdioTransport struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout *bufio.Reader

	writeMu   sync.Mutex
	closeOnce sync.Once
}

func (t *stdioTransport) ReadJSON(v any) error {
	for {
		line, err := t.stdout.ReadBytes('\n')
		if err != nil {
			if len(bytes.TrimSpace(line)) == 0 {
				return err
			}
			// Try the line we got first; the next call will
			// re-encounter the EOF/error.
		}
		if tryDecodeJSON(line, v) {
			return nil
		}
		// Even if we got a partial-line + EOF, return EOF after
		// trying to decode.
		if err != nil {
			return err
		}
	}
}

func (t *stdioTransport) WriteJSON(v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	t.writeMu.Lock()
	defer t.writeMu.Unlock()
	_, err = t.stdin.Write(b)
	return err
}

func (t *stdioTransport) Close() error {
	t.closeOnce.Do(func() {
		_ = t.stdin.Close()
		// Give pi a beat to flush + exit cleanly.
		done := make(chan struct{})
		go func() {
			_ = t.cmd.Wait()
			close(done)
		}()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			_ = t.cmd.Process.Kill()
			<-done
		}
	})
	return nil
}

// spawnHostPi starts a `pi --mode rpc ...` subprocess on the
// Karkhana host with the given argv and environment, and returns
// a stdioTransport for it. Pi's stderr is forwarded to ours so
// crashes are visible in `karkhana.log`; tagging it would be
// nice but plain io.Copy is fine for v0.
func spawnHostPi(ctx context.Context, argv []string, env map[string]string) (*stdioTransport, error) {
	if len(argv) == 0 {
		return nil, errors.New("spawnHostPi: empty argv")
	}
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)

	// Environment: start from the host's own env (so pi can find
	// node, npm, locale settings) and overlay the per-driver
	// additions (KARKHANA_DRIVER_TOKEN, OPENROUTER_API_KEY, …).
	cmd.Env = os.Environ()
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("stdin pipe: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("stdout pipe: %w", err)
	}
	// Forward stderr verbatim to ours — pi prints diagnostics there
	// and we want them in the karkhana log when something breaks.
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, fmt.Errorf("stderr pipe: %w", err)
	}
	go func() { _, _ = io.Copy(prefixWriter{prefix: "[host-pi] ", w: os.Stderr}, stderr) }()

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start pi: %w", err)
	}
	return &stdioTransport{
		cmd:    cmd,
		stdin:  stdin,
		stdout: bufio.NewReaderSize(stdout, 256*1024),
	}, nil
}

// prefixWriter prepends a tag to each line — used to tag the
// host-pi process's stderr in our combined log.
type prefixWriter struct {
	prefix string
	w      io.Writer
	buf    []byte
}

func (p prefixWriter) Write(b []byte) (int, error) {
	for _, line := range strings.SplitAfter(string(b), "\n") {
		if line == "" {
			continue
		}
		_, _ = p.w.Write([]byte(p.prefix + line))
	}
	return len(b), nil
}
