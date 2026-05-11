// Package bhatti is the typed Go client for bhatti's HTTP and
// WebSocket APIs. Ported from `Karkhana.Bhatti.Client` and
// `Karkhana.Bhatti.WS` (Elixir). Method names use v0.5 vocabulary
// (Suspend / Resume / Terminate / Checkpoint) even where bhatti's
// current URLs still use the older verbs (/stop, /start, DELETE);
// the URLs are an implementation detail of this client.
package bhatti

import "time"

// SandboxSpec is the create-sandbox request body. Mirrors bhatti's
// manifest fields. We accept v0.5-style additions (Agent, Job,
// Metadata) even before bhatti supports them — the client sends
// them and bhatti can ignore unknown fields until it doesn't.
type SandboxSpec struct {
	Name        string            `json:"name,omitempty"`
	Image       string            `json:"image"`
	CPUs        float32           `json:"cpus,omitempty"`
	MemoryMB    int               `json:"memory_mb,omitempty"`
	DiskSizeMB  int               `json:"disk_size_mb,omitempty"`
	TimeoutSecs int               `json:"timeout_secs,omitempty"`
	Env         map[string]string `json:"env,omitempty"`
	SecretNames []string          `json:"secret_names,omitempty"`
	Entrypoint  []string          `json:"entrypoint,omitempty"`

	// v0.5 additions; bhatti currently ignores until shipped
	Agent          *AgentSpec        `json:"agent,omitempty"`
	Job            *JobSpec          `json:"job,omitempty"`
	Metadata       map[string]string `json:"metadata,omitempty"`
	IdempotencyKey string            `json:"idempotency_key,omitempty"`

	// Legacy: keep_hot is being replaced by `name` presence at v0.5,
	// but bhatti today still honours it. Drop when bhatti renames.
	KeepHot bool `json:"keep_hot,omitempty"`

	// Persistent volumes — current bhatti API
	PersistentVolumes []VolumeMount `json:"persistent_volumes,omitempty"`
}

type VolumeMount struct {
	Name       string `json:"name"`
	Mount      string `json:"mount"`
	SizeMB     int    `json:"size_mb,omitempty"`
	AutoCreate bool   `json:"auto_create,omitempty"`
	ReadOnly   bool   `json:"read_only,omitempty"`
}

// AgentSpec — v0.5 manifest field. bhatti will read this once
// the agent-mode work lands; for now the Karkhana side sends it
// for forward-compatibility.
type AgentSpec struct {
	Cmd        []string          `json:"cmd"`
	Workdir    string            `json:"workdir,omitempty"`
	Env        map[string]string `json:"env,omitempty"`
	User       string            `json:"user,omitempty"`
	MaxIdleSec int               `json:"max_idle_sec,omitempty"`
	Protocol   string            `json:"protocol,omitempty"` // default "pi-rpc/v0"
	Outputs    []OutputSpec      `json:"outputs,omitempty"`
}

type JobSpec struct {
	Cmd        []string          `json:"cmd"`
	Workdir    string            `json:"workdir,omitempty"`
	Env        map[string]string `json:"env,omitempty"`
	User       string            `json:"user,omitempty"`
	Outputs    []OutputSpec      `json:"outputs,omitempty"`
	TimeoutSec int               `json:"timeout_sec,omitempty"`
	OnComplete string            `json:"on_complete,omitempty"`
	OnCrash    string            `json:"on_crash,omitempty"`
}

type OutputSpec struct {
	Path string `json:"path"`
	Kind string `json:"kind,omitempty"`
	Name string `json:"name"`
}

// Sandbox is the create-sandbox response (and list-element).
// Mirrors what `GET /sandboxes/:id` returns from bhatti today.
type Sandbox struct {
	ID         string    `json:"id"`
	Name       string    `json:"name,omitempty"`
	Image      string    `json:"image"`
	IP         string    `json:"ip,omitempty"`
	Status     string    `json:"status"`
	CPUs       float32   `json:"cpus,omitempty"`
	MemoryMB   int       `json:"memory_mb,omitempty"`
	DiskSizeMB int       `json:"disk_size_mb,omitempty"`
	Thermal    string    `json:"thermal,omitempty"` // hot|warm|cold (internal but exposed)
	URLs       []string  `json:"urls,omitempty"`    // published preview URLs
	CreatedAt  time.Time `json:"created_at"`
}

// PublishResult is what `POST /sandboxes/:id/publish` returns.
// bhatti has used both `url` and `preview_url` over time;
// CanonicalURL() prefers URL, falls back to PreviewURL.
type PublishResult struct {
	URL        string `json:"url"`
	PreviewURL string `json:"preview_url,omitempty"`
	Port       int    `json:"port,omitempty"`
	Alias      string `json:"alias,omitempty"`
}

// CanonicalURL returns the public hostname for the published port.
func (p *PublishResult) CanonicalURL() string {
	if p.URL != "" {
		return p.URL
	}
	return p.PreviewURL
}

// PortRule is one entry returned by `GET /sandboxes/:id/ports`.
type PortRule struct {
	ContainerPort int    `json:"container_port"`
	ProxyURL      string `json:"proxy_url,omitempty"`
	URL           string `json:"url,omitempty"`
	Alias         string `json:"alias,omitempty"`
}

// SessionInfo describes one tracked session inside a sandbox
// (from `GET /sandboxes/:id/sessions`).
type SessionInfo struct {
	SessionID string   `json:"session_id"`
	Argv      []string `json:"argv"`
	TTY       bool     `json:"tty"`
	Running   bool     `json:"running"`
	Attached  bool     `json:"attached"`
}

// ExecRequest is the body for `POST /sandboxes/:id/exec`.
// The current bhatti API takes `cmd` as the field name; we mirror.
type ExecRequest struct {
	Cmd        []string          `json:"cmd"`
	Env        map[string]string `json:"env,omitempty"`
	TimeoutSec int               `json:"timeout_sec,omitempty"`
	Detach     bool              `json:"detach,omitempty"`

	// v0.5 piped-session mode for agent transports. When Session=true
	// and TTY=false, lohar tracks this as a piped session with
	// scrollback — the path Karkhana.AgentRPC uses today.
	Session bool  `json:"session,omitempty"`
	TTY     *bool `json:"tty,omitempty"`
}

// ExecResult is what `POST /sandboxes/:id/exec` returns.
type ExecResult struct {
	ExitCode int    `json:"exit_code"`
	Stdout   string `json:"stdout"`
	Stderr   string `json:"stderr"`

	// When Session=true was sent, the response includes the session ID
	// of the long-running session (via stream-start metadata).
	SessionID string `json:"session_id,omitempty"`
}

// CheckpointSpec is the body for `POST /sandboxes/:id/checkpoint`.
type CheckpointSpec struct {
	Type     string            `json:"type,omitempty"` // "memory" | "filesystem"
	Name     string            `json:"name,omitempty"`
	Metadata map[string]string `json:"metadata,omitempty"`
}

type Snapshot struct {
	SnapshotID string    `json:"snapshot_id"`
	Type       string    `json:"type"`
	SizeBytes  int64     `json:"size_bytes,omitempty"`
	CreatedAt  time.Time `json:"created_at,omitempty"`
}

// RestoreSpec is one entry in `POST /snapshots/:id/restore`'s
// batch body. The multi-restore primitive lands in v0.5 of bhatti;
// this type is shaped today so Karkhana code can compile against
// it from day one.
type RestoreSpec struct {
	Name           string            `json:"name,omitempty"`
	Metadata       map[string]string `json:"metadata,omitempty"`
	Publish        []PublishRule     `json:"publish,omitempty"`
	IdempotencyKey string            `json:"idempotency_key,omitempty"`
}

type PublishRule struct {
	Port  int    `json:"port"`
	Alias string `json:"alias,omitempty"`
}

// PublicEvent mirrors the events bhatti broadcasts on /events.
// Karkhana subscribes (will subscribe) to these to know about
// sandbox lifecycle, agent crashes, etc.
type PublicEvent struct {
	ID        int64     `json:"id"`
	Kind      string    `json:"kind"`
	SandboxID string    `json:"sandbox_id,omitempty"`
	SessionID string    `json:"session_id,omitempty"`
	Payload   any       `json:"payload"`
	Ts        time.Time `json:"ts"`
}
