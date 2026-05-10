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
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

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

// Driver is one open agent-protocol connection. It runs over
// either a bhatti exec/ws WebSocket (workers) or a local stdio
// pipe (drivers running on the Karkhana host) — the transport
// is selected at construction time. See transport.go.
//
// AgentDriver below is the small interface that main.go holds;
// every method on Driver satisfies it.
type Driver struct {
	// transport-agnostic context. sandboxID is empty for host
	// drivers; bhatti is nil for host drivers.
	sandboxID string
	bhatti    *bhatti.Client

	txMu sync.Mutex
	tx   transport

	sessionID atomic.Value // string

	requestCounter atomic.Int64
	pending        sync.Map // requestID(string) -> chan response

	completionMu      sync.Mutex
	completionWaiters []chan completionResult
	isStreaming       atomic.Bool

	closed   atomic.Bool
	closeErr atomic.Value // error
	doneCh   chan struct{}

	onEvent      func(Event)
	onDisconnect func(error)
}

// AgentDriver is the surface main.go uses. Both bhatti-backed
// (workers) and host-stdio-backed (drivers) Drivers implement
// it; main.go holds them in a single map[string]AgentDriver.
type AgentDriver interface {
	SessionID() string
	IsStreaming() bool
	Prompt(ctx context.Context, text string) error
	FollowUp(ctx context.Context, text string) error
	Steer(ctx context.Context, text string) error
	Abort(ctx context.Context) error
	AwaitCompletion(ctx context.Context) error
	Close() error
}

var _ AgentDriver = (*Driver)(nil)

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

	wsTx, err := dialBhattiWS(ctx, b.BaseURL, b.APIKey, sandboxID)
	if err != nil {
		return nil, err
	}

	d := &Driver{
		sandboxID:    sandboxID,
		bhatti:       b,
		tx:           wsTx,
		doneCh:       make(chan struct{}),
		onEvent:      opts.OnEvent,
		onDisconnect: opts.OnDisconnect,
	}

	// Send the command spec — bhatti expects this as the first
	// frame on /exec/ws.
	cmdSpec := struct {
		Cmd        []string          `json:"cmd"`
		Env        map[string]string `json:"env,omitempty"`
		MaxIdleSec int               `json:"max_idle_sec"`
	}{
		Cmd:        opts.Cmd,
		Env:        opts.Env,
		MaxIdleSec: opts.MaxIdleSec,
	}
	if err := wsTx.WriteJSON(cmdSpec); err != nil {
		wsTx.Close()
		return nil, fmt.Errorf("write cmd spec: %w", err)
	}

	// First frame back is bhatti's session info. Read it directly
	// off the underlying conn so the deadline applies and we can
	// surface bhatti errors before the readLoop starts.
	if err := wsTx.conn.SetReadDeadline(time.Now().Add(15 * time.Second)); err != nil {
		wsTx.Close()
		return nil, err
	}
	_, raw, err := wsTx.conn.ReadMessage()
	if err != nil {
		wsTx.Close()
		return nil, fmt.Errorf("read session info: %w", err)
	}
	var sess bhattiSessionInfo
	if err := json.Unmarshal(raw, &sess); err != nil {
		wsTx.Close()
		return nil, fmt.Errorf("decode session info: %w (got %q)", err, string(raw))
	}
	if sess.Type != "session" || sess.SessionID == "" {
		wsTx.Close()
		return nil, fmt.Errorf("expected session info, got %q", string(raw))
	}
	d.sessionID.Store(sess.SessionID)
	wsTx.conn.SetReadDeadline(time.Time{}) // clear

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

// IsStreaming reports whether pi is currently mid-turn (i.e. the
// agent is working). Callers use this to decide between Prompt
// (idle — fresh turn) and Steer (mid-turn — inject guidance).
func (d *Driver) IsStreaming() bool {
	return d.isStreaming.Load()
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
//
// Race-safety: we re-check isStreaming AFTER acquiring the
// completion lock, otherwise an agent_end that fires between
// our initial Load() and our channel-registration would signal
// an empty waiter list and our channel would block forever.
// dispatchEvent's order is: Store(false) → lock → snapshot →
// clear → unlock → signal. So under the lock, if Load() is
// already false, the agent_end has happened (or is about to
// happen with no signal because we'd have to be in the snapshot
// to receive one). Either way, no need to wait.
func (d *Driver) AwaitCompletion(ctx context.Context) error {
	if !d.isStreaming.Load() {
		return nil
	}
	ch := make(chan completionResult, 1)
	d.completionMu.Lock()
	if !d.isStreaming.Load() {
		d.completionMu.Unlock()
		return nil
	}
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

// Close terminates the transport and the underlying pi session.
// Idempotent.
func (d *Driver) Close() error {
	if !d.closed.CompareAndSwap(false, true) {
		return nil
	}
	d.txMu.Lock()
	defer d.txMu.Unlock()
	if d.tx != nil {
		_ = d.tx.Close()
	}
	close(d.doneCh)
	return nil
}

// --- private ---

func (d *Driver) send(payload map[string]any) error {
	d.txMu.Lock()
	defer d.txMu.Unlock()
	if d.tx == nil || d.closed.Load() {
		return errors.New("driver closed")
	}
	return d.tx.WriteJSON(payload)
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
		var ev Event
		if err := d.tx.ReadJSON(&ev); err != nil {
			d.closeErr.Store(err)
			return
		}
		d.dispatchEvent(ev)
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
