// karkhana is the single-binary HTTP + WebSocket server.
//
// Iteration 2 (this revision): real agent integration.
// - POST /api/missions creates a real computer-tier sandbox via
//   bhatti, publishes its KasmVNC port (6080), installs pi, opens
//   an agent driver, sends the goal as the first prompt, forwards
//   pi events to the canvas event bus.
// - The canvas tile shows the live desktop + the agent's
//   reasoning/tool-call overlay.
// - Tile state survives Karkhana restarts: at startup we list
//   bhatti sandboxes tagged with our metadata and rebuild minimal
//   in-memory state (no event replay yet — those are gone).
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/sahil-shubham/karkhana/pkg/agent/driver"
	"github.com/sahil-shubham/karkhana/pkg/bhatti"
	"github.com/sahil-shubham/karkhana/pkg/canvas"
	"github.com/sahil-shubham/karkhana/pkg/config"
	"github.com/sahil-shubham/karkhana/pkg/eventbus"
	"github.com/sahil-shubham/karkhana/pkg/kasmproxy"
	"github.com/sahil-shubham/karkhana/pkg/mission"
	"github.com/sahil-shubham/karkhana/pkg/store"
)

const (
	// Computer tier publishes KasmVNC on this port (FACTS-verified).
	kasmVNCPort = 6080

	// Default worker resources for iteration 2. Computer tier with
	// XFCE+Chromium+pi needs at least these.
	defaultWorkerCPUs     = 2
	defaultWorkerMemoryMB = 4096

	// Auto-terminate workers after this idle period.
	defaultWorkerTimeoutSecs = 1800 // 30 min

	// pi-coding-agent npm package
	piPackage = "@mariozechner/pi-coding-agent"

	// Where pi stores session JSONL files inside the sandbox.
	piSessionDir = "/home/lohar/karkhana-sessions"
)

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))

	cfg, err := config.Load()
	if err != nil {
		slog.Error("config load failed", "err", err)
		os.Exit(1)
	}
	slog.Info("config loaded",
		"bhatti_url", cfg.BhattiURL,
		"token_prefix", cfg.BhattiToken[:min(15, len(cfg.BhattiToken))]+"...",
		"addr", cfg.Addr)

	bus := eventbus.New()
	defer bus.Close()
	bhattiCli := bhatti.New(cfg.BhattiURL, cfg.BhattiToken)

	// SQLite-backed persistence. Karkhana is amnesic without
	// this — missions / agents / events all live in this DB and
	// the in-memory maps are write-through caches.
	db, err := store.Open(cfg.DBPath)
	if err != nil {
		slog.Error("store open failed", "path", cfg.DBPath, "err", err)
		os.Exit(1)
	}
	defer db.Close()
	slog.Info("store opened", "path", cfg.DBPath)

	state := &serverState{
		bus:               bus,
		bhatti:            bhattiCli,
		store:             db,
		missions:          map[string]*mission.Mission{},
		agents:            map[string]*mission.Agent{},
		drivers:           map[string]driver.AgentDriver{},
		piProvider:        cfg.PiProvider,
		piModel:           cfg.PiModel,
		workerImage:       cfg.WorkerImage,
		piExtensions:      cfg.PiExtensions,
		driverToolsPath:   cfg.DriverToolsPath,
		driverSessionRoot: cfg.DriverSessionRoot,
		internalURL:       cfg.InternalURL,
		driverTokens:      map[string]string{},
		driverPendingAsk:  map[string]chan string{},
		timingLogged:      map[string]map[string]bool{},
		tickDispatchers:   map[string]*TickDispatcher{},
		ctx:               context.Background(),
	}

	// Seed the event ID counter from the persisted max so newly
	// published events keep monotonically increasing without
	// colliding with replayed history.
	if maxID, err := db.MaxEventID(context.Background()); err == nil {
		state.eventID = maxID
	} else {
		slog.Warn("max event id read failed (non-fatal)", "err", err)
	}
	if len(cfg.PiExtensions) > 0 {
		slog.Info("pi extensions enabled",
			"count", len(cfg.PiExtensions),
			"paths", cfg.PiExtensions)
	}
	slog.Info("pi provider resolved",
		"provider", cfg.PiProvider,
		"model", cfg.PiModel)
	slog.Info("worker image", "image", cfg.WorkerImage,
		"hint", "set KARKHANA_WORKER_IMAGE=kk-base after running scripts/bake-image.sh to skip pi install")

	// Smoke-test the bhatti connection at startup.
	smokeCtx, cancelSmoke := context.WithTimeout(context.Background(), 10*time.Second)
	if _, err := bhattiCli.ListSandboxes(smokeCtx); err != nil {
		cancelSmoke()
		slog.Error("bhatti auth smoke test failed", "err", err)
		slog.Info("hint: check ~/.bhatti/config.yaml or KARKHANA_BHATTI_TOKEN")
		os.Exit(1)
	}
	cancelSmoke()
	slog.Info("bhatti connection ok")

	// Hydrate from store + reattach to running agents.
	// recoverFromStore replaces v0.5's bhatti-scan-only recovery:
	// it reads missions/agents/events from SQLite, rebuilds the
	// caches, and re-spawns drivers / re-attaches workers for
	// anything still status='running'.
	go state.recoverFromStore()

	mux := http.NewServeMux()
	mux.HandleFunc("/api/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"status": "ok"})
	})
	mux.HandleFunc("/api/missions", state.handleMissions)
	mux.HandleFunc("/api/missions/", state.handleMissionByID)
	mux.HandleFunc("/api/agents", state.handleAgents)
	mux.HandleFunc("/api/agents/", state.handleAgentByID)
	mux.HandleFunc("/api/artifacts/", state.handleArtifactByID)
	mux.HandleFunc("/api/events", canvas.EventStreamHandler(bus, state))
	mux.HandleFunc("/proxy/", kasmproxy.Handler("/proxy/", state))
	// Driver-tool callbacks. Authed via per-driver bearer
	// tokens minted at driver-spawn time. Bound to localhost
	// only by virtue of running on the same host as the driver
	// pi subprocess that calls them.
	mux.HandleFunc("/internal/driver/", state.handleInternalDriver)

	handler := withCORS(mux)
	srv := &http.Server{Addr: cfg.Addr, Handler: handler}

	// Graceful shutdown.
	go func() {
		ch := make(chan os.Signal, 1)
		signal.Notify(ch, os.Interrupt, syscall.SIGTERM)
		<-ch
		slog.Info("shutting down")
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
	}()

	slog.Info("karkhana listening", "addr", cfg.Addr,
		"open", "http://localhost:5173 (vite)",
		"or", "http://localhost"+cfg.Addr)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		slog.Error("server error", "err", err)
		os.Exit(1)
	}
}

// --- server state ---

type serverState struct {
	mu       sync.Mutex
	bus      *eventbus.Bus
	bhatti   *bhatti.Client
	store    *store.Store
	missions map[string]*mission.Mission
	agents   map[string]*mission.Agent
	drivers  map[string]driver.AgentDriver // keyed by agentID
	eventID  int64

	// pi-coding-agent provider/model, resolved at startup
	piProvider string
	piModel    string

	// Worker bhatti image. "computer" (default) requires runtime
	// pi install; "kk-base" (after bake-image.sh) has pi pre-baked.
	workerImage string

	// Pi --extension paths (interpreted in the sandbox FS) to
	// load on every worker spawn. With kk-base, this is the
	// computer-use extension; with raw "computer", empty.
	piExtensions []string

	// Driver-side: paths/URLs for spawning the host driver pi
	// process and routing its tool callbacks back here.
	driverToolsPath   string
	driverSessionRoot string
	internalURL       string

	// Per-driver auth tokens for the /internal/driver/* HTTP
	// callbacks. Generated when the driver is spawned, deleted
	// when the mission ends. Keyed by driver agent ID.
	driverTokens map[string]string

	// Outstanding ask_operator calls. While set, the next
	// operator chat message resolves the pending question (the
	// HTTP handler for /internal/.../ask_operator blocks on this
	// channel). Keyed by driver agent ID. Only one outstanding
	// ask per driver at a time.
	driverPendingAsk map[string]chan string

	// Per-mission "have we logged this milestone yet" tracker.
	// Keys are missionID; value is a bitmask of which milestones
	// have already been logged (one slog line apiece, otherwise
	// the log fills up). See timing.go in pkg/mission for the
	// canonical milestone definitions.
	timingLogged map[string]map[string]bool

	// Active-driver tick dispatchers. One per mission; created
	// when the driver is connected, stopped on mission delete /
	// driver disconnect. Owns its own goroutine. See tick.go.
	tickMu          sync.Mutex
	tickDispatchers map[string]*TickDispatcher

	// ctx is the lifetime context for all background dispatchers.
	// Cancelled on graceful shutdown (currently unused; reserved
	// for SIGTERM handling).
	ctx context.Context
}

func (s *serverState) nextEventID() int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.eventID++
	return s.eventID
}

// --- handlers ---

type createMissionReq struct {
	Goal string `json:"goal"`
	// Canvas coordinates of the right-click that dispatched this
	// mission, in canvas-flow space. When set, the mission's
	// driver tile spawns at this point and the position
	// persists across Karkhana restarts. Optional.
	CanvasX *float64 `json:"canvas_x,omitempty"`
	CanvasY *float64 `json:"canvas_y,omitempty"`
}

func (s *serverState) handleMissions(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		s.mu.Lock()
		out := make([]*mission.Mission, 0, len(s.missions))
		for _, m := range s.missions {
			out = append(out, m)
		}
		s.mu.Unlock()
		writeJSON(w, 200, out)

	case http.MethodPost:
		var req createMissionReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, 400, map[string]any{"error": "invalid json"})
			return
		}
		if req.Goal == "" {
			writeJSON(w, 400, map[string]any{"error": "goal required"})
			return
		}

		m := &mission.Mission{
			ID:        "msn_" + randHex(12),
			Goal:      req.Goal,
			Status:    mission.StatusRunning,
			CreatedBy: "operator",
			CreatedAt: time.Now(),
		}
		s.mu.Lock()
		s.missions[m.ID] = m
		s.mu.Unlock()
		s.persistMission(m)

		s.publish(mission.Event{
			ID:        s.nextEventID(),
			MissionID: m.ID,
			Kind:      "mission.created",
			Payload:   map[string]any{"goal": m.Goal},
			Ts:        time.Now(),
		})

		// Pass the right-click canvas coords to runMission so the
		// driver agent's canvas_x/y get set on creation.
		go s.runMission(m, req.CanvasX, req.CanvasY)
		writeJSON(w, 201, m)

	default:
		http.Error(w, "method not allowed", 405)
	}
}

func (s *serverState) handleMissionByID(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path[len("/api/missions/"):]
	// Sub-routes: /api/missions/:id/<action>
	if idx := strings.IndexByte(path, '/'); idx >= 0 {
		missionID := path[:idx]
		action := path[idx+1:]
		switch action {
		case "timing":
			s.handleMissionTiming(w, r, missionID)
			return
		case "notes":
			s.handleMissionNotes(w, r, missionID)
			return
		case "artifacts":
			s.handleMissionArtifacts(w, r, missionID)
			return
		default:
			http.Error(w, "unknown sub-route: "+action, 404)
			return
		}
	}
	id := path
	s.mu.Lock()
	m, ok := s.missions[id]
	s.mu.Unlock()
	if !ok {
		http.Error(w, "not found", 404)
		return
	}
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, 200, m)
	case http.MethodDelete:
		go s.deleteMission(m)
		writeJSON(w, 202, map[string]any{"status": "deleting"})
	default:
		http.Error(w, "method not allowed", 405)
	}
}

// handleMissionNotes returns blackboard notes for a mission.
// Used by the frontend on initial hydrate / when the operator
// expands a note row.
//
//   GET /api/missions/:id/notes        — all notes
//   GET /api/missions/:id/notes?key=X  — only notes with key=X
//
// Always returns oldest-first within a key (creation order).
func (s *serverState) handleMissionNotes(w http.ResponseWriter, r *http.Request, missionID string) {
	if s.store == nil {
		http.Error(w, "persistence disabled", http.StatusServiceUnavailable)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	notes, err := s.store.ListNotes(ctx, missionID, r.URL.Query().Get("key"))
	if err != nil {
		http.Error(w, "read notes failed: "+err.Error(), 500)
		return
	}
	writeJSON(w, 200, notes)
}

// handleMissionArtifacts returns the artifact list for a mission.
// v0.7: usually 0 or 1 artifact per mission (created when the
// driver calls finish). Newer-first ordering.
//
//   GET /api/missions/:id/artifacts
func (s *serverState) handleMissionArtifacts(w http.ResponseWriter, r *http.Request, missionID string) {
	if s.store == nil {
		http.Error(w, "persistence disabled", http.StatusServiceUnavailable)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	arts, err := s.store.ListArtifacts(ctx, missionID)
	if err != nil {
		http.Error(w, "read artifacts failed: "+err.Error(), 500)
		return
	}
	writeJSON(w, 200, arts)
}

// handleArtifactByID returns a single artifact's full content.
//
//   GET /api/artifacts/:id
func (s *serverState) handleArtifactByID(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimPrefix(r.URL.Path, "/api/artifacts/")
	if id == "" {
		http.Error(w, "id required", 400)
		return
	}
	if s.store == nil {
		http.Error(w, "persistence disabled", http.StatusServiceUnavailable)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	art, err := s.store.GetArtifact(ctx, id)
	if err != nil {
		http.Error(w, "read artifact failed: "+err.Error(), 500)
		return
	}
	if art == nil {
		http.Error(w, "not found", 404)
		return
	}
	writeJSON(w, 200, art)
}

// handleMissionTiming returns mission.MissionTiming — milestone
// timestamps + computed durations — derived from the events
// table. Useful for answering "how long did the driver take to
// react" without scrolling logs.
//
// GET /api/missions/:id/timing
func (s *serverState) handleMissionTiming(w http.ResponseWriter, r *http.Request, missionID string) {
	if s.store == nil {
		http.Error(w, "persistence disabled", http.StatusServiceUnavailable)
		return
	}
	s.mu.Lock()
	m, ok := s.missions[missionID]
	s.mu.Unlock()
	if !ok {
		http.Error(w, "not found", 404)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	evs, err := s.store.AllEventsForMission(ctx, missionID)
	if err != nil {
		http.Error(w, "events read failed: "+err.Error(), 500)
		return
	}
	timing := mission.ComputeMissionTiming(missionID, m.CreatedAt, evs)
	writeJSON(w, 200, timing)
}

// deleteMission tears down everything attached to a mission:
// terminates each worker's pi-rpc driver, destroys each bhatti
// sandbox, removes the in-memory mission + agent rows, emits a
// terminal event. Idempotent and best-effort — if bhatti is
// unreachable, we still clean up Karkhana state.
func (s *serverState) deleteMission(m *mission.Mission) {
	slog.Info("delete mission", "mission", m.ID, "goal", truncate(m.Goal, 60))

	// Stop the tick dispatcher first so it doesn't fire follow_ups
	// against an about-to-be-closed driver.
	s.stopTickDispatcher(m.ID)

	// Snapshot all agents belonging to this mission, then operate
	// outside the lock (terminate calls bhatti, can take seconds).
	s.mu.Lock()
	var agents []*mission.Agent
	for _, a := range s.agents {
		if a.MissionID == m.ID {
			agents = append(agents, a)
		}
	}
	s.mu.Unlock()

	for _, a := range agents {
		s.terminateAgent(a)
	}

	// Remove from state
	s.mu.Lock()
	delete(s.missions, m.ID)
	delete(s.timingLogged, m.ID)
	for id, a := range s.agents {
		if a.MissionID == m.ID {
			delete(s.agents, id)
		}
	}
	s.mu.Unlock()

	// Remove from store. The DB has FK ON DELETE CASCADE so
	// agents + events for this mission go too. Run after the
	// in-memory cleanup so we never have a row in s.agents
	// that's been deleted from the DB.
	if s.store != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		if err := s.store.DeleteMission(ctx, m.ID); err != nil {
			slog.Warn("mission DB delete failed",
				"mission", m.ID, "err", err)
		}
		cancel()
	}

	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID,
		Kind: "mission.deleted", Ts: time.Now(),
		Payload: map[string]any{"workers_terminated": len(agents)},
	})
}

func (s *serverState) handleAgents(w http.ResponseWriter, r *http.Request) {
	missionID := r.URL.Query().Get("mission_id")
	s.mu.Lock()
	out := make([]*mission.Agent, 0)
	for _, a := range s.agents {
		if missionID == "" || a.MissionID == missionID {
			out = append(out, a)
		}
	}
	s.mu.Unlock()
	writeJSON(w, 200, out)
}

// handleAgentByID supports:
//   GET    /api/agents/:id        — fetch agent
//   DELETE /api/agents/:id        — terminate agent (cascades to
//                                   sandbox / driver subprocess)
//   POST   /api/agents/:id/prompt — operator chat (drivers only,
//                                   in practice; workers don't
//                                   currently take live input)
func (s *serverState) handleAgentByID(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path[len("/api/agents/"):]
	// Sub-routes: /api/agents/:id/<action>
	if idx := strings.IndexByte(path, '/'); idx >= 0 {
		agentID := path[:idx]
		action := path[idx+1:]
		switch action {
		case "prompt":
			s.handleAgentPrompt(w, r, agentID)
			return
		default:
			http.Error(w, "unknown sub-route", 404)
			return
		}
	}
	id := path
	s.mu.Lock()
	a, ok := s.agents[id]
	s.mu.Unlock()
	if !ok {
		http.Error(w, "not found", 404)
		return
	}
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, 200, a)
	case http.MethodDelete:
		go s.terminateAgent(a)
		writeJSON(w, 202, map[string]any{"status": "terminating"})
	default:
		http.Error(w, "method not allowed", 405)
	}
}

// --- mission runner (real bhatti + real pi) ---

// runMission spawns the per-mission DRIVER agent on the
// Karkhana host and sends the operator's initial goal as its
// first prompt. The driver decides whether to spawn workers via
// its tools (spawn_worker), and the operator can keep chatting
// with it for the lifetime of the mission — v0.6: mission ==
// driver tile == conversation.
//
// canvasX/Y come from the right-click coords if the operator
// dispatched via the canvas; nil for programmatic dispatches.
// They land on the driver agent's canvas_x/y and persist.
//
// Worker spawning is now a SEPARATE flow: spawnWorker(), called
// from the /internal/driver/:id/spawn_worker HTTP handler when
// the driver invokes its spawn_worker tool.
func (s *serverState) runMission(m *mission.Mission, canvasX, canvasY *float64) {
	driverID := "agent_" + randHex(12)
	token := randHex(32)

	driverAgent := &mission.Agent{
		ID:        driverID,
		MissionID: m.ID,
		Role:      mission.RoleDriver,
		SpawnKind: mission.SpawnRoot,
		Task:      m.Goal,
		Status:    mission.StatusRunning,
		StartedAt: time.Now(),
		CanvasX:   canvasX,
		CanvasY:   canvasY,
	}
	s.mu.Lock()
	s.agents[driverID] = driverAgent
	s.driverTokens[driverID] = token
	m.DriverAgentID = driverID
	s.mu.Unlock()
	s.persistAgent(driverAgent)
	if s.store != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		_ = s.store.SetMissionDriver(ctx, m.ID, driverID)
		cancel()
	}

	spawningPayload := map[string]any{
		"role":  "driver",
		"task":  m.Goal,
		"stage": "spawning host pi process",
	}
	if canvasX != nil {
		spawningPayload["canvas_x"] = *canvasX
	}
	if canvasY != nil {
		spawningPayload["canvas_y"] = *canvasY
	}
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: driverID,
		Kind: "agent.spawning", Ts: time.Now(),
		Payload: spawningPayload,
	})

	// Per-mission session dir for pi's JSONL.
	sessDir := filepath.Join(s.driverSessionRoot, m.ID)
	if err := os.MkdirAll(sessDir, 0o755); err != nil {
		s.failAgent(m, driverAgent, "mkdir session dir: "+err.Error())
		return
	}

	argv := buildDriverArgv(sessDir, s.piProvider, s.piModel, s.driverToolsPath, false)

	env := s.piEnvFromHost()
	env["KARKHANA_INTERNAL_URL"] = s.internalURL
	env["KARKHANA_DRIVER_TOKEN"] = token
	env["KARKHANA_DRIVER_ID"] = driverID

	ctx := context.Background()
	drv, err := driver.ConnectHost(ctx, driver.HostOptions{
		Argv:      argv,
		Env:       env,
		SessionID: "host-" + m.ID,
		OnEvent: func(ev driver.Event) {
			s.forwardPiEvent(m.ID, driverID, ev)
		},
		OnDisconnect: func(err error) {
			s.handleDriverDisconnect(m.ID, driverID, err)
		},
	})
	if err != nil {
		s.failAgent(m, driverAgent, "spawn driver pi failed: "+err.Error())
		return
	}
	s.mu.Lock()
	s.drivers[driverID] = drv
	s.mu.Unlock()

	driverSpawnedAt := time.Now()
	slog.Info("timing: driver spawned",
		"mission", m.ID,
		"driver", driverID,
		"warmup_ms", driverSpawnedAt.Sub(m.CreatedAt).Milliseconds())

	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: driverID,
		Kind: "agent.spawned", Ts: time.Now(),
		Payload: map[string]any{
			"role": "driver",
			"task": m.Goal,
		},
	})
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: driverID,
		Kind: "agent.driver_connected", Ts: time.Now(),
		Payload: map[string]any{"session_id": drv.SessionID()},
	})

	// Echo the operator's first message into the event stream so
	// the DriverTile chat shows it. The first prompt and any
	// follow-ups go through the same operator.message kind.
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: driverID,
		Kind: "operator.message", Ts: time.Now(),
		Payload: map[string]any{"text": m.Goal},
	})

	prompt := wrapGoalWithDriverContext(m.Goal)
	if err := drv.Prompt(context.Background(), prompt); err != nil {
		s.failAgent(m, driverAgent, "send prompt failed: "+err.Error())
		return
	}
	promptSentAt := time.Now()
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: driverID,
		Kind: "driver.prompt_sent", Ts: promptSentAt,
		Payload: map[string]any{"text": m.Goal},
	})
	slog.Info("timing: first prompt sent",
		"mission", m.ID,
		"goal_len", len(m.Goal),
		"warmup_ms", promptSentAt.Sub(m.CreatedAt).Milliseconds())

	// Active-driver tick dispatcher. Wakes the driver on every
	// material mission event (note_write, worker_terminated,
	// heartbeat). See tick.go for the loop.
	s.startTickDispatcher(m, drv, driverID)

	// We do NOT AwaitCompletion. The driver is persistent — it
	// finishes a turn (agent_end) but stays running, awaiting
	// the operator's next chat message via /api/agents/:id/prompt.
	// Cleanup happens via mission deletion or driver crash.
}

// spawnWorker creates a new worker sandbox + pi-rpc agent under
// the given driver. Called by the /internal/driver/:id/spawn_worker
// HTTP handler when the driver invokes its spawn_worker tool.
// Returns the worker agent record (already in s.agents).
func (s *serverState) spawnWorker(parentDriverID string, m *mission.Mission, task string) (*mission.Agent, error) {
	workerID := "agent_" + randHex(12)
	worker := &mission.Agent{
		ID:            workerID,
		MissionID:     m.ID,
		ParentAgentID: parentDriverID,
		Role:          mission.RoleWorker,
		SpawnKind:     mission.SpawnSpawn,
		Task:          task,
		Recipe:        "computer-use",
		Status:        mission.StatusRunning,
		StartedAt:     time.Now(),
	}
	s.mu.Lock()
	s.agents[workerID] = worker
	s.mu.Unlock()
	s.persistAgent(worker)

	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: workerID,
		Kind: "agent.spawning", Ts: time.Now(),
		Payload: map[string]any{
			"role":   "worker",
			"task":   task,
			"parent": parentDriverID,
			"stage":  "creating sandbox",
		},
	})

	// Spawn the rest asynchronously so the driver tool returns
	// quickly with a worker_id; sandbox boot + pi connect take
	// a couple seconds even on kk-base.
	go s.runWorker(parentDriverID, m, worker)
	return worker, nil
}

// runWorker is the per-worker async lifecycle: create sandbox,
// publish KasmVNC, ensure pi, connect driver, send task as
// prompt. This is the meat of v0.5's runMission, just renamed
// and parameterized by parentDriverID + task. Failures call
// failAgent (which used to be failWorker).
func (s *serverState) runWorker(parentDriverID string, m *mission.Mission, worker *mission.Agent) {
	workerID := worker.ID
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	sandboxName := fmt.Sprintf("kk-%s", workerID[len(workerID)-8:])

	// 1. Create sandbox
	piEnv := s.piEnvFromHost()
	sb, err := s.bhatti.CreateSandbox(ctx, bhatti.SandboxSpec{
		Name:        sandboxName,
		Image:       s.workerImage,
		CPUs:        defaultWorkerCPUs,
		MemoryMB:    defaultWorkerMemoryMB,
		TimeoutSecs: defaultWorkerTimeoutSecs,
		KeepHot:     true,
		Env:         piEnv, // pre-set so pi can read on first run
		Metadata: map[string]string{
			"karkhana.dev/mission_id": m.ID,
			"karkhana.dev/agent_id":   workerID,
			"karkhana.dev/goal":       truncate(m.Goal, 200),
		},
	})
	if err != nil {
		s.failWorker(m, worker, "sandbox create failed: "+err.Error())
		return
	}
	slog.Info("sandbox created",
		"mission", m.ID, "agent", workerID,
		"sandbox", sb.ID, "ip", sb.IP)

	s.mu.Lock()
	worker.BhattiSandboxID = sb.ID
	s.mu.Unlock()
	s.persistAgent(worker)

	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: workerID,
		Kind: "sandbox.created", Ts: time.Now(),
		Payload: map[string]any{
			"sandbox_id": sb.ID, "ip": sb.IP, "image": sb.Image,
		},
	})

	// 2. Publish KasmVNC + fetch creds (parallelize-able but keep
	// sequential for clarity).
	pub, err := s.bhatti.Publish(ctx, sb.ID, kasmVNCPort,
		strings.ToLower(workerID[len(workerID)-8:]))
	kasmURL := ""
	if err != nil {
		slog.Warn("publish failed", "err", err)
	} else if pub != nil {
		kasmURL = pub.CanonicalURL()
	}

	user, pass, err := s.fetchKasmCreds(ctx, sb.ID)
	if err != nil {
		slog.Warn("vnc-creds failed", "agent", workerID, "err", err)
	}

	proxyPath := "/proxy/" + workerID + "/"
	s.mu.Lock()
	worker.KasmVNCURL = kasmURL
	worker.KasmVNCProxyPath = proxyPath
	worker.KasmVNCUser = user
	worker.KasmVNCPass = pass
	s.mu.Unlock()
	s.persistAgent(worker)

	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: workerID,
		Kind: "agent.spawned", Ts: time.Now(),
		Payload: map[string]any{
			"role":             "worker",
			"task":             m.Goal,
			"sandbox_id":       sb.ID,
			"kasmvnc_url":      proxyPath,
			"kasmvnc_upstream": kasmURL,
		},
	})

	// 3. Ensure pi is available. With KARKHANA_WORKER_IMAGE=kk-base
	// (post-bake), pi is already in /usr/bin and we skip the install.
	// With image="computer" (default), we npm-install at runtime
	// (~30s). Detect via `which pi`; install on miss.
	if err := s.ensurePi(ctx, m, workerID, sb.ID); err != nil {
		s.failWorker(m, worker, err.Error())
		return
	}

	// 4. Connect agent driver. The driver opens a piped session,
	// receives session_id, configures pi, then waits for prompts.
	drv, err := driver.Connect(ctx, s.bhatti, sb.ID, driver.Options{
		Cmd: []string{
			"pi", "--mode", "rpc", "--session-dir", piSessionDir,
		},
		Provider:   s.piProvider,
		Model:      s.piModel,
		Extensions: s.piExtensions,
		Env:        piEnv,
		OnEvent: func(ev driver.Event) {
			s.forwardPiEvent(m.ID, workerID, ev)
		},
		OnDisconnect: func(err error) {
			s.handleDriverDisconnect(m.ID, workerID, err)
		},
	})
	if err != nil {
		s.failWorker(m, worker, "agent driver connect failed: "+err.Error())
		return
	}
	s.mu.Lock()
	s.drivers[workerID] = drv
	worker.BhattiSessionID = drv.SessionID()
	s.mu.Unlock()
	s.persistAgent(worker)

	slog.Info("agent driver connected",
		"agent", workerID, "session", drv.SessionID())
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: workerID,
		Kind: "agent.driver_connected", Ts: time.Now(),
		Payload: map[string]any{"session_id": drv.SessionID()},
	})

	// 5. Send the WORKER's task as the first prompt, with the
	// desktop-context preamble so the worker pi knows it has a
	// visible KasmVNC display and the computer-use toolset.
	hasComputerUse := len(s.piExtensions) > 0
	prompt := wrapGoalWithDesktopContext(worker.Task, hasComputerUse)
	if err := drv.Prompt(context.Background(), prompt); err != nil {
		s.failAgent(m, worker, "send prompt failed: "+err.Error())
		return
	}
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: workerID,
		Kind: "driver.prompt_sent", Ts: time.Now(),
		Payload: map[string]any{"text": worker.Task},
	})

	// 6. Wait for agent_end in a goroutine; mark worker complete.
	go func() {
		awaitCtx, awaitCancel := context.WithTimeout(
			context.Background(),
			time.Duration(defaultWorkerTimeoutSecs)*time.Second,
		)
		defer awaitCancel()
		if err := drv.AwaitCompletion(awaitCtx); err != nil {
			slog.Warn("agent end errored",
				"agent", workerID, "err", err)
		}
		s.markWorkerCompleted(m.ID, workerID)
	}()
}

// failAgent is the rename of failWorker, used for both worker
// and driver failure paths. failWorker remains as a thin alias
// for the existing call sites elsewhere in this file (recovery,
// etc.) until those are touched.
func (s *serverState) failAgent(m *mission.Mission, a *mission.Agent, reason string) {
	s.failWorker(m, a, reason)
}

// ensurePi makes sure `pi` is on the worker's PATH. Fast path:
// `which pi` returns 0 (image already has it baked, e.g. kk-base)
// — emit a quick "pi ready" event and return. Slow path: npm
// install -g pi-coding-agent (~30s).
func (s *serverState) ensurePi(ctx context.Context, m *mission.Mission, workerID, sandboxID string) error {
	check, err := s.bhatti.Exec(ctx, sandboxID, bhatti.ExecRequest{
		Cmd:        []string{"which", "pi"},
		TimeoutSec: 10,
	})
	if err == nil && check.ExitCode == 0 && strings.TrimSpace(check.Stdout) != "" {
		s.publish(mission.Event{
			ID: s.nextEventID(), MissionID: m.ID, AgentID: workerID,
			Kind: "worker.installed", Ts: time.Now(),
			Payload: map[string]any{
				"text": "pi pre-baked in image; skipping install",
			},
		})
		return nil
	}

	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: workerID,
		Kind: "worker.installing", Ts: time.Now(),
		Payload: map[string]any{
			"text": "installing pi-coding-agent (~30s; bake an image to skip)…",
		},
	})
	res, err := s.bhatti.Exec(ctx, sandboxID, bhatti.ExecRequest{
		Cmd: []string{
			"sudo", "npm", "install", "-g", "--silent", piPackage,
		},
		TimeoutSec: 240,
	})
	if err != nil {
		return fmt.Errorf("pi install failed: %w", err)
	}
	if res.ExitCode != 0 {
		return fmt.Errorf("npm exit=%d stderr=%q",
			res.ExitCode, truncate(res.Stderr, 500))
	}
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: workerID,
		Kind: "worker.installed", Ts: time.Now(),
		Payload: map[string]any{"text": "pi installed; connecting agent driver…"},
	})
	return nil
}

// wrapGoalWithDriverContext is the preamble for the per-mission
// DRIVER agent (running on the Karkhana host, no desktop). The
// driver orchestrates worker microVMs via its tool surface;
// this preamble teaches it the tools and the chat-shaped
// lifecycle (finish is a checkpoint, not an exit).
func wrapGoalWithDriverContext(goal string) string {
	env := `<environment>
You are the SUPERVISOR of a Karkhana mission. You orchestrate worker agents AND narrate your reasoning live to the operator who is watching on a canvas. You run on the Karkhana host (no desktop — just bash/read/write/edit + your orchestration tools); your workers run inside isolated bhatti microVMs with full Linux desktops, Chromium, and computer-use tools (screenshot, click, type, scroll).

## You are not a batch coordinator — you are LIVE

This is what makes Karkhana different from every other research agent. You do not:
  - spawn N workers, block until they all finish, then synthesize once
  - hide your reasoning between worker turns
  - emit one final report at the end

You DO:
  - fan out workers in parallel when the task's parts are already known
  - scout progressively when the dimensions of the task are NOT yet known
  - get auto-ticked by Karkhana every time something material happens (worker writes a note, worker terminates, ~45s heartbeat)
  - narrate your reasoning OUT LOUD in 1-2 sentences per tick, so the operator can follow your thinking
  - re-plan, steer workers, terminate workers that are off-task
  - call finish() to produce the artifact ONLY when you have enough

## When to fan out vs. scout

This matters. Wrong default kills the wedge.

FAN OUT (spawn ALL workers immediately via spawn_workers([t1..tN])):
  - The operator already named the items: "compare A, B, C, D, E", "summarize these 5 articles", "check these 7 URLs".
  - The task shape is clear and the worker tasks are mostly the same template with different inputs.
  - You have nothing to gain from waiting; bhatti boots them all in parallel for ~3-4s.

SCOUT first (spawn 1-2, wait for early findings, then dispatch the rest):
  - The operator described a SHAPE but not the items: "find the top 5 PRs in this repo, then summarize each".
  - You don't yet know the dimensions and worker tasks would be guesses until a scout reports back.
  - You think a quick early finding will sharpen subsequent tasks ("if A turns out to use libkrun, I want the others to specifically check libkrun-vs-firecracker").

DEFAULT TO FAN OUT. The progressive pattern is for genuine uncertainty, not for hedging. If the operator gave you 5 URLs, spawn 5 workers in one spawn_workers call. Don't be cute.

The operator chose Karkhana because they want to WATCH a supervisor think in real time. Your value is in the narration + dynamic decisions, not the templated fan-out.

## The tick loop

After your initial response, you'll start receiving "[karkhana tick]" messages. Each one carries:
  - what just changed (a new note, a worker terminated, etc.)
  - current mission state (worker statuses, blackboard manifest, elapsed/cost)
  - the supervisor protocol reminder

On each tick, do ONE of:
  - Narrate a sentence about what's interesting and end with "(watching)" if nothing needs action.
  - Narrate + take ONE tool action (spawn_worker, steer_worker, terminate_worker, write_note, finish).

Keep tick responses short. The operator reads each one in your driver tile chat.

## Orchestration tools

  spawn_worker(task)                    one worker; returns worker_id immediately
  spawn_workers(tasks)                  N workers in ONE call (parallel; prefer for fan-out)
  steer_worker(worker_id, hint)         inject mid-flight guidance into a running worker
  terminate_worker(worker_id, reason)   force-stop a worker (off-task, looping, no-longer-needed)
  ask_operator(question)                pause and ask the human; blocks until reply
  report_progress(message)              quick status update (you can also just narrate)
  finish(result, title?)                produce the FINAL ARTIFACT and enter idle

  list_notes()                          manifest of blackboard keys + entry counts
  read_notes(key?)                      read all entries for a key (or whole blackboard)
  write_note(key, content, summary?)    append your own planning note

DO NOT call wait_for_workers. It is deprecated; ticks replace it. After spawning workers, just end your turn — Karkhana ticks you on every material event.

## Blackboard

The mission's shared scratchpad. Workers contribute findings via write_note continuously. You read those contributions during synthesis. Append-only — multiple notes under the same key accumulate.

WHEN YOU SPAWN WORKERS, the task description must:
  1. Pin a SPECIFIC blackboard key (e.g. 'bhatti_findings', 'pricing_x').
  2. Instruct INCREMENTAL writes — write_note as findings are discovered, NOT one final dump.
  3. Tell the worker to use the BROWSER (chromium + click/scroll/screenshot), not curl. (Karkhana now BLOCKS curl against public URLs at the tool layer, but you should still spell it out so the worker plans correctly.)
  4. End with "call finish(summary) when done." — the literal phrase "finish" is the worker's deterministic termination signal.

Example task string:

  "Open https://X in the browser. Explore visually — read the overview, scroll, click into sections. AS YOU DISCOVER each finding, call write_note('topic_x', <markdown>, <one-line summary>). Don't save everything for a final dump — stream notes as you find them. When you've covered the task adequately, call finish('summary line referencing your notes')."

## Active supervision patterns

The tick loop enables patterns you couldn't do before:

  Progressive fan-out:
    Tick 0:  spawn 2 scout workers, see what the landscape looks like
    Tick 3:  one scout reports "X uses approach A". Spawn 3 more workers on similar items now that you know the dimensions.
  Mid-flight redirect:
    Tick N:  worker W's notes show it's down a rabbit hole. steer_worker(W, "skip the kernel deep-dive; focus on the public API surface").

  Cutting losses:
    Tick M:  worker W has written 12 notes that duplicate worker V's. terminate_worker(W, "diminishing returns; V covered this dimension thoroughly").

  Diverge→converge:
    Spawn N workers each on a different angle. As notes accumulate, spot the through-line and write_note('synthesis_v1', …) yourself. On final tick, finish() with a polished version.

## When to finish()

When the blackboard answers the operator's question. Not when every worker has terminated — you can finish() even while workers are still running (Karkhana terminates them when you finish).

finish() produces a markdown artifact that appears on the canvas as its own tile. The driver tile stays active; the operator can follow up with "extend section 3" or "compare with Y" and you pick up with full conversation history.

## Your conversation persists

The first message below is the operator's goal. Tick messages arrive automatically. Operator follow-ups arrive as normal user messages. All of these accumulate in your context — you remember everything across days.
</environment>`
	return env + `

<goal>
` + goal + `
</goal>`
}

// wrapGoalWithDesktopContext prepends a short system-style
// preamble to the operator's goal so pi-coding-agent understands
// it's running on a XFCE4 + KasmVNC desktop with computer-use
// tools available. Without this preamble, pi happily reaches
// for curl when the goal says "open X.com" — the operator sees
// a static empty desktop in the iframe.
//
// Two flavors:
//   - withComputerUse=true: the worker has the screenshot/click/
//     type/key/scroll tools loaded (kk-base image). Tell the
//     agent to drive the desktop visually.
//   - withComputerUse=false: only bash/read/write/edit. Tell the
//     agent to launch chromium and narrate from curl.
//
// Why an inline preamble (vs. a real --system-prompt CLI flag):
// pi exposes per-message context cleanly, and we want the
// preamble to ride alongside *this* goal so re-prompts in the
// same session don't double up on it.
func wrapGoalWithDesktopContext(goal string, withComputerUse bool) string {
	var env string
	if withComputerUse {
		env = `<environment>
You are a WORKER agent running inside a sandboxed Linux microVM (Debian + XFCE4 + Chromium). The DRIVER agent for this mission delegated this task to you and is waiting for your answer.

The desktop resolution is 1280x720, DISPLAY=:99. The operator watches you live over KasmVNC.

## Completion criteria are mandatory

When you have finished your task, call the finish(summary) tool as your VERY LAST action. This is the ONLY reliable termination signal — do NOT just stop responding or end with a text-only message; pi will keep the agent loop alive and the driver will block forever waiting for you.

The finish tool:
  - Takes a short 'summary' (≤ 500 chars) that becomes your final answer to the driver.
  - Returns terminate:true which deterministically ends the worker's pi loop.
  - Should be called IMMEDIATELY after your final write_note. Don't add a chatty wrap-up message after — the summary string IS your wrap-up.

Flow at end-of-task: last write_note(...)  →  finish("recorded N notes under <key>; see blackboard for details")  →  worker terminates.

## Tools

In addition to bash/read/write/edit, you have a full computer-use toolset that drives the desktop directly. PREFER these over bash for any visible interaction:

  screenshot()                          — capture the current desktop
  left_click(x, y) / right_click(x, y)  — click at pixel coords
  double_click(x, y)                    — double-click
  mouse_move(x, y)                      — hover without clicking
  left_click_drag(x1,y1, x2,y2)         — drag from A to B
  type(text)                            — type literal text at focus
  key(combo)                            — e.g. "Return", "Tab", "ctrl+l"
  scroll(direction, amount?)            — "up"|"down"|"left"|"right"
  wait(seconds)                         — sleep, return screenshot
  cursor_position()                     — read-only, no action

Every action tool returns a fresh screenshot in its result, so you have visual feedback automatically — you do NOT need to call screenshot() after each click. Use coordinates from the latest screenshot you have.

Workflow for "open <url>" / "go to <site>" / "browse to X":
  1. bash: 'kk-browser <url>' to launch chromium with Chrome DevTools
     Protocol enabled on port 9222. ALWAYS use kk-browser, never call
     chromium directly — kk-browser sets the flags that make browser_eval
     work, AND it suppresses the yellow infobars that would otherwise eat
     the top ~80px of the viewport.
  2. wait(2)  — let the window appear and the page render
  3. Then either:
       - browser_eval('<js>') for fast structured data extraction (see below)
       - screenshot() + click/scroll/type for visual interaction

Do NOT interpret bare hostnames like "bhatti.sh" as local files. They are URLs (prefix https:// when launching).

## browser_eval — fast structured extraction from the loaded page

browser_eval(code) runs JavaScript in the chromium tab you opened with kk-browser. It is MUCH faster than scrolling + screenshotting when you need to pull repeated/structured data off the loaded page:

  - all PR titles + URLs from a github page
  - all filenames in a directory listing
  - all rows of a pricing table
  - title / metadata of the current page
  - links matching a CSS selector

The data lands as a JSON value in the tool result; write_note it directly.

GOOD pattern (preferred over scroll-screenshot loops):

  bash 'kk-browser https://github.com/X/Y/pulls'
  wait(2)
  browser_eval("return Array.from(document.querySelectorAll('.js-issue-row')).map(r => ({ title: r.querySelector('a.Link--primary')?.textContent.trim(), author: r.querySelector('.opened-by a')?.textContent.trim() }))")
  write_note('prs', '...JSON result here...', 'top PR titles + authors')

browser_eval CANNOT bypass the page boundary:
  - fetch() / XHR to EXTERNAL hosts (e.g. api.github.com from a github.com page is NOT external; external means a totally different domain) is blocked
  - same-origin and localhost fetches still work for SPA-style apps
  - the operator still sees the page you're querying — transparency preserved

## Curl against public URLs is BLOCKED

The bash tool refuses curl/wget against any external http(s) URL. Use kk-browser + browser_eval instead. Local/internal URLs (localhost, 127.0.0.1, 10.0.x.x, 169.254.x.x, 192.168.x.x) are still allowed for legitimate sandbox-internal needs.

Why the block: you exist as a HEADFUL agent on a real X11 desktop. Curl turns you into an invisible HTTP scraper. browser_eval gives you the SAME speed while keeping the page (with its session, cookies, JS-rendered content) visible to the operator. That distinction is why Karkhana exists.

## When to use which tool

| Goal                                  | Tool                                |
|---------------------------------------|-------------------------------------|
| Open a URL                            | bash 'kk-browser <url>' + wait(2)   |
| Read a list of repeated items         | browser_eval (returns JSON)         |
| Get one specific value (title, attr)  | browser_eval                        |
| Click a link / button / form          | left_click(x, y) from screenshot    |
| Type in a field                       | screenshot → click → type(text)     |
| Scroll through long content           | scroll(direction)                   |
| Judge layout, design, screenshots     | screenshot()                        |
| Explore unfamiliar page first time    | screenshot() then decide            |
| Read source code on github page       | browser_eval('return document.querySelector(".blob-code-content")?.textContent') |

Default: if you know the SHAPE of the data you want and just need to extract it — browser_eval. If you need to SEE something or navigate — GUI tools.

## Blackboard — record findings as you discover them

When the driver's task includes phrases like "write findings to write_note(...)", "contribute under key X", or "record what you find", call:

  write_note(key, content, summary?)

This appends a contribution to the mission's shared scratchpad. Other agents (the driver, possibly peer workers) read it during synthesis.

KEY POINT: write notes INCREMENTALLY — every time you discover a meaningful chunk (a project's stated purpose, the architecture summary you just read, a relevant pricing tier, etc.), write_note it immediately. Do NOT save up everything to dump in a single giant final note. Reasons:
  - if you crash or time out, partial findings are still preserved
  - the operator and driver see your progress in real time
  - multiple smaller notes are easier to synthesize than one wall of text

Typical rhythm for a research task: open page → read overview → write_note(key, 'overview: ...') → explore section → write_note(key, 'architecture: ...') → explore another → write_note(key, 'limitations: ...') → respond 'DONE'.

Multiple notes under the same key are normal — they accumulate, none overwrites others. Use a stable key the driver specified; don't invent your own.

Narrate what you're doing in short assistant messages between tool calls. The operator watches both your reasoning and the desktop live.
</environment>`
	} else {
		env = `<environment>
You are a WORKER agent running inside a sandboxed Linux microVM (Debian + XFCE4 + Chromium). The DRIVER agent for this mission delegated this task to you and is waiting for your answer.

DISPLAY=:99 — GUI apps you launch from bash will appear in the operator's iframe in real time.

## Completion criteria are mandatory

When you have produced your final answer, respond with TEXT ONLY — do NOT call any more tools after that. The text-only response is what signals you're done; without it the driver thinks you're still working and the mission hangs.

The driver's task description below usually includes the explicit phrase "do not call any more tools after that" — honour it literally. Once you have what was asked, write it out and stop.

## Browsing

When the goal says "open <site>", "visit <url>", "browse to X", or anything that implies a web UI, launch chromium so the operator can SEE it:

  chromium --no-sandbox --test-type --new-window <url> &

(Include --test-type to suppress chromium's yellow infobars that would otherwise occupy ~80px at the top of the page.)

Not curl, not playwright, not headless. Wait ~2 seconds after launching for the window to settle. Use xdotool / wmctrl from bash if you need basic clicks or keypresses.

Do NOT interpret bare hostnames like "bhatti.sh" as local files. They are URLs (prefix https://).

For programmatic text extraction (data scraping, etc.), curl is fine — but launch the visible browser for the human-watching part.

Narrate what you're doing in short assistant messages between tool calls. The operator watches both your reasoning and the desktop live.
</environment>`
	}
	return env + `

<goal>
` + goal + `
</goal>`
}

// piEnvFromHost extracts LLM-provider API keys from Karkhana's
// environment so pi-coding-agent has something to authenticate
// with. Mirrors the env keys the Elixir prototype passes through.
// buildDriverArgv composes the argv for a host-side `pi --mode rpc`
// subprocess that runs as the mission driver. Used by both the
// initial spawn (continueSession=false) and the recovery path
// (continueSession=true, adds --continue to resume the existing
// session.jsonl).
//
// Hermeticity flags:
//   --no-extensions        Pi auto-discovers extensions from
//                          ~/.pi/agent/extensions/. We don't want
//                          the driver to inherit globally-installed
//                          extensions like pi-bhatti-browser (which
//                          adds playwright-driven browser_open /
//                          browser_screenshot tools that operate on
//                          the OPERATOR'S HOST machine, invisible to
//                          the canvas, and architecturally wrong —
//                          drivers coordinate workers, they don't
//                          browse. The --extension flag we pass
//                          explicitly still works.)
//   --no-skills            same reasoning — don't inherit local skills
//   --no-prompt-templates  same
//   --no-context-files     skip AGENTS.md / CLAUDE.md from operator's cwd
//   --no-themes            irrelevant in rpc mode, but cleaner
//
// Net effect: the driver pi process sees ONLY the tools we
// explicitly --extension in, plus pi's built-in bash/read/write/
// edit/grep/find/ls. No surprise tools.
func buildDriverArgv(sessDir, provider, model, driverToolsPath string, continueSession bool) []string {
	argv := []string{
		"pi", "--mode", "rpc",
		"--session-dir", sessDir,
		"--no-extensions",
		"--no-skills",
		"--no-prompt-templates",
		"--no-context-files",
		"--no-themes",
	}
	if continueSession {
		argv = append(argv, "--continue")
	}
	if provider != "" {
		argv = append(argv, "--provider", provider)
	}
	if model != "" {
		argv = append(argv, "--model", model)
	}
	if driverToolsPath != "" {
		// --no-extensions disables DISCOVERY but explicit
		// --extension paths still load. This is the only tool
		// surface the driver should see.
		argv = append(argv, "--extension", driverToolsPath)
	}
	return argv
}

func (s *serverState) piEnvFromHost() map[string]string {
	keys := []string{
		"ANTHROPIC_API_KEY",
		"OPENAI_API_KEY",
		"OPENROUTER_API_KEY",
		"GOOGLE_API_KEY",
		"GH_TOKEN",
	}
	env := map[string]string{}
	for _, k := range keys {
		if v := os.Getenv(k); v != "" {
			env[k] = v
		}
	}
	if env["GH_TOKEN"] != "" {
		env["GITHUB_TOKEN"] = env["GH_TOKEN"]
	}
	return env
}

// fetchKasmCreds runs `vnc-creds` inside the sandbox.
func (s *serverState) fetchKasmCreds(ctx context.Context, sandboxID string) (string, string, error) {
	res, err := s.bhatti.Exec(ctx, sandboxID, bhatti.ExecRequest{
		Cmd:        []string{"vnc-creds"},
		TimeoutSec: 10,
	})
	if err != nil {
		return "", "", err
	}
	if res.ExitCode != 0 {
		return "", "", fmt.Errorf("vnc-creds exit=%d stderr=%q",
			res.ExitCode, res.Stderr)
	}
	var user, pass string
	for _, line := range strings.Split(res.Stdout, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "username:") {
			user = strings.TrimSpace(strings.TrimPrefix(line, "username:"))
		} else if strings.HasPrefix(line, "password:") {
			pass = strings.TrimSpace(strings.TrimPrefix(line, "password:"))
		}
	}
	if user == "" || pass == "" {
		return "", "", fmt.Errorf("could not parse vnc-creds output: %q",
			res.Stdout)
	}
	return user, pass, nil
}

// --- pi-rpc event forwarding ---

// forwardPiEvent translates pi-rpc events to Karkhana event kinds.
// Pi emits dozens of distinct kinds; we pick the ones operators
// care about. message_update fires per-token during streaming —
// we DROP those (too noisy for the canvas) and rely on
// message_end for the final text.
func (s *serverState) forwardPiEvent(missionID, agentID string, ev driver.Event) {
	t, _ := ev["type"].(string)

	// Diagnostic: we observed workers that responded text-only,
	// went idle, but never produced an agent_end on the wire.
	// Log every event type so we can see exactly what pi emits
	// during the suspect window. Cheap; gated to debug-volume
	// types via the if below to avoid log spam.
	if t == "agent_end" || t == "extension_error" {
		slog.Info("pi event",
			"mission", missionID, "agent", agentID, "type", t)
	}

	switch t {
	case "agent_start":
		s.maybeLogFirstReaction(missionID, agentID, "agent_start")
		s.publish(mission.Event{
			ID: s.nextEventID(), MissionID: missionID, AgentID: agentID,
			Kind: "worker.thinking", Ts: time.Now(),
			Payload: map[string]any{"text": "(agent started)"},
		})
		// Role-aware streaming signal. The frontend uses
		// agent.streaming / agent.idle to glow the driver tile
		// border + pulse outgoing edges while the supervisor
		// thinks. We emit one event regardless of role; the UI
		// decides what to do with it.
		s.publish(mission.Event{
			ID: s.nextEventID(), MissionID: missionID, AgentID: agentID,
			Kind: "agent.streaming", Ts: time.Now(),
			Payload: map[string]any{},
		})

	case "turn_start":
		// Quiet event; useful if we want a turn counter but skip for now.

	case "message_update":
		// Pi emits message_update for each streaming chunk during
		// an assistant turn — including thinking_delta. We surface
		// thinking deltas as a live feed so the operator can SEE
		// the supervisor reasoning during the long thinking phase
		// (Sonnet 4.6 on high thinking can spend 20-60s reasoning
		// before emitting any text; without this, the canvas
		// looks frozen).
		//
		// These events are TRANSIENT (skipped by persist) so we
		// don't fill SQLite with kilobytes of streaming chunks.
		// The final assistant message is still persisted via
		// message_end → worker.message.
		ame, _ := ev["assistantMessageEvent"].(map[string]any)
		ameType, _ := ame["type"].(string)
		switch ameType {
		case "thinking_start":
			s.publish(mission.Event{
				ID: s.nextEventID(), MissionID: missionID, AgentID: agentID,
				Kind: "agent.thinking_start", Ts: time.Now(),
				Payload: map[string]any{},
			})
		case "thinking_delta":
			delta, _ := ame["delta"].(string)
			if delta == "" {
				return
			}
			s.publish(mission.Event{
				ID: s.nextEventID(), MissionID: missionID, AgentID: agentID,
				Kind: "agent.thinking_delta", Ts: time.Now(),
				Payload: map[string]any{"delta": delta},
			})
		case "thinking_end":
			// Marker the UI uses to finalize the live thinking
			// bubble (lock it in, stop accepting deltas under the
			// same block).
			s.publish(mission.Event{
				ID: s.nextEventID(), MissionID: missionID, AgentID: agentID,
				Kind: "agent.thinking_end", Ts: time.Now(),
				Payload: map[string]any{},
			})
		case "text_delta":
			// Mirror thinking deltas for the post-thinking assistant
			// text. Makes the driver's spoken reply land word-by-
			// word in the chat instead of as one block at
			// message_end. Cheap; the final message_end still fires
			// for the canonical persisted record.
			delta, _ := ame["delta"].(string)
			if delta == "" {
				return
			}
			s.publish(mission.Event{
				ID: s.nextEventID(), MissionID: missionID, AgentID: agentID,
				Kind: "agent.text_delta", Ts: time.Now(),
				Payload: map[string]any{"delta": delta},
			})
		}

	case "turn_end":
		// Extract token usage to update accounting.
		if msg, ok := ev["message"].(map[string]any); ok {
			if usage, ok := msg["usage"].(map[string]any); ok {
				s.updateTokens(agentID, usage)
			}
		}

	case "message_end":
		// Pi emits message_end for EVERY message in the stream:
		// the user's prompt (wrapped with our preamble), tool
		// results coming back from extension calls, AND the
		// assistant's response. We only want to echo the
		// assistant's reply into the canvas event log — echoing
		// the user's prompt makes the chat tile show the 5600-
		// char preamble as if the driver wrote it, which is what
		// made the driver LOOK slow to react (operator sees a
		// wall of text streaming "from the driver" before the
		// actual tool call lands).
		msg, _ := ev["message"].(map[string]any)
		role, _ := msg["role"].(string)
		if role != "assistant" {
			return
		}
		text := extractAssistantText(msg)
		if text == "" {
			return
		}
		s.mu.Lock()
		if a, ok := s.agents[agentID]; ok {
			a.FinalAssistantText = truncate(text, 1000)
		}
		s.mu.Unlock()
		s.publish(mission.Event{
			ID: s.nextEventID(), MissionID: missionID, AgentID: agentID,
			Kind: "worker.message", Ts: time.Now(),
			Payload: map[string]any{"text": text},
		})

	case "tool_execution_start":
		toolName, _ := ev["toolName"].(string)
		args, _ := ev["args"].(map[string]any)
		summary := summarizeToolCall(toolName, args)
		s.maybeLogFirstAction(missionID, agentID, toolName)
		// Intercept write_note: workers can't call Karkhana via HTTP
		// (sandbox network reach to host is fragile across deployment
		// shapes), so we use the pi-rpc tool_execution_start event
		// stream as the transport. Tool args carry the note data;
		// the worker's tool execute() is a local no-op that just
		// returns success. See extensions/computer-use/index.ts.
		if toolName == "write_note" && args != nil {
			go s.persistBlackboardWrite(missionID, agentID, args)
		}
		// Worker's `finish` tool. The tool result's `terminate: true`
		// drives pi's natural agent_end, which our case "agent_end"
		// below handles. But the `summary` arg is the worker's
		// authoritative final answer to the driver, so we capture
		// it eagerly here so it's available the moment the driver's
		// next tick reads final_assistant_text — even if the
		// downstream agent_end is slow to propagate.
		if toolName == "finish" && args != nil {
			if summ, ok := args["summary"].(string); ok && summ != "" {
				s.mu.Lock()
				if a, ok := s.agents[agentID]; ok && a.Role == mission.RoleWorker {
					a.FinalAssistantText = truncate(summ, 1000)
				}
				s.mu.Unlock()
			}
		}
		s.publish(mission.Event{
			ID: s.nextEventID(), MissionID: missionID, AgentID: agentID,
			Kind: "worker.tool_call", Ts: time.Now(),
			Payload: map[string]any{
				"text":  summary,
				"tool":  toolName,
				"args":  args,
			},
		})

	case "tool_execution_end":
		// Optional; we render the start event as a single tile line.

	case "auto_retry_start":
		attempt, _ := ev["attempt"].(float64)
		errMsg, _ := ev["errorMessage"].(string)
		s.publish(mission.Event{
			ID: s.nextEventID(), MissionID: missionID, AgentID: agentID,
			Kind: "worker.retry", Ts: time.Now(),
			Payload: map[string]any{
				"text":    fmt.Sprintf("auto-retry %.0f: %s", attempt, errMsg),
				"attempt": attempt,
			},
		})

	case "compaction_start":
		s.publish(mission.Event{
			ID: s.nextEventID(), MissionID: missionID, AgentID: agentID,
			Kind: "worker.compacting", Ts: time.Now(),
			Payload: map[string]any{"text": "(context compaction)"},
		})

	case "agent_end":
		// Primary path is AwaitCompletion -> markWorkerCompleted in
		// runWorker. We ALSO call markWorkerCompleted here as a
		// belt-and-braces safety net: if the AwaitCompletion
		// completion-waiter race ever drops a signal (it shouldn't
		// post-race-fix, but defensive), this path catches it.
		// markWorkerCompleted is a no-op if status is already
		// terminated, so calling it twice is safe.
		//
		// Drivers (host pi processes) ALSO emit agent_end after
		// each turn, but they're persistent in v0.6 — we don't
		// auto-terminate them on agent_end. Skip the call if the
		// agent is a driver.
		s.mu.Lock()
		a := s.agents[agentID]
		s.mu.Unlock()
		if a != nil && a.Role == mission.RoleWorker && a.Status == mission.StatusRunning {
			s.markWorkerCompleted(missionID, agentID)
		}
		// Idle signal mirroring agent.streaming above. The UI
		// uses this to stop glowing the driver tile.
		s.publish(mission.Event{
			ID: s.nextEventID(), MissionID: missionID, AgentID: agentID,
			Kind: "agent.idle", Ts: time.Now(),
			Payload: map[string]any{},
		})

	case "extension_error":
		extPath, _ := ev["extensionPath"].(string)
		errMsg, _ := ev["error"].(string)
		s.publish(mission.Event{
			ID: s.nextEventID(), MissionID: missionID, AgentID: agentID,
			Kind: "worker.extension_error", Ts: time.Now(),
			Payload: map[string]any{
				"text":      fmt.Sprintf("extension error: %s", errMsg),
				"extension": extPath,
			},
		})
	}
}

// extractAssistantText pulls the text out of an assistant message,
// concatenating text content blocks and stripping thinking blocks.
func extractAssistantText(msg any) string {
	m, ok := msg.(map[string]any)
	if !ok {
		return ""
	}
	contentRaw, ok := m["content"]
	if !ok {
		return ""
	}
	// content may be a string (rare) or array of blocks
	if s, ok := contentRaw.(string); ok {
		return s
	}
	arr, ok := contentRaw.([]any)
	if !ok {
		return ""
	}
	var b strings.Builder
	for _, block := range arr {
		bm, ok := block.(map[string]any)
		if !ok {
			continue
		}
		if t, _ := bm["type"].(string); t == "text" {
			if txt, ok := bm["text"].(string); ok {
				if b.Len() > 0 {
					b.WriteString("\n")
				}
				b.WriteString(txt)
			}
		}
	}
	return b.String()
}

func summarizeToolCall(toolName string, args map[string]any) string {
	if args == nil {
		return toolName + "()"
	}
	// Pick a representative arg for display
	for _, k := range []string{"command", "path", "url", "query", "code"} {
		if v, ok := args[k].(string); ok {
			return fmt.Sprintf("%s(%s=%s)", toolName, k, truncate(v, 80))
		}
	}
	return toolName + "(...)"
}

func (s *serverState) updateTokens(agentID string, usage map[string]any) {
	get := func(k string) int64 {
		if v, ok := usage[k].(float64); ok {
			return int64(v)
		}
		return 0
	}
	getf := func(k string) float64 {
		if v, ok := usage[k].(float64); ok {
			return v
		}
		return 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	a, ok := s.agents[agentID]
	if !ok {
		return
	}
	in := get("input")
	out := get("output")
	cr := get("cacheRead")
	if in > a.TokensInput {
		a.TokensInput = in
	}
	if out > a.TokensOutput {
		a.TokensOutput = out
	}
	if cr > a.TokensCacheRead {
		a.TokensCacheRead = cr
	}
	// pi nests cost as cost.total (a float)
	if cost, ok := usage["cost"].(map[string]any); ok {
		if total := getfMap(cost, "total"); total > a.CostUSD {
			a.CostUSD = total
		}
	} else if c := getf("cost"); c > a.CostUSD {
		a.CostUSD = c
	}
	// Persist outside the lock so the SQLite call doesn't block
	// other event handlers.
	copyA := *a
	defer func() { go s.persistAgent(&copyA) }()
}

func getfMap(m map[string]any, k string) float64 {
	if v, ok := m[k].(float64); ok {
		return v
	}
	return 0
}

// --- termination + completion ---

func (s *serverState) markWorkerCompleted(missionID, workerID string) {
	now := time.Now()
	s.mu.Lock()
	w, ok := s.agents[workerID]
	if !ok {
		s.mu.Unlock()
		return
	}
	// Idempotency: don't double-fire if already terminated. The
	// dual call sites (AwaitCompletion + forwardPiEvent agent_end)
	// can both reach here for the same worker.
	if w.Status == mission.StatusTerminated {
		s.mu.Unlock()
		return
	}
	w.Status = mission.StatusTerminated
	w.Outcome = mission.StatusDone
	w.TerminatedAt = &now
	finalText := w.FinalAssistantText
	if d := s.drivers[workerID]; d != nil {
		go d.Close()
		delete(s.drivers, workerID)
	}
	s.mu.Unlock()
	s.persistAgent(w)

	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: missionID, AgentID: workerID,
		Kind: "agent.completed", Ts: time.Now(),
		Payload: map[string]any{
			"final_assistant_text": finalText,
		},
	})

	// Wake the active driver: a worker just terminated.
	s.enqueueTick(missionID, Tick{
		Reason:  tickReasonWorkerTerminated,
		AgentID: workerID,
		Payload: map[string]any{
			"final_text": finalText,
			"reason":     "clean termination",
		},
	})
}

func (s *serverState) handleDriverDisconnect(missionID, workerID string, err error) {
	if err == nil {
		return
	}
	slog.Warn("driver disconnected",
		"agent", workerID, "err", err)
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: missionID, AgentID: workerID,
		Kind: "agent.disconnected", Ts: time.Now(),
		Payload: map[string]any{"err": err.Error()},
	})
}

func (s *serverState) terminateAgent(a *mission.Agent) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	s.mu.Lock()
	d := s.drivers[a.ID]
	delete(s.drivers, a.ID)
	delete(s.driverTokens, a.ID)
	// Resolve any pending ask_operator with empty string so the
	// blocked /ask_operator handler returns and the driver pi
	// process can exit cleanly.
	if ch, ok := s.driverPendingAsk[a.ID]; ok {
		select {
		case ch <- "":
		default:
		}
		delete(s.driverPendingAsk, a.ID)
	}
	s.mu.Unlock()
	if d != nil {
		_ = d.Close()
	}

	if a.BhattiSandboxID != "" {
		if err := s.bhatti.TerminateSandbox(ctx, a.BhattiSandboxID); err != nil {
			slog.Warn("bhatti terminate failed",
				"sandbox", a.BhattiSandboxID, "err", err)
		}
	}
	now := time.Now()
	s.mu.Lock()
	a.Status = mission.StatusTerminated
	a.Outcome = "terminated_by_operator"
	a.TerminatedAt = &now
	s.mu.Unlock()
	s.persistAgent(a)
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: a.MissionID, AgentID: a.ID,
		Kind: "agent.terminated", Ts: time.Now(),
		Payload: map[string]any{"reason": "terminated by operator"},
	})
	// Wake the active driver if a worker was terminated mid-flight
	// (operator UI or driver's terminate_worker tool path).
	if a.Role == mission.RoleWorker {
		s.enqueueTick(a.MissionID, Tick{
			Reason:  tickReasonWorkerTerminated,
			AgentID: a.ID,
			Payload: map[string]any{
				"reason":     "terminated",
				"final_text": a.FinalAssistantText,
			},
		})
	}
}

func (s *serverState) failWorker(m *mission.Mission, worker *mission.Agent, reason string) {
	now := time.Now()
	s.mu.Lock()
	worker.Status = mission.StatusFailed
	worker.Outcome = mission.StatusFailed
	worker.FinalAssistantText = reason
	worker.TerminatedAt = &now
	s.mu.Unlock()
	s.persistAgent(worker)
	slog.Warn("worker failed",
		"mission", m.ID, "agent", worker.ID, "reason", reason)
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: worker.ID,
		Kind: "agent.terminated", Ts: time.Now(),
		Payload: map[string]any{"reason": reason, "outcome": "failed"},
	})
}

// --- recovery ---
//
// recoverFromStore is the v0.6 startup path. It hydrates the
// in-memory caches from SQLite, then re-spawns drivers and
// re-attaches workers for any mission whose status is still
// 'running'.
//
// Order of work:
//
//   1. Read all missions + all agents from store → fill caches.
//   2. For each running mission, kick off async recoverMission
//      that handles its driver + workers.
//   3. Driver recovery: re-spawn host pi with --continue and
//      same --session-dir; pi reads the existing JSONL and
//      keeps going. Mint a fresh driver token (old one dies
//      with the old subprocess). Operator chat works again.
//   4. Worker recovery: dial bhatti exec/ws WITH the stored
//      session_id (no cmd-spec, no session_info handshake —
//      we're attaching to an existing session, not creating).
//      Worker pi process is unchanged; events resume streaming.
//
// If a sandbox is gone (operator deleted it manually), we mark
// the worker failed instead of trying to attach. Same for a
// driver session file that doesn't exist anymore.
func (s *serverState) recoverFromStore() {
	if s.store == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	missions, err := s.store.ListMissions(ctx)
	if err != nil {
		slog.Warn("recovery: list missions failed", "err", err)
		return
	}
	agents, err := s.store.ListAllAgents(ctx)
	if err != nil {
		slog.Warn("recovery: list agents failed", "err", err)
		return
	}

	s.mu.Lock()
	for _, m := range missions {
		s.missions[m.ID] = m
	}
	for _, a := range agents {
		s.agents[a.ID] = a
	}
	s.mu.Unlock()

	running := 0
	for _, m := range missions {
		if m.Status != mission.StatusRunning {
			continue
		}
		running++
		go s.recoverMission(m)
	}
	slog.Info("recovery: hydrated from store",
		"missions", len(missions),
		"agents", len(agents),
		"running_missions", running)
}

// recoverMission re-spawns the driver and re-attaches workers
// for one mission. Called per running mission from
// recoverFromStore.
func (s *serverState) recoverMission(m *mission.Mission) {
	s.mu.Lock()
	var driverAgent *mission.Agent
	var workerAgents []*mission.Agent
	if m.DriverAgentID != "" {
		driverAgent = s.agents[m.DriverAgentID]
	}
	for _, a := range s.agents {
		if a.MissionID != m.ID || a.Role != mission.RoleWorker {
			continue
		}
		workerAgents = append(workerAgents, a)
	}
	s.mu.Unlock()

	if driverAgent != nil && driverAgent.Status == mission.StatusRunning {
		s.recoverDriver(m, driverAgent)
	}
	for _, w := range workerAgents {
		if w.Status != mission.StatusRunning {
			continue
		}
		go s.recoverWorker(m, w)
	}
}

// recoverDriver re-spawns a host pi process for the mission's
// driver agent, using pi's --continue flag against the same
// --session-dir so the conversation history is preserved.
func (s *serverState) recoverDriver(m *mission.Mission, d *mission.Agent) {
	sessDir := filepath.Join(s.driverSessionRoot, m.ID)
	if _, err := os.Stat(sessDir); err != nil {
		slog.Warn("recovery: driver session dir missing; marking driver failed",
			"mission", m.ID, "agent", d.ID, "sess_dir", sessDir)
		s.failWorker(m, d, "driver session dir missing on restart")
		return
	}

	token := randHex(32)
	s.mu.Lock()
	s.driverTokens[d.ID] = token
	s.mu.Unlock()

	// pi --continue resumes the most recent session in --session-dir.
	argv := buildDriverArgv(sessDir, s.piProvider, s.piModel, s.driverToolsPath, true)
	env := s.piEnvFromHost()
	env["KARKHANA_INTERNAL_URL"] = s.internalURL
	env["KARKHANA_DRIVER_TOKEN"] = token
	env["KARKHANA_DRIVER_ID"] = d.ID

	ctx := context.Background()
	drv, err := driver.ConnectHost(ctx, driver.HostOptions{
		Argv:      argv,
		Env:       env,
		SessionID: "host-" + m.ID,
		OnEvent: func(ev driver.Event) {
			s.forwardPiEvent(m.ID, d.ID, ev)
		},
		OnDisconnect: func(err error) {
			s.handleDriverDisconnect(m.ID, d.ID, err)
		},
	})
	if err != nil {
		slog.Warn("recovery: driver respawn failed",
			"mission", m.ID, "agent", d.ID, "err", err)
		s.failWorker(m, d, "driver respawn failed: "+err.Error())
		return
	}
	s.mu.Lock()
	s.drivers[d.ID] = drv
	s.mu.Unlock()

	slog.Info("recovery: driver re-spawned",
		"mission", m.ID, "agent", d.ID, "sess_dir", sessDir)
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: d.ID,
		Kind: "agent.driver_connected", Ts: time.Now(),
		Payload: map[string]any{
			"session_id": drv.SessionID(),
			"recovered":  true,
		},
	})

	// Re-arm tick dispatcher. Recovery loses any pending in-memory
	// ticks; the heartbeat will resync the driver within
	// tickHeartbeatInterval.
	s.startTickDispatcher(m, drv, d.ID)
}

// recoverWorker re-attaches to a running worker's pi-rpc session
// inside its bhatti sandbox, by passing the stored session_id
// to bhatti's exec/ws (no cmd spec sent; we're attaching to an
// existing piped session, not spawning a new one).
func (s *serverState) recoverWorker(m *mission.Mission, w *mission.Agent) {
	if w.BhattiSandboxID == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Verify the sandbox still exists. Operators can manually
	// delete sandboxes via the bhatti CLI; if so, the worker is
	// gone and we mark it failed.
	sb, err := s.bhatti.GetSandbox(ctx, w.BhattiSandboxID)
	if err != nil || sb == nil {
		slog.Info("recovery: worker sandbox gone; marking failed",
			"agent", w.ID, "sandbox", w.BhattiSandboxID, "err", err)
		s.failWorker(m, w, "sandbox no longer exists")
		return
	}
	if sb.Status != "running" {
		slog.Info("recovery: worker sandbox not running; marking failed",
			"agent", w.ID, "sandbox", w.BhattiSandboxID, "status", sb.Status)
		s.failWorker(m, w, "sandbox status: "+sb.Status)
		return
	}

	sessionID := w.BhattiSessionID
	if sessionID == "" {
		// Without a session ID we can't attach. Look up the
		// sandbox's sessions; if there's a single pi-rpc one,
		// adopt its ID.
		sessions, err := s.bhatti.ListSessions(ctx, w.BhattiSandboxID)
		if err != nil {
			slog.Warn("recovery: list sessions failed", "agent", w.ID, "err", err)
			s.failWorker(m, w, "list sessions failed: "+err.Error())
			return
		}
		for _, ses := range sessions {
			if !ses.Running {
				continue
			}
			joined := strings.Join(ses.Argv, " ")
			if strings.Contains(joined, "pi") {
				sessionID = ses.SessionID
				break
			}
		}
		if sessionID == "" {
			slog.Info("recovery: no live pi session in worker sandbox",
				"agent", w.ID, "sandbox", w.BhattiSandboxID)
			s.failWorker(m, w, "no live pi session")
			return
		}
		s.mu.Lock()
		w.BhattiSessionID = sessionID
		s.mu.Unlock()
		s.persistAgent(w)
	}

	drv, err := driver.AttachBhatti(ctx, s.bhatti, w.BhattiSandboxID, sessionID, driver.Options{
		OnEvent: func(ev driver.Event) {
			s.forwardPiEvent(m.ID, w.ID, ev)
		},
		OnDisconnect: func(err error) {
			s.handleDriverDisconnect(m.ID, w.ID, err)
		},
	})
	if err != nil {
		slog.Warn("recovery: worker reattach failed",
			"agent", w.ID, "session", sessionID, "err", err)
		s.failWorker(m, w, "worker reattach failed: "+err.Error())
		return
	}
	s.mu.Lock()
	s.drivers[w.ID] = drv
	s.mu.Unlock()

	slog.Info("recovery: worker re-attached",
		"agent", w.ID, "sandbox", w.BhattiSandboxID, "session", sessionID)
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: w.ID,
		Kind: "agent.driver_connected", Ts: time.Now(),
		Payload: map[string]any{
			"session_id": sessionID,
			"recovered":  true,
		},
	})
}

// --- helpers ---

// maybeLogFirstReaction logs the time-to-first-token for a
// driver or worker agent if we haven't logged it yet for this
// mission. Idempotent on (missionID, agentID).
func (s *serverState) maybeLogFirstReaction(missionID, agentID, source string) {
	s.mu.Lock()
	m := s.missions[missionID]
	a := s.agents[agentID]
	if m == nil || a == nil {
		s.mu.Unlock()
		return
	}
	logged := s.timingLogged[missionID]
	if logged == nil {
		logged = map[string]bool{}
		s.timingLogged[missionID] = logged
	}
	key := "first_reaction:" + agentID
	if logged[key] {
		s.mu.Unlock()
		return
	}
	logged[key] = true
	s.mu.Unlock()

	slog.Info("timing: first reaction",
		"mission", missionID,
		"agent", agentID,
		"role", a.Role,
		"source", source,
		"since_mission_created_ms", time.Since(m.CreatedAt).Milliseconds(),
		"since_agent_started_ms", time.Since(a.StartedAt).Milliseconds())
}

// maybeLogFirstAction logs the time-to-first-tool-call for an
// agent (driver: spawn_worker; worker: any computer-use tool).
// Idempotent on (missionID, agentID).
func (s *serverState) maybeLogFirstAction(missionID, agentID, toolName string) {
	s.mu.Lock()
	m := s.missions[missionID]
	a := s.agents[agentID]
	if m == nil || a == nil {
		s.mu.Unlock()
		return
	}
	logged := s.timingLogged[missionID]
	if logged == nil {
		logged = map[string]bool{}
		s.timingLogged[missionID] = logged
	}
	key := "first_action:" + agentID
	if logged[key] {
		s.mu.Unlock()
		return
	}
	logged[key] = true
	s.mu.Unlock()

	slog.Info("timing: first action",
		"mission", missionID,
		"agent", agentID,
		"role", a.Role,
		"tool", toolName,
		"since_mission_created_ms", time.Since(m.CreatedAt).Milliseconds(),
		"since_agent_started_ms", time.Since(a.StartedAt).Milliseconds())
}

// publish sends the event to the in-memory bus (which fans to
// connected canvas WS clients) AND persists it to SQLite. The
// store write is best-effort; failures are logged but don't
// block fan-out (the canvas is the user-visible thing).
func (s *serverState) publish(e mission.Event) {
	s.bus.Publish(e)
	// Some event kinds are TRANSIENT — they're meant for the live
	// WS stream only (UI animations / streaming thinking deltas)
	// and would generate huge replay payloads on reconnect. Skip
	// the SQLite append for those; the persistent record of what
	// happened lives in the consolidated worker.message /
	// worker.tool_call events that DO get persisted.
	switch e.Kind {
	case "agent.thinking_delta",
		"agent.text_delta",
		"agent.thinking_start",
		"agent.thinking_end",
		"agent.streaming",
		"agent.idle":
		return
	}
	if s.store != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		if err := s.store.AppendEvent(ctx, e); err != nil {
			slog.Warn("event persist failed",
				"kind", e.Kind, "agent", e.AgentID, "err", err)
		}
	}
}

// persistMission writes the mission record to SQLite. Called on
// create + every status change. Best-effort; logs on failure.
func (s *serverState) persistMission(m *mission.Mission) {
	if s.store == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := s.store.CreateMission(ctx, m); err != nil {
		slog.Warn("mission persist failed", "mission", m.ID, "err", err)
	}
}

// persistAgent writes one agent's current state to SQLite. Called
// on every meaningful state change (sandbox created, kasmvnc
// published, status flipped, terminated, costs updated, etc.).
func (s *serverState) persistAgent(a *mission.Agent) {
	if s.store == nil || a == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := s.store.UpsertAgent(ctx, a); err != nil {
		slog.Warn("agent persist failed", "agent", a.ID, "err", err)
	}
}

// --- internal driver-tool callbacks ---
// These endpoints are called by the host driver pi process via
// HTTP, in response to the LLM invoking one of the 5 driver
// tools (see extensions/driver-tools/index.ts). They are NOT
// exposed to the operator UI and authed via per-driver bearer
// tokens minted at driver-spawn time.

// authDriver looks up the driver agent by ID, validates the
// bearer token, and returns (driver_id, mission, ok). Writes
// the appropriate HTTP error and returns ok=false on miss.
func (s *serverState) authDriver(w http.ResponseWriter, r *http.Request, driverID string) (*mission.Agent, *mission.Mission, bool) {
	authz := r.Header.Get("Authorization")
	token := strings.TrimPrefix(authz, "Bearer ")
	if token == "" || token == authz {
		http.Error(w, "missing bearer", http.StatusUnauthorized)
		return nil, nil, false
	}
	s.mu.Lock()
	want, hasToken := s.driverTokens[driverID]
	agent, hasAgent := s.agents[driverID]
	var m *mission.Mission
	if hasAgent {
		m = s.missions[agent.MissionID]
	}
	s.mu.Unlock()
	if !hasToken || !hasAgent || m == nil {
		http.Error(w, "unknown driver", http.StatusNotFound)
		return nil, nil, false
	}
	if token != want {
		http.Error(w, "bad token", http.StatusForbidden)
		return nil, nil, false
	}
	return agent, m, true
}

// handleInternalDriver routes /internal/driver/{driver_id}/<action>
// to the right tool handler.
func (s *serverState) handleInternalDriver(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	rest := strings.TrimPrefix(r.URL.Path, "/internal/driver/")
	parts := strings.SplitN(rest, "/", 2)
	if len(parts) != 2 {
		http.Error(w, "path must be /internal/driver/<id>/<action>",
			http.StatusNotFound)
		return
	}
	driverID, action := parts[0], parts[1]

	driverAgent, m, ok := s.authDriver(w, r, driverID)
	if !ok {
		return
	}

	switch action {
	case "spawn_worker":
		s.handleToolSpawnWorker(w, r, driverAgent, m)
	case "spawn_workers":
		s.handleToolSpawnWorkers(w, r, driverAgent, m)
	case "steer_worker":
		s.handleToolSteerWorker(w, r, driverAgent, m)
	case "terminate_worker":
		s.handleToolTerminateWorker(w, r, driverAgent, m)
	case "notes/write":
		s.handleToolWriteNote(w, r, driverAgent, m)
	case "notes/read":
		s.handleToolReadNotes(w, r, m)
	case "notes/list":
		s.handleToolListNotes(w, r, m)
	case "wait_for_workers":
		// Vestigial: kept so old/cached driver-tool extensions
		// don't 404. Returns immediately with current worker state
		// and a soft reminder that the driver is auto-ticked now.
		s.handleToolWaitForWorkers(w, r, m)
	case "ask_operator":
		s.handleToolAskOperator(w, r, driverAgent, m)
	case "report_progress":
		s.handleToolReportProgress(w, r, driverAgent, m)
	case "finish":
		s.handleToolFinish(w, r, driverAgent, m)
	default:
		http.Error(w, "unknown action: "+action, http.StatusNotFound)
	}
}

// handleToolSteerWorker implements the driver-tool steer_worker.
// Sends a pi-rpc steer message into the target worker's stream.
// Worker may be mid-tool-call or idle; pi handles both (steer
// queues for after the current tool batch completes).
func (s *serverState) handleToolSteerWorker(w http.ResponseWriter, r *http.Request, driverAgent *mission.Agent, m *mission.Mission) {
	var body struct {
		WorkerID string `json:"worker_id"`
		Hint     string `json:"hint"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if body.WorkerID == "" || body.Hint == "" {
		http.Error(w, "worker_id and hint required", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	worker, ok := s.agents[body.WorkerID]
	if !ok || worker.MissionID != m.ID {
		s.mu.Unlock()
		http.Error(w, "worker not in this mission", http.StatusNotFound)
		return
	}
	if worker.Status != mission.StatusRunning {
		s.mu.Unlock()
		http.Error(w, "worker is not running", http.StatusConflict)
		return
	}
	drv := s.drivers[body.WorkerID]
	s.mu.Unlock()
	if drv == nil {
		http.Error(w, "worker driver not attached", http.StatusServiceUnavailable)
		return
	}

	// Wrap the hint so the worker sees it as a steer from the
	// supervisor, not as a fresh task. Include the literal phrase
	// the worker preamble expects so it knows this is mid-flight
	// guidance.
	wrapped := "[supervisor steer from driver]\n" + body.Hint +
		"\n\nAdjust your current work to incorporate this; keep going " +
		"toward your task. Continue writing notes incrementally and " +
		"call finish() when done."
	if err := drv.Steer(r.Context(), wrapped); err != nil {
		http.Error(w, "steer failed: "+err.Error(), http.StatusBadGateway)
		return
	}

	// Publish an event so the canvas can pulse the
	// driver→worker spawn edge.
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: body.WorkerID,
		Kind: "driver.steer_worker", Ts: time.Now(),
		Payload: map[string]any{
			"driver_id": driverAgent.ID,
			"hint":      body.Hint,
		},
	})

	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// handleToolTerminateWorker implements terminate_worker.
// Force-stops a worker: closes the pi-rpc driver, destroys the
// bhatti sandbox, marks the agent terminated. Used by the
// supervisor when a worker is curl-looping, off-task, or no
// longer needed.
func (s *serverState) handleToolTerminateWorker(w http.ResponseWriter, r *http.Request, driverAgent *mission.Agent, m *mission.Mission) {
	var body struct {
		WorkerID string `json:"worker_id"`
		Reason   string `json:"reason"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if body.WorkerID == "" {
		http.Error(w, "worker_id required", http.StatusBadRequest)
		return
	}
	s.mu.Lock()
	worker, ok := s.agents[body.WorkerID]
	if !ok || worker.MissionID != m.ID {
		s.mu.Unlock()
		http.Error(w, "worker not in this mission", http.StatusNotFound)
		return
	}
	worker.FinalAssistantText = truncate(
		"[terminated by supervisor] "+body.Reason, 1000)
	s.mu.Unlock()

	// terminateAgent already handles bhatti teardown + state
	// cleanup; it ends in markWorkerCompleted which fires the
	// agent.completed event and ticks the driver.
	go s.terminateAgent(worker)

	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: body.WorkerID,
		Kind: "driver.terminate_worker", Ts: time.Now(),
		Payload: map[string]any{
			"driver_id": driverAgent.ID,
			"reason":    body.Reason,
		},
	})

	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *serverState) handleToolSpawnWorker(w http.ResponseWriter, r *http.Request, driverAgent *mission.Agent, m *mission.Mission) {
	var body struct {
		Task string `json:"task"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(body.Task) == "" {
		http.Error(w, "task required", http.StatusBadRequest)
		return
	}
	worker, err := s.spawnWorker(driverAgent.ID, m, body.Task)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"worker_id":  worker.ID,
		"sandbox_id": worker.BhattiSandboxID, // may be empty if still booting
		"status":     worker.Status,
	})
}

// handleToolWriteNote is the driver's path for adding blackboard
// entries. Workers reach the same notes table via the
// tool_execution_start interception in forwardPiEvent (they
// can't easily HTTP to the host from a sandbox); drivers, which
// run on the host, use this HTTP endpoint for symmetry with
// their other tools.
func (s *serverState) handleToolWriteNote(w http.ResponseWriter, r *http.Request, driverAgent *mission.Agent, m *mission.Mission) {
	var body struct {
		Key     string `json:"key"`
		Content string `json:"content"`
		Summary string `json:"summary,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(body.Key) == "" || strings.TrimSpace(body.Content) == "" {
		http.Error(w, "key and content required", http.StatusBadRequest)
		return
	}
	id := s.appendBlackboardNote(m.ID, driverAgent.ID, body.Key, body.Content, body.Summary)
	writeJSON(w, http.StatusOK, map[string]any{"note_id": id})
}

func (s *serverState) handleToolReadNotes(w http.ResponseWriter, r *http.Request, m *mission.Mission) {
	var body struct {
		Key string `json:"key"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json: "+err.Error(), http.StatusBadRequest)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	notes, err := s.store.ListNotes(ctx, m.ID, body.Key)
	if err != nil {
		http.Error(w, "read notes failed: "+err.Error(), 500)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"notes": notes})
}

func (s *serverState) handleToolListNotes(w http.ResponseWriter, r *http.Request, m *mission.Mission) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	manifest, err := s.store.NoteManifest(ctx, m.ID)
	if err != nil {
		http.Error(w, "manifest failed: "+err.Error(), 500)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"manifest": manifest})
}

// persistBlackboardWrite is the goroutine-launched handler for a
// worker's write_note tool call (intercepted from the pi-rpc
// event stream). Drivers use the HTTP path above; we share the
// underlying append + event-emission logic.
func (s *serverState) persistBlackboardWrite(missionID, agentID string, args map[string]any) {
	key, _ := args["key"].(string)
	content, _ := args["content"].(string)
	summary, _ := args["summary"].(string)
	if strings.TrimSpace(key) == "" || strings.TrimSpace(content) == "" {
		slog.Warn("write_note ignored: empty key or content",
			"mission", missionID, "agent", agentID)
		return
	}
	s.appendBlackboardNote(missionID, agentID, key, content, summary)
}

// appendBlackboardNote does the DB write + event emission. Called
// from both the worker interception path (persistBlackboardWrite)
// and the driver HTTP path (handleToolWriteNote). Returns the
// new note's id (0 on failure).
func (s *serverState) appendBlackboardNote(missionID, agentID, key, content, summary string) int64 {
	if s.store == nil {
		return 0
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	note := &store.Note{
		MissionID: missionID,
		Key:       key,
		Content:   content,
		Summary:   summary,
		AgentID:   agentID,
		Ts:        time.Now(),
	}
	id, err := s.store.AppendNote(ctx, note)
	if err != nil {
		slog.Warn("note append failed",
			"mission", missionID, "agent", agentID, "key", key, "err", err)
		return 0
	}
	// Fire a worker.note_write event so the frontend can pulse
	// the agent→blackboard edge and append a new entry to the
	// blackboard tile in real time.
	// Include full content in the event payload so the frontend
	// doesn't need a REST roundtrip to render the note. Notes are
	// typically a few KB; even at 100 notes/mission this is fine
	// in the event stream (compared to a single agent_end which
	// carries 100× more in pi's stream).
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: missionID, AgentID: agentID,
		Kind: "worker.note_write", Ts: note.Ts,
		Payload: map[string]any{
			"note_id": id,
			"key":     key,
			"content": content,
			"summary": summary,
		},
	})

	// Wake the active driver: a worker (or the driver itself)
	// just wrote to the blackboard. The dispatcher coalesces if
	// many notes arrive in quick succession.
	s.enqueueTick(missionID, Tick{
		Reason:  tickReasonNoteWrite,
		AgentID: agentID,
		Payload: map[string]any{
			"key":     key,
			"summary": summary,
			"note_id": id,
		},
	})
	return id
}

// handleToolSpawnWorkers is the bulk version: one HTTP call,
// N workers spawned concurrently. The driver LLM calls this
// instead of spawn_worker repeatedly when fanning out.
//
// Concurrency: spawnWorker is itself non-blocking (creates the
// agent record + kicks off a runWorker goroutine, returns the
// new worker_id). So we just call it N times in a loop — the
// goroutines do the parallel sandbox boot, KasmVNC publish,
// pi-rpc connect dance. No semaphore needed; bhatti's API
// handles the concurrent CreateSandbox calls fine.
func (s *serverState) handleToolSpawnWorkers(w http.ResponseWriter, r *http.Request, driverAgent *mission.Agent, m *mission.Mission) {
	var body struct {
		Tasks []string `json:"tasks"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if len(body.Tasks) == 0 {
		http.Error(w, "tasks required", http.StatusBadRequest)
		return
	}
	// Soft-cap matches the schema's maxItems on the TS side.
	// Without this guard a confused agent could spawn 1000
	// sandboxes — expensive and likely to trip bhatti rate limits.
	if len(body.Tasks) > 20 {
		http.Error(w, "too many tasks (max 20)", http.StatusBadRequest)
		return
	}

	workers := make([]map[string]any, 0, len(body.Tasks))
	for _, task := range body.Tasks {
		if strings.TrimSpace(task) == "" {
			continue
		}
		worker, err := s.spawnWorker(driverAgent.ID, m, task)
		if err != nil {
			// Continue with the rest; partial success is
			// preferable to refusing the whole batch. The driver
			// will see fewer worker IDs than tasks and can
			// decide what to do.
			slog.Warn("bulk spawn: one worker failed",
				"err", err, "task", truncate(task, 80))
			continue
		}
		workers = append(workers, map[string]any{
			"worker_id":  worker.ID,
			"sandbox_id": worker.BhattiSandboxID,
			"status":     worker.Status,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"workers": workers})
}

// handleToolWaitForWorkers is vestigial in the active-driver
// architecture. The driver no longer needs to block; Karkhana
// auto-ticks it on each material event (note write, worker
// terminated, heartbeat). We keep this route alive so that an
// older cached driver-tools extension calling wait_for_workers
// doesn't 404 the entire turn.
//
// Behavior: returns IMMEDIATELY with a state snapshot, never
// blocks. The response also carries a `notice` string telling
// the LLM to use ticks instead, so it learns and stops calling
// this tool on subsequent turns.
func (s *serverState) handleToolWaitForWorkers(w http.ResponseWriter, r *http.Request, m *mission.Mission) {
	var body struct {
		WorkerIDs []string `json:"worker_ids"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	s.mu.Lock()
	result := []map[string]any{}
	for _, wid := range body.WorkerIDs {
		a, ok := s.agents[wid]
		if !ok {
			result = append(result, map[string]any{
				"worker_id": wid,
				"status":    "unknown",
			})
			continue
		}
		result = append(result, map[string]any{
			"worker_id":            a.ID,
			"status":               a.Status,
			"outcome":              a.Outcome,
			"final_assistant_text": a.FinalAssistantText,
			"cost_usd":             a.CostUSD,
		})
	}
	s.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{
		"workers":   result,
		"timed_out": false,
		"notice": "wait_for_workers is DEPRECATED in active-driver mode. " +
			"Karkhana auto-ticks you when workers contribute notes or " +
			"terminate — do NOT call wait_for_workers again. Just end " +
			"your turn after spawning workers; you'll be ticked on every " +
			"material event with full context.",
	})
	_ = m
}

func (s *serverState) handleToolAskOperator(w http.ResponseWriter, r *http.Request, driverAgent *mission.Agent, m *mission.Mission) {
	var body struct {
		Question string `json:"question"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json: "+err.Error(), http.StatusBadRequest)
		return
	}

	// Publish the question for the UI to render with chat-blocked
	// styling.
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: driverAgent.ID,
		Kind: "driver.ask_operator", Ts: time.Now(),
		Payload: map[string]any{"question": body.Question},
	})

	ch := make(chan string, 1)
	s.mu.Lock()
	if _, exists := s.driverPendingAsk[driverAgent.ID]; exists {
		s.mu.Unlock()
		http.Error(w, "another ask_operator is already pending",
			http.StatusConflict)
		return
	}
	s.driverPendingAsk[driverAgent.ID] = ch
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.driverPendingAsk, driverAgent.ID)
		s.mu.Unlock()
	}()

	select {
	case answer := <-ch:
		writeJSON(w, http.StatusOK, map[string]any{"answer": answer})
	case <-time.After(30 * time.Minute):
		http.Error(w, "operator did not answer within 30m",
			http.StatusRequestTimeout)
	case <-r.Context().Done():
		return
	}
}

func (s *serverState) handleToolReportProgress(w http.ResponseWriter, r *http.Request, driverAgent *mission.Agent, m *mission.Mission) {
	var body struct {
		Message string `json:"message"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json: "+err.Error(), http.StatusBadRequest)
		return
	}
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: driverAgent.ID,
		Kind: "driver.report_progress", Ts: time.Now(),
		Payload: map[string]any{"message": body.Message},
	})
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *serverState) handleToolFinish(w http.ResponseWriter, r *http.Request, driverAgent *mission.Agent, m *mission.Mission) {
	var body struct {
		Result string `json:"result"`
		Title  string `json:"title,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json: "+err.Error(), http.StatusBadRequest)
		return
	}
	// finish() now produces a typed artifact in addition to
	// updating the driver agent's FinalAssistantText. The artifact
	// is the operator-visible deliverable; FinalAssistantText is
	// the legacy chat-bubble path that we keep for UI fallback.
	artifactID := "art_" + randHex(12)
	title := body.Title
	if title == "" {
		title = truncate(m.Goal, 80)
	}
	art := &store.Artifact{
		ID:         artifactID,
		MissionID:  m.ID,
		Type:       "markdown:report",
		Title:      title,
		Content:    body.Result,
		Summary:    truncate(body.Result, 160),
		ProducedBy: driverAgent.ID,
	}
	if s.store != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		if err := s.store.CreateArtifact(ctx, art); err != nil {
			slog.Warn("artifact create failed",
				"mission", m.ID, "agent", driverAgent.ID, "err", err)
		}
		cancel()
	}

	s.mu.Lock()
	driverAgent.FinalAssistantText = body.Result
	s.mu.Unlock()
	s.persistAgent(driverAgent)
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: driverAgent.ID,
		Kind: "driver.finish", Ts: time.Now(),
		Payload: map[string]any{
			"result":      body.Result,
			"artifact_id": artifactID,
			"title":       title,
		},
	})
	// Surface the new artifact on the canvas as a dedicated event
	// so the frontend can render an artifact tile immediately.
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: driverAgent.ID,
		Kind: "artifact.created", Ts: time.Now(),
		Payload: map[string]any{
			"artifact_id": artifactID,
			"type":        art.Type,
			"title":       title,
			"summary":     art.Summary,
		},
	})
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":          true,
		"artifact_id": artifactID,
	})
}

// --- operator chat ---
// POST /api/agents/:id/prompt with { text: "..." } sends a
// follow-up message from the operator to a driver. If the driver
// is mid-turn (streaming), the message is steered; otherwise
// it's a fresh prompt. If there's a pending ask_operator, the
// message resolves that and isn't forwarded as a prompt.

func (s *serverState) handleAgentPrompt(w http.ResponseWriter, r *http.Request, agentID string) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var body struct {
		Text string `json:"text"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if strings.TrimSpace(body.Text) == "" {
		http.Error(w, "text required", http.StatusBadRequest)
		return
	}

	s.mu.Lock()
	agent, hasAgent := s.agents[agentID]
	drv, hasDrv := s.drivers[agentID]
	pendingAsk, hasAsk := s.driverPendingAsk[agentID]
	s.mu.Unlock()
	if !hasAgent {
		http.Error(w, "no such agent", http.StatusNotFound)
		return
	}

	// Echo into the event stream so the chat UI shows it.
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: agent.MissionID, AgentID: agentID,
		Kind: "operator.message", Ts: time.Now(),
		Payload: map[string]any{"text": body.Text},
	})

	if hasAsk {
		select {
		case pendingAsk <- body.Text:
		default:
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"ok": true, "resolved_ask": true,
		})
		return
	}

	if !hasDrv {
		http.Error(w, "agent has no live driver", http.StatusConflict)
		return
	}

	ctx := r.Context()

	// Policy: chat-app semantics. If the driver is mid-flight, the
	// operator's new message takes precedence over whatever the
	// driver was doing — abort the current operation, then send
	// the message as a fresh prompt.
	//
	// We considered pi-rpc's `steer` (queue for after current
	// turn completes) but it failed in practice: when the driver
	// blocks on wait_for_workers, the current turn never
	// completes, so steer messages pile up invisibly and the
	// operator sees nothing happen. Abort+prompt is the right
	// default for a chat surface.
	var err error
	if drv.IsStreaming() {
		if aerr := drv.Abort(ctx); aerr != nil {
			slog.Warn("abort before re-prompt failed",
				"agent", agentID, "err", aerr)
		}
		// Brief pause so pi processes the abort before the new
		// prompt arrives — otherwise pi may reject the prompt
		// with "streaming, must use steer".
		time.Sleep(100 * time.Millisecond)
	}
	if err = drv.Prompt(ctx, body.Text); err != nil {
		http.Error(w, "forward to driver: "+err.Error(),
			http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// ReplayEvents implements canvas.Replayer — returns every event
// across every running mission so a freshly-connected canvas
// client sees the full conversation history of every active
// driver / worker. Closed missions' events aren't replayed; the
// operator can scroll the missions list later if we add an
// archive view.
func (s *serverState) ReplayEvents() ([]mission.Event, error) {
	if s.store == nil {
		return nil, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	s.mu.Lock()
	missionIDs := make([]string, 0, len(s.missions))
	for id, m := range s.missions {
		if m.Status != mission.StatusRunning {
			continue
		}
		missionIDs = append(missionIDs, id)
	}
	s.mu.Unlock()

	var all []mission.Event
	for _, mid := range missionIDs {
		evs, err := s.store.AllEventsForMission(ctx, mid)
		if err != nil {
			slog.Warn("replay events for mission failed",
				"mission", mid, "err", err)
			continue
		}
		all = append(all, evs...)
	}
	return all, nil
}

// Resolve implements kasmproxy.Resolver — returns the upstream URL
// and Basic-auth creds for an agent ID.
func (s *serverState) Resolve(agentID string) (string, string, string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	a, ok := s.agents[agentID]
	if !ok || a.KasmVNCURL == "" {
		return "", "", "", false
	}
	return a.KasmVNCURL, a.KasmVNCUser, a.KasmVNCPass, true
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func randHex(n int) string {
	b := make([]byte, n/2+1)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)[:n]
}

func withCORS(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		if r.Method == http.MethodOptions {
			w.WriteHeader(204)
			return
		}
		h.ServeHTTP(w, r)
	})
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
