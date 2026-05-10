// Package mission defines the core entities Karkhana tracks:
// missions (operator intents), agents (driver + worker execution
// instances), and events (the typed observation stream).
//
// The agent tree (parent_agent_id) is the task tree. Drivers
// spawn workers; workers can fork into variants (v0.5+); both
// edges encoded via parent_agent_id.
package mission

import "time"

// Status enumerates the lifecycle states a mission or agent can
// be in. Same set of strings used in both contexts; the canvas
// uses agent status, the mission list uses mission status.
const (
	StatusRunning    = "running"
	StatusSuspended  = "suspended"
	StatusTerminated = "terminated"
	StatusFailed     = "failed"
	StatusDone       = "done"
	StatusAbandoned  = "abandoned"
)

// Role distinguishes the two kinds of agents. v0 ships only one
// of each (one driver per mission, N workers).
const (
	RoleDriver = "driver"
	RoleWorker = "worker"
)

// SpawnKind tracks how an agent came into existence. "root" is
// the first driver of a mission; "spawn" is a worker dispatched
// by a driver; "fork" is a Pattern-A snapshot fork (v0.5+).
const (
	SpawnRoot       = "root"
	SpawnSpawn      = "spawn"
	SpawnFork       = "fork"
	SpawnSubDriver  = "sub_driver"
)

// Mission is the operator's intent. One per top-level user request.
type Mission struct {
	ID            string     `json:"id"`              // msn_<12-hex>
	Goal          string     `json:"goal"`
	Status        string     `json:"status"`
	DriverAgentID string     `json:"driver_agent_id,omitempty"`
	CreatedBy     string     `json:"created_by"`
	CreatedAt     time.Time  `json:"created_at"`
	CompletedAt   *time.Time `json:"completed_at,omitempty"`
}

// Agent is an execution instance. Drivers and workers both live here.
type Agent struct {
	ID             string  `json:"id"`              // agent_<12-hex>
	MissionID      string  `json:"mission_id"`
	ParentAgentID  string  `json:"parent_agent_id,omitempty"`
	Role           string  `json:"role"`            // driver | worker
	SpawnKind      string  `json:"spawn_kind"`      // root | spawn | fork | sub_driver

	// Substrate handles. Drivers running on the Karkhana host have
	// no sandbox_id; workers always do.
	BhattiSandboxID        string `json:"bhatti_sandbox_id,omitempty"`
	SpawnedFromSnapshotID  string `json:"spawned_from_snapshot_id,omitempty"`
	// KasmVNCURL is the RAW upstream URL (Cloudflare-published
	// host with Basic auth). Server-side only — never sent to the
	// browser. The browser must talk to the same-origin proxy
	// path; if it had the upstream URL it could (a) trigger
	// Cloudflare's Basic-auth dialog and (b) bypass our auth
	// injection layer.
	KasmVNCURL string `json:"-"`

	// KasmVNCProxyPath is the same-origin path the iframe loads
	// (e.g. "/proxy/agent_abcd1234/"). This is what the frontend
	// consumes; we marshal it as `kasmvnc_url` so the JSON shape
	// matches what the iframe will actually use — the upstream
	// distinction stays a server-side internal.
	KasmVNCProxyPath string `json:"kasmvnc_url,omitempty"`

	KasmVNCUser string `json:"-"` // not exposed over the wire
	KasmVNCPass string `json:"-"`
	AgentEndpointURL       string `json:"agent_endpoint_url,omitempty"`

	// Task / config
	Task   string `json:"task,omitempty"`
	Recipe string `json:"recipe,omitempty"`

	// pi-rpc session info
	BhattiSessionID string `json:"bhatti_session_id,omitempty"`
	PiSessionFile   string `json:"pi_session_file,omitempty"`

	// Lifecycle
	Status               string   `json:"status"`
	Outcome              string   `json:"outcome,omitempty"`
	FinalArtifactIDs     []string `json:"final_artifact_ids,omitempty"`
	FinalAssistantText   string   `json:"final_assistant_text,omitempty"`

	// Accounting
	TokensInput     int64   `json:"tokens_input"`
	TokensOutput    int64   `json:"tokens_output"`
	TokensCacheRead int64   `json:"tokens_cache_read"`
	CostUSD         float64 `json:"cost_usd"`

	StartedAt    time.Time  `json:"started_at"`
	TerminatedAt *time.Time `json:"terminated_at,omitempty"`

	// Canvas position. v0.6: durable spatial coords (right-click
	// drop point or operator-dragged). nil falls back to the
	// canvas's auto-layout. Stored on agents.canvas_x/y in
	// SQLite; the API exposes them as `canvas_x` / `canvas_y`.
	CanvasX *float64 `json:"canvas_x,omitempty"`
	CanvasY *float64 `json:"canvas_y,omitempty"`
}

// Event is a typed observation. Source of truth for the canvas
// timeline, audit log, and replay. Kinds are namespaced:
//
//   mission.created, mission.completed
//   agent.spawned, agent.forked, agent.terminated, agent.outcome
//   driver.prompt_sent, driver.followup_sent
//   worker.event_received     (forwarded pi-rpc events)
//   worker.thinking, worker.tool_call, worker.message
//
// The canvas subscribes to these to update tile state.
type Event struct {
	ID        int64           `json:"id"`
	MissionID string          `json:"mission_id"`
	AgentID   string          `json:"agent_id,omitempty"`
	Kind      string          `json:"kind"`
	Payload   any             `json:"payload"`
	Ts        time.Time       `json:"ts"`
}
