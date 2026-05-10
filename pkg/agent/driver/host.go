// ConnectHost — spawn a `pi --mode rpc` subprocess on the
// Karkhana host (NOT inside a bhatti sandbox) and wrap it in a
// Driver. Used for the per-mission *driver agent* in v0.6:
// the persistent conversational anchor the operator chats with,
// which orchestrates worker sandboxes via Karkhana's internal
// HTTP API.
//
// The same Driver methods (Prompt, Steer, Abort, Close) work
// here — only the transport differs (stdio pipes instead of a
// bhatti WebSocket). See transport.go for the abstraction.

package driver

import (
	"context"
	"errors"
	"fmt"
)

// HostOptions configures a host-side pi subprocess.
type HostOptions struct {
	// Argv to spawn. Required. Typically:
	//   ["pi", "--mode", "rpc",
	//    "--session-dir", "/tmp/karkhana-driver/<mission>",
	//    "--provider", "openrouter",
	//    "--model", "anthropic/claude-sonnet-4",
	//    "--extension", "/path/to/driver-tools/index.ts"]
	Argv []string

	// Env to layer on top of the host's environment. Typical
	// keys: OPENROUTER_API_KEY, KARKHANA_DRIVER_TOKEN,
	// KARKHANA_DRIVER_ID, KARKHANA_INTERNAL_URL.
	Env map[string]string

	// OnEvent is called for every pi event the driver emits.
	// Same contract as the bhatti Connect path.
	OnEvent func(Event)

	// OnDisconnect is called once when stdio EOFs / pi exits.
	OnDisconnect func(error)

	// SessionID, if non-empty, is recorded as the Driver's
	// SessionID(). Host drivers don't go through bhatti's
	// session_info handshake, so we synthesize one for parity
	// (e.g. "host-<mission_id>").
	SessionID string
}

// ConnectHost spawns the local pi subprocess and returns a
// Driver wrapping it. The Driver is ready to accept Prompt /
// Steer / etc. immediately — no handshake to wait for.
func ConnectHost(ctx context.Context, opts HostOptions) (*Driver, error) {
	if len(opts.Argv) == 0 {
		return nil, errors.New("ConnectHost: empty argv")
	}

	tx, err := spawnHostPi(ctx, opts.Argv, opts.Env)
	if err != nil {
		return nil, fmt.Errorf("spawn host pi: %w", err)
	}

	d := &Driver{
		// sandboxID stays empty — host drivers don't have one.
		// bhatti stays nil.
		tx:           tx,
		doneCh:       make(chan struct{}),
		onEvent:      opts.OnEvent,
		onDisconnect: opts.OnDisconnect,
	}
	if opts.SessionID != "" {
		d.sessionID.Store(opts.SessionID)
	}

	go d.readLoop()

	// Same defaults as the bhatti Connect path. Pi's auto-
	// compaction + auto-retry are both safe to enable for a
	// long-running driver and matter MORE for drivers (their
	// sessions can run for hours of operator chat).
	_ = d.sendCommand(ctx, "set_auto_compaction", map[string]any{"enabled": true})
	_ = d.sendCommand(ctx, "set_auto_retry", map[string]any{"enabled": true})

	return d, nil
}
