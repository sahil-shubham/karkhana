// Package store is Karkhana's SQLite-backed persistence layer.
//
// One file (`karkhana.db`), three tables: missions, agents,
// events. WAL mode for write throughput; pure-Go SQLite driver
// (modernc.org/sqlite) so no CGO at build time.
//
// We chose plain `database/sql` over sqlc for v0: the schema is
// small enough that codegen overhead isn't worth the typing
// benefit. Migration to sqlc later is mechanical.
//
// Write-through model: every mutation hits the DB synchronously
// BEFORE fanning to the in-memory caches and the WS event bus.
// On startup, hydrate the caches from the DB and reattach to
// any running agents (driver pi processes are re-spawned with
// pi's --continue flag; worker pi-rpc sessions inside bhatti
// sandboxes are reattached via session_id="s1").
package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	_ "modernc.org/sqlite"

	"github.com/sahil-shubham/karkhana/pkg/mission"
)

// Store is the typed wrapper around our SQLite database. Safe
// for concurrent use; the sql.DB connection pool handles the
// locking under WAL.
type Store struct {
	db *sql.DB
}

// Open opens (or creates) the SQLite database at path and runs
// pending migrations. WAL + foreign keys are enabled via DSN
// pragmas so they persist on every connection.
func Open(path string) (*Store, error) {
	// modernc.org/sqlite supports `_pragma=...` repeated in DSN.
	dsn := path +
		"?_pragma=journal_mode(wal)" +
		"&_pragma=foreign_keys(on)" +
		"&_pragma=busy_timeout(5000)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	// SQLite is fine with a small pool; concurrent writers serialize
	// at the WAL level anyway.
	db.SetMaxOpenConns(8)
	db.SetMaxIdleConns(4)
	if err := db.PingContext(context.Background()); err != nil {
		db.Close()
		return nil, fmt.Errorf("ping sqlite: %w", err)
	}
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}
	return s, nil
}

// Close closes the underlying database connection.
func (s *Store) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

// DB returns the raw *sql.DB. Mostly for tests.
func (s *Store) DB() *sql.DB { return s.db }

// migrate creates tables if they don't exist. v0 = idempotent
// CREATE IF NOT EXISTS only; if the schema needs to evolve, we
// add a `schema_migrations` table later. Karkhana is single-
// host, single-DB; full migrations are overkill at v0.
func (s *Store) migrate() error {
	const schema = `
CREATE TABLE IF NOT EXISTS missions (
    id              TEXT PRIMARY KEY,
    goal            TEXT NOT NULL,
    status          TEXT NOT NULL,
    driver_agent_id TEXT,
    created_by      TEXT NOT NULL,
    created_at      TEXT NOT NULL,
    completed_at    TEXT
);

CREATE INDEX IF NOT EXISTS idx_missions_status
    ON missions(status) WHERE status = 'running';

CREATE TABLE IF NOT EXISTS agents (
    id                       TEXT PRIMARY KEY,
    mission_id               TEXT NOT NULL,
    parent_agent_id          TEXT,

    role                     TEXT NOT NULL,
    spawn_kind               TEXT,

    bhatti_sandbox_id        TEXT,
    spawned_from_snapshot_id TEXT,
    kasmvnc_proxy_path       TEXT,
    agent_endpoint_url       TEXT,

    task                     TEXT,
    recipe                   TEXT,

    bhatti_session_id        TEXT,
    pi_session_file          TEXT,

    status                   TEXT NOT NULL,
    outcome                  TEXT,
    final_artifact_ids       TEXT,    -- json array
    final_assistant_text     TEXT,

    tokens_input             INTEGER DEFAULT 0,
    tokens_output            INTEGER DEFAULT 0,
    tokens_cache_read        INTEGER DEFAULT 0,
    cost_usd                 REAL DEFAULT 0,

    started_at               TEXT NOT NULL,
    terminated_at            TEXT,

    -- v0.6: durable canvas position (right-click drop point or
    -- operator-dragged). NULL falls back to auto-layout.
    canvas_x                 REAL,
    canvas_y                 REAL,

    FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_agents_mission ON agents(mission_id);
CREATE INDEX IF NOT EXISTS idx_agents_parent  ON agents(parent_agent_id);
CREATE INDEX IF NOT EXISTS idx_agents_status_running
    ON agents(status) WHERE status = 'running';

CREATE TABLE IF NOT EXISTS events (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    mission_id   TEXT NOT NULL,
    agent_id     TEXT,
    kind         TEXT NOT NULL,
    payload      TEXT NOT NULL,    -- json
    ts           TEXT NOT NULL,

    FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_events_mission_ts
    ON events(mission_id, ts);
CREATE INDEX IF NOT EXISTS idx_events_agent_ts
    ON events(agent_id, ts) WHERE agent_id IS NOT NULL;

-- v0.7: blackboard (per-mission shared scratchpad).
-- Append-only by design — every write_note from any agent
-- creates a new row. Concurrent writes don't collide because
-- they don't share row identity. Reads of "key=X" return ALL
-- entries for that key, oldest first.
CREATE TABLE IF NOT EXISTS notes (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    mission_id   TEXT NOT NULL,
    key          TEXT NOT NULL,
    content      TEXT NOT NULL,
    summary      TEXT,
    agent_id     TEXT,
    ts           TEXT NOT NULL,
    FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_notes_mission_key ON notes(mission_id, key);
CREATE INDEX IF NOT EXISTS idx_notes_mission_ts  ON notes(mission_id, id);

-- v0.7: typed mission outputs. v0 has one type (markdown:report)
-- and one artifact per mission, produced by driver.finish.
-- Multi-type / multi-artifact missions in v1.
CREATE TABLE IF NOT EXISTS artifacts (
    id           TEXT PRIMARY KEY,    -- art_<12-hex>
    mission_id   TEXT NOT NULL,
    type         TEXT NOT NULL,       -- markdown:report (v0.7)
    title        TEXT,
    content      TEXT NOT NULL,
    summary      TEXT,
    produced_by  TEXT,                -- agent_id (usually the driver)
    created_at   TEXT NOT NULL,
    FOREIGN KEY (mission_id) REFERENCES missions(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_artifacts_mission ON artifacts(mission_id);
`
	_, err := s.db.Exec(schema)
	return err
}

// --- helpers ---

// nullableString is what we store in TEXT columns that can be NULL.
// Empty string → NULL (matches our Go semantics: zero-value strings
// represent "absent").
func nullableString(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func nullableTime(t *time.Time) any {
	if t == nil || t.IsZero() {
		return nil
	}
	return t.UTC().Format(time.RFC3339Nano)
}

func nullableFloat(f *float64) any {
	if f == nil {
		return nil
	}
	return *f
}

func parseTime(s sql.NullString) time.Time {
	if !s.Valid || s.String == "" {
		return time.Time{}
	}
	if t, err := time.Parse(time.RFC3339Nano, s.String); err == nil {
		return t
	}
	if t, err := time.Parse(time.RFC3339, s.String); err == nil {
		return t
	}
	return time.Time{}
}

func parseTimePtr(s sql.NullString) *time.Time {
	t := parseTime(s)
	if t.IsZero() {
		return nil
	}
	return &t
}

// --- missions ---

// CreateMission inserts a new mission record. ID must be set.
// Returns nil if the mission already exists (UPSERT semantics —
// recovery may legitimately re-create rows after a hand-edit).
func (s *Store) CreateMission(ctx context.Context, m *mission.Mission) error {
	const q = `
INSERT INTO missions (id, goal, status, driver_agent_id, created_by, created_at, completed_at)
VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
    goal = excluded.goal,
    status = excluded.status,
    driver_agent_id = excluded.driver_agent_id,
    completed_at = excluded.completed_at`
	_, err := s.db.ExecContext(ctx, q,
		m.ID,
		m.Goal,
		m.Status,
		nullableString(m.DriverAgentID),
		m.CreatedBy,
		m.CreatedAt.UTC().Format(time.RFC3339Nano),
		nullableTime(m.CompletedAt),
	)
	return err
}

// UpdateMissionStatus is the common path for marking a mission
// done/abandoned without rewriting the whole row.
func (s *Store) UpdateMissionStatus(ctx context.Context, id, status string, completedAt *time.Time) error {
	const q = `UPDATE missions SET status = ?, completed_at = ? WHERE id = ?`
	_, err := s.db.ExecContext(ctx, q, status, nullableTime(completedAt), id)
	return err
}

// SetMissionDriver sets driver_agent_id post-creation (drivers
// are agents themselves, so we insert the mission first then the
// driver agent then back-fill this).
func (s *Store) SetMissionDriver(ctx context.Context, missionID, driverID string) error {
	const q = `UPDATE missions SET driver_agent_id = ? WHERE id = ?`
	_, err := s.db.ExecContext(ctx, q, driverID, missionID)
	return err
}

// GetMission fetches one mission by ID.
func (s *Store) GetMission(ctx context.Context, id string) (*mission.Mission, error) {
	const q = `
SELECT id, goal, status, driver_agent_id, created_by, created_at, completed_at
FROM missions WHERE id = ?`
	row := s.db.QueryRowContext(ctx, q, id)
	return scanMission(row)
}

// ListMissions returns all missions, newest first.
func (s *Store) ListMissions(ctx context.Context) ([]*mission.Mission, error) {
	const q = `
SELECT id, goal, status, driver_agent_id, created_by, created_at, completed_at
FROM missions ORDER BY created_at DESC`
	rows, err := s.db.QueryContext(ctx, q)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*mission.Mission
	for rows.Next() {
		m, err := scanMission(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// ListMissionsByStatus is the recovery path's primary query.
func (s *Store) ListMissionsByStatus(ctx context.Context, status string) ([]*mission.Mission, error) {
	const q = `
SELECT id, goal, status, driver_agent_id, created_by, created_at, completed_at
FROM missions WHERE status = ? ORDER BY created_at`
	rows, err := s.db.QueryContext(ctx, q, status)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*mission.Mission
	for rows.Next() {
		m, err := scanMission(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// DeleteMission removes the mission and (via FK cascade) all its
// agents and events.
func (s *Store) DeleteMission(ctx context.Context, id string) error {
	const q = `DELETE FROM missions WHERE id = ?`
	_, err := s.db.ExecContext(ctx, q, id)
	return err
}

type rowScanner interface {
	Scan(dest ...any) error
}

func scanMission(row rowScanner) (*mission.Mission, error) {
	var m mission.Mission
	var driverID, completedAt sql.NullString
	var createdAt sql.NullString
	if err := row.Scan(
		&m.ID, &m.Goal, &m.Status, &driverID,
		&m.CreatedBy, &createdAt, &completedAt,
	); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	m.DriverAgentID = driverID.String
	m.CreatedAt = parseTime(createdAt)
	m.CompletedAt = parseTimePtr(completedAt)
	return &m, nil
}

// --- agents ---

// UpsertAgent writes the agent (insert or replace). Karkhana
// mutates agents over time — sandbox_id arrives after sandbox
// boot, kasmvnc_proxy_path arrives after publish, status flips
// on completion. UPSERT keeps it simple; we always write the
// full row.
func (s *Store) UpsertAgent(ctx context.Context, a *mission.Agent) error {
	artifactJSON := ""
	if len(a.FinalArtifactIDs) > 0 {
		b, err := json.Marshal(a.FinalArtifactIDs)
		if err != nil {
			return fmt.Errorf("marshal artifacts: %w", err)
		}
		artifactJSON = string(b)
	}
	const q = `
INSERT INTO agents (
    id, mission_id, parent_agent_id,
    role, spawn_kind,
    bhatti_sandbox_id, spawned_from_snapshot_id, kasmvnc_proxy_path, agent_endpoint_url,
    task, recipe,
    bhatti_session_id, pi_session_file,
    status, outcome, final_artifact_ids, final_assistant_text,
    tokens_input, tokens_output, tokens_cache_read, cost_usd,
    started_at, terminated_at,
    canvas_x, canvas_y
) VALUES (
    ?, ?, ?,
    ?, ?,
    ?, ?, ?, ?,
    ?, ?,
    ?, ?,
    ?, ?, ?, ?,
    ?, ?, ?, ?,
    ?, ?,
    ?, ?
) ON CONFLICT(id) DO UPDATE SET
    parent_agent_id = excluded.parent_agent_id,
    role = excluded.role,
    spawn_kind = excluded.spawn_kind,
    bhatti_sandbox_id = excluded.bhatti_sandbox_id,
    spawned_from_snapshot_id = excluded.spawned_from_snapshot_id,
    kasmvnc_proxy_path = excluded.kasmvnc_proxy_path,
    agent_endpoint_url = excluded.agent_endpoint_url,
    task = excluded.task,
    recipe = excluded.recipe,
    bhatti_session_id = excluded.bhatti_session_id,
    pi_session_file = excluded.pi_session_file,
    status = excluded.status,
    outcome = excluded.outcome,
    final_artifact_ids = excluded.final_artifact_ids,
    final_assistant_text = excluded.final_assistant_text,
    tokens_input = excluded.tokens_input,
    tokens_output = excluded.tokens_output,
    tokens_cache_read = excluded.tokens_cache_read,
    cost_usd = excluded.cost_usd,
    terminated_at = excluded.terminated_at,
    canvas_x = excluded.canvas_x,
    canvas_y = excluded.canvas_y`
	_, err := s.db.ExecContext(ctx, q,
		a.ID, a.MissionID, nullableString(a.ParentAgentID),
		a.Role, nullableString(a.SpawnKind),
		nullableString(a.BhattiSandboxID), nullableString(a.SpawnedFromSnapshotID),
		nullableString(a.KasmVNCProxyPath), nullableString(a.AgentEndpointURL),
		nullableString(a.Task), nullableString(a.Recipe),
		nullableString(a.BhattiSessionID), nullableString(a.PiSessionFile),
		a.Status, nullableString(a.Outcome), nullableString(artifactJSON),
		nullableString(a.FinalAssistantText),
		a.TokensInput, a.TokensOutput, a.TokensCacheRead, a.CostUSD,
		a.StartedAt.UTC().Format(time.RFC3339Nano),
		nullableTime(a.TerminatedAt),
		a.CanvasX, a.CanvasY,
	)
	return err
}

// GetAgent fetches one agent by ID.
func (s *Store) GetAgent(ctx context.Context, id string) (*mission.Agent, error) {
	const q = agentSelect + ` WHERE id = ?`
	row := s.db.QueryRowContext(ctx, q, id)
	return scanAgent(row)
}

// ListAllAgents returns every agent record. Used by the recovery
// hydrate path; for ongoing reads use ListAgentsByMission.
func (s *Store) ListAllAgents(ctx context.Context) ([]*mission.Agent, error) {
	rows, err := s.db.QueryContext(ctx, agentSelect+` ORDER BY started_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanAgents(rows)
}

// ListAgentsByMission returns all agents in the given mission.
func (s *Store) ListAgentsByMission(ctx context.Context, missionID string) ([]*mission.Agent, error) {
	rows, err := s.db.QueryContext(ctx, agentSelect+` WHERE mission_id = ? ORDER BY started_at`, missionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanAgents(rows)
}

// SetAgentCanvasPos persists a canvas position update (drag-to-
// move, or initial right-click drop). NULL for either coord
// resets to "auto-positioned".
func (s *Store) SetAgentCanvasPos(ctx context.Context, agentID string, x, y *float64) error {
	const q = `UPDATE agents SET canvas_x = ?, canvas_y = ? WHERE id = ?`
	_, err := s.db.ExecContext(ctx, q, nullableFloat(x), nullableFloat(y), agentID)
	return err
}

const agentSelect = `
SELECT
    id, mission_id, parent_agent_id,
    role, spawn_kind,
    bhatti_sandbox_id, spawned_from_snapshot_id, kasmvnc_proxy_path, agent_endpoint_url,
    task, recipe,
    bhatti_session_id, pi_session_file,
    status, outcome, final_artifact_ids, final_assistant_text,
    tokens_input, tokens_output, tokens_cache_read, cost_usd,
    started_at, terminated_at,
    canvas_x, canvas_y
FROM agents`

func scanAgent(row rowScanner) (*mission.Agent, error) {
	var a mission.Agent
	var parent, spawnKind, sandboxID, snapID, kasmPath, endpoint sql.NullString
	var task, recipe, sessionID, sessionFile sql.NullString
	var outcome, artifactJSON, finalText sql.NullString
	var startedAt, terminatedAt sql.NullString
	var canvasX, canvasY sql.NullFloat64

	if err := row.Scan(
		&a.ID, &a.MissionID, &parent,
		&a.Role, &spawnKind,
		&sandboxID, &snapID, &kasmPath, &endpoint,
		&task, &recipe,
		&sessionID, &sessionFile,
		&a.Status, &outcome, &artifactJSON, &finalText,
		&a.TokensInput, &a.TokensOutput, &a.TokensCacheRead, &a.CostUSD,
		&startedAt, &terminatedAt,
		&canvasX, &canvasY,
	); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}

	a.ParentAgentID = parent.String
	a.SpawnKind = spawnKind.String
	a.BhattiSandboxID = sandboxID.String
	a.SpawnedFromSnapshotID = snapID.String
	a.KasmVNCProxyPath = kasmPath.String
	a.AgentEndpointURL = endpoint.String
	a.Task = task.String
	a.Recipe = recipe.String
	a.BhattiSessionID = sessionID.String
	a.PiSessionFile = sessionFile.String
	a.Outcome = outcome.String
	a.FinalAssistantText = finalText.String
	a.StartedAt = parseTime(startedAt)
	a.TerminatedAt = parseTimePtr(terminatedAt)

	if canvasX.Valid {
		v := canvasX.Float64
		a.CanvasX = &v
	}
	if canvasY.Valid {
		v := canvasY.Float64
		a.CanvasY = &v
	}

	if artifactJSON.Valid && artifactJSON.String != "" {
		_ = json.Unmarshal([]byte(artifactJSON.String), &a.FinalArtifactIDs)
	}

	return &a, nil
}

func scanAgents(rows *sql.Rows) ([]*mission.Agent, error) {
	var out []*mission.Agent
	for rows.Next() {
		a, err := scanAgent(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}

// --- events ---

// AppendEvent persists one event record. Called from the bus
// publish() path so every event is durable.
func (s *Store) AppendEvent(ctx context.Context, e mission.Event) error {
	payloadJSON := []byte("null")
	if e.Payload != nil {
		b, err := json.Marshal(e.Payload)
		if err != nil {
			return fmt.Errorf("marshal payload: %w", err)
		}
		payloadJSON = b
	}
	// Mission-less events shouldn't happen but guard anyway —
	// FK will reject rows whose mission doesn't exist. Skip silently
	// if mission_id is empty.
	if strings.TrimSpace(e.MissionID) == "" {
		return nil
	}
	const q = `
INSERT INTO events (mission_id, agent_id, kind, payload, ts)
VALUES (?, ?, ?, ?, ?)`
	_, err := s.db.ExecContext(ctx, q,
		e.MissionID,
		nullableString(e.AgentID),
		e.Kind,
		string(payloadJSON),
		e.Ts.UTC().Format(time.RFC3339Nano),
	)
	return err
}

// RecentEventsByMission returns the last `limit` events for a
// mission, oldest-first (so callers can replay them in order).
func (s *Store) RecentEventsByMission(ctx context.Context, missionID string, limit int) ([]mission.Event, error) {
	if limit <= 0 {
		limit = 500
	}
	const q = `
SELECT id, mission_id, agent_id, kind, payload, ts
FROM events
WHERE mission_id = ?
ORDER BY id DESC
LIMIT ?`
	rows, err := s.db.QueryContext(ctx, q, missionID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []mission.Event
	for rows.Next() {
		ev, err := scanEvent(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, ev)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	// Reverse so callers iterate oldest-first.
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out, nil
}

// AllEventsForMission is the recovery-replay path: we replay
// every event so the canvas hydrates with the full timeline.
// For very long missions this may need a cap; v0 plays them all.
func (s *Store) AllEventsForMission(ctx context.Context, missionID string) ([]mission.Event, error) {
	const q = `
SELECT id, mission_id, agent_id, kind, payload, ts
FROM events
WHERE mission_id = ?
ORDER BY id`
	rows, err := s.db.QueryContext(ctx, q, missionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []mission.Event
	for rows.Next() {
		ev, err := scanEvent(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, ev)
	}
	return out, rows.Err()
}

func scanEvent(rows *sql.Rows) (mission.Event, error) {
	var ev mission.Event
	var agentID sql.NullString
	var ts sql.NullString
	var payload sql.NullString
	if err := rows.Scan(&ev.ID, &ev.MissionID, &agentID, &ev.Kind, &payload, &ts); err != nil {
		return ev, err
	}
	ev.AgentID = agentID.String
	ev.Ts = parseTime(ts)
	if payload.Valid && payload.String != "" {
		_ = json.Unmarshal([]byte(payload.String), &ev.Payload)
	}
	return ev, nil
}

// MaxEventID returns the highest event ID in the table — useful
// to seed the in-memory eventID counter on startup so newly
// published events keep increasing without colliding with replay.
func (s *Store) MaxEventID(ctx context.Context) (int64, error) {
	var id sql.NullInt64
	err := s.db.QueryRowContext(ctx, `SELECT MAX(id) FROM events`).Scan(&id)
	if err != nil {
		return 0, err
	}
	return id.Int64, nil
}

// --- notes (mission blackboard) ---

// Note is one blackboard entry. Append-only; concurrent writes
// to the same key by different agents produce separate rows.
type Note struct {
	ID        int64     `json:"id"`
	MissionID string    `json:"mission_id"`
	Key       string    `json:"key"`
	Content   string    `json:"content"`
	Summary   string    `json:"summary,omitempty"`
	AgentID   string    `json:"agent_id,omitempty"`
	Ts        time.Time `json:"ts"`
}

// AppendNote writes a new blackboard entry. Returns the new note's ID.
func (s *Store) AppendNote(ctx context.Context, n *Note) (int64, error) {
	if n.Ts.IsZero() {
		n.Ts = time.Now()
	}
	const q = `INSERT INTO notes (mission_id, key, content, summary, agent_id, ts)
               VALUES (?, ?, ?, ?, ?, ?)`
	res, err := s.db.ExecContext(ctx, q,
		n.MissionID, n.Key, n.Content,
		nullableString(n.Summary), nullableString(n.AgentID),
		n.Ts.UTC().Format(time.RFC3339Nano),
	)
	if err != nil {
		return 0, err
	}
	id, _ := res.LastInsertId()
	n.ID = id
	return id, nil
}

// ListNotes returns notes for a mission. If key is non-empty,
// filters to that key. Ordered by id (creation order).
func (s *Store) ListNotes(ctx context.Context, missionID, key string) ([]Note, error) {
	var (
		rows *sql.Rows
		err  error
	)
	if key == "" {
		rows, err = s.db.QueryContext(ctx,
			`SELECT id, mission_id, key, content, summary, agent_id, ts
             FROM notes WHERE mission_id = ? ORDER BY id`,
			missionID)
	} else {
		rows, err = s.db.QueryContext(ctx,
			`SELECT id, mission_id, key, content, summary, agent_id, ts
             FROM notes WHERE mission_id = ? AND key = ? ORDER BY id`,
			missionID, key)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Note
	for rows.Next() {
		var n Note
		var summary, agentID, ts sql.NullString
		if err := rows.Scan(&n.ID, &n.MissionID, &n.Key, &n.Content,
			&summary, &agentID, &ts); err != nil {
			return nil, err
		}
		n.Summary = summary.String
		n.AgentID = agentID.String
		n.Ts = parseTime(ts)
		out = append(out, n)
	}
	return out, rows.Err()
}

// NoteManifestEntry is one row of the manifest — a key with its
// entry count + latest contributor metadata. This is what agents
// see in their prompt (instead of full note content) to keep
// context windows tight.
type NoteManifestEntry struct {
	Key           string    `json:"key"`
	Count         int       `json:"count"`
	LatestSummary string    `json:"latest_summary,omitempty"`
	LatestAgent   string    `json:"latest_agent,omitempty"`
	LatestTs      time.Time `json:"latest_ts"`
}

// NoteManifest returns the per-key manifest for a mission.
func (s *Store) NoteManifest(ctx context.Context, missionID string) ([]NoteManifestEntry, error) {
	const q = `
SELECT key,
       COUNT(*) AS cnt,
       MAX(id) AS last_id
FROM notes
WHERE mission_id = ?
GROUP BY key
ORDER BY last_id DESC`
	rows, err := s.db.QueryContext(ctx, q, missionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	type lastEntry struct {
		key    string
		count  int
		lastID int64
	}
	var group []lastEntry
	for rows.Next() {
		var e lastEntry
		if err := rows.Scan(&e.key, &e.count, &e.lastID); err != nil {
			return nil, err
		}
		group = append(group, e)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	// For each, fetch the latest entry's summary + agent + ts.
	out := make([]NoteManifestEntry, 0, len(group))
	for _, g := range group {
		var summary, agent, ts sql.NullString
		err := s.db.QueryRowContext(ctx,
			`SELECT summary, agent_id, ts FROM notes WHERE id = ?`,
			g.lastID).Scan(&summary, &agent, &ts)
		if err != nil {
			return nil, err
		}
		out = append(out, NoteManifestEntry{
			Key:           g.key,
			Count:         g.count,
			LatestSummary: summary.String,
			LatestAgent:   agent.String,
			LatestTs:      parseTime(ts),
		})
	}
	return out, nil
}

// --- artifacts ---

// Artifact is a typed mission output. v0.7: one per mission,
// type="markdown:report", produced by the driver's finish tool.
type Artifact struct {
	ID         string    `json:"id"`
	MissionID  string    `json:"mission_id"`
	Type       string    `json:"type"`
	Title      string    `json:"title,omitempty"`
	Content    string    `json:"content"`
	Summary    string    `json:"summary,omitempty"`
	ProducedBy string    `json:"produced_by,omitempty"`
	CreatedAt  time.Time `json:"created_at"`
}

// CreateArtifact inserts an artifact row.
func (s *Store) CreateArtifact(ctx context.Context, a *Artifact) error {
	if a.CreatedAt.IsZero() {
		a.CreatedAt = time.Now()
	}
	const q = `INSERT INTO artifacts
               (id, mission_id, type, title, content, summary, produced_by, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
	_, err := s.db.ExecContext(ctx, q,
		a.ID, a.MissionID, a.Type,
		nullableString(a.Title), a.Content,
		nullableString(a.Summary), nullableString(a.ProducedBy),
		a.CreatedAt.UTC().Format(time.RFC3339Nano),
	)
	return err
}

// GetArtifact fetches an artifact by ID.
func (s *Store) GetArtifact(ctx context.Context, id string) (*Artifact, error) {
	const q = `SELECT id, mission_id, type, title, content, summary, produced_by, created_at
               FROM artifacts WHERE id = ?`
	row := s.db.QueryRowContext(ctx, q, id)
	var a Artifact
	var title, summary, producedBy, ts sql.NullString
	if err := row.Scan(&a.ID, &a.MissionID, &a.Type, &title,
		&a.Content, &summary, &producedBy, &ts); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	a.Title = title.String
	a.Summary = summary.String
	a.ProducedBy = producedBy.String
	a.CreatedAt = parseTime(ts)
	return &a, nil
}

// ListArtifacts returns all artifacts for a mission, newest first.
func (s *Store) ListArtifacts(ctx context.Context, missionID string) ([]Artifact, error) {
	const q = `SELECT id, mission_id, type, title, content, summary, produced_by, created_at
               FROM artifacts WHERE mission_id = ? ORDER BY created_at DESC`
	rows, err := s.db.QueryContext(ctx, q, missionID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Artifact
	for rows.Next() {
		var a Artifact
		var title, summary, producedBy, ts sql.NullString
		if err := rows.Scan(&a.ID, &a.MissionID, &a.Type, &title,
			&a.Content, &summary, &producedBy, &ts); err != nil {
			return nil, err
		}
		a.Title = title.String
		a.Summary = summary.String
		a.ProducedBy = producedBy.String
		a.CreatedAt = parseTime(ts)
		out = append(out, a)
	}
	return out, rows.Err()
}
