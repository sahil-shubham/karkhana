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

	state := &serverState{
		bus:          bus,
		bhatti:       bhattiCli,
		missions:     map[string]*mission.Mission{},
		agents:       map[string]*mission.Agent{},
		drivers:      map[string]*driver.Driver{},
		piProvider:   cfg.PiProvider,
		piModel:      cfg.PiModel,
		workerImage:  cfg.WorkerImage,
		piExtensions: cfg.PiExtensions,
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

	// Recover any sandboxes we own but lost track of (Karkhana
	// restart, or the operator hit Cmd+R in the browser).
	go state.recoverFromBhatti()

	mux := http.NewServeMux()
	mux.HandleFunc("/api/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, 200, map[string]any{"status": "ok"})
	})
	mux.HandleFunc("/api/missions", state.handleMissions)
	mux.HandleFunc("/api/missions/", state.handleMissionByID)
	mux.HandleFunc("/api/agents", state.handleAgents)
	mux.HandleFunc("/api/agents/", state.handleAgentByID)
	mux.HandleFunc("/api/events", canvas.EventStreamHandler(bus))
	mux.HandleFunc("/proxy/", kasmproxy.Handler("/proxy/", state))

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
	missions map[string]*mission.Mission
	agents   map[string]*mission.Agent
	drivers  map[string]*driver.Driver // keyed by agentID
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

		s.publish(mission.Event{
			ID:        s.nextEventID(),
			MissionID: m.ID,
			Kind:      "mission.created",
			Payload:   map[string]any{"goal": m.Goal},
			Ts:        time.Now(),
		})

		go s.runMission(m)
		writeJSON(w, 201, m)

	default:
		http.Error(w, "method not allowed", 405)
	}
}

func (s *serverState) handleMissionByID(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Path[len("/api/missions/"):]
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

// deleteMission tears down everything attached to a mission:
// terminates each worker's pi-rpc driver, destroys each bhatti
// sandbox, removes the in-memory mission + agent rows, emits a
// terminal event. Idempotent and best-effort — if bhatti is
// unreachable, we still clean up Karkhana state.
func (s *serverState) deleteMission(m *mission.Mission) {
	slog.Info("delete mission", "mission", m.ID, "goal", truncate(m.Goal, 60))

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
	for id, a := range s.agents {
		if a.MissionID == m.ID {
			delete(s.agents, id)
		}
	}
	s.mu.Unlock()

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

// handleAgentByID supports DELETE /api/agents/:id for terminate.
func (s *serverState) handleAgentByID(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Path[len("/api/agents/"):]
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

func (s *serverState) runMission(m *mission.Mission) {
	workerID := "agent_" + randHex(12)
	worker := &mission.Agent{
		ID:        workerID,
		MissionID: m.ID,
		Role:      mission.RoleWorker,
		SpawnKind: mission.SpawnSpawn,
		Task:      m.Goal,
		Recipe:    "computer-use",
		Status:    mission.StatusRunning,
		StartedAt: time.Now(),
	}
	s.mu.Lock()
	s.agents[workerID] = worker
	s.mu.Unlock()

	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: workerID,
		Kind: "agent.spawning", Ts: time.Now(),
		Payload: map[string]any{
			"role":  "worker",
			"task":  m.Goal,
			"stage": "creating sandbox",
		},
	})

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

	slog.Info("agent driver connected",
		"agent", workerID, "session", drv.SessionID())
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: workerID,
		Kind: "agent.driver_connected", Ts: time.Now(),
		Payload: map[string]any{"session_id": drv.SessionID()},
	})

	// 5. Send the operator's goal as the first prompt, wrapped
	// with the desktop-context preamble so the agent knows it has
	// a visible KasmVNC display and (when applicable) the
	// computer-use toolset for clicking/typing/scrolling.
	hasComputerUse := len(s.piExtensions) > 0
	prompt := wrapGoalWithDesktopContext(m.Goal, hasComputerUse)
	if err := drv.Prompt(context.Background(), prompt); err != nil {
		s.failWorker(m, worker, "send prompt failed: "+err.Error())
		return
	}
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: workerID,
		Kind: "driver.prompt_sent", Ts: time.Now(),
		Payload: map[string]any{"text": m.Goal},
	})

	// 6. Wait for agent_end in a goroutine; mark worker complete.
	// Doesn't block — runMission returns and the driver's readLoop
	// keeps streaming events to the canvas.
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
You are running inside a sandboxed Linux microVM (Debian + XFCE4 + Chromium) streamed live to your operator over KasmVNC. The desktop resolution is 1280x720, DISPLAY=:99.

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
  1. bash: "chromium --no-sandbox --new-window <url> &" to launch (or click an existing browser icon)
  2. wait(2)  — let the window appear and the page render
  3. screenshot() if needed, then click/type/scroll to interact

Do NOT interpret bare hostnames like "bhatti.sh" as local files. They are URLs (prefix https:// when launching).

Narrate what you're doing in short assistant messages between tool calls. The operator watches both your reasoning and the desktop live.
</environment>`
	} else {
		env = `<environment>
You are running inside a sandboxed Linux microVM (Debian + XFCE4 + Chromium) streamed live to your operator over KasmVNC. DISPLAY=:99 — GUI apps you launch from bash will appear in the operator's iframe in real time.

When the goal says "open <site>", "visit <url>", "browse to X", or anything that implies a web UI, launch chromium so the operator can SEE it:

  chromium --no-sandbox --new-window <url> &

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

	switch t {
	case "agent_start":
		s.publish(mission.Event{
			ID: s.nextEventID(), MissionID: missionID, AgentID: agentID,
			Kind: "worker.thinking", Ts: time.Now(),
			Payload: map[string]any{"text": "(agent started)"},
		})

	case "turn_start":
		// Quiet event; useful if we want a turn counter but skip for now.

	case "turn_end":
		// Extract token usage to update accounting.
		if msg, ok := ev["message"].(map[string]any); ok {
			if usage, ok := msg["usage"].(map[string]any); ok {
				s.updateTokens(agentID, usage)
			}
		}

	case "message_end":
		// One per assistant message. Extract the text.
		text := extractAssistantText(ev["message"])
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
		// Handled by AwaitCompletion -> markWorkerCompleted; nothing to do here.

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
	w.Status = mission.StatusTerminated
	w.Outcome = mission.StatusDone
	w.TerminatedAt = &now
	if d := s.drivers[workerID]; d != nil {
		go d.Close()
		delete(s.drivers, workerID)
	}
	s.mu.Unlock()

	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: missionID, AgentID: workerID,
		Kind: "agent.completed", Ts: time.Now(),
		Payload: map[string]any{
			"final_assistant_text": w.FinalAssistantText,
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
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: a.MissionID, AgentID: a.ID,
		Kind: "agent.terminated", Ts: time.Now(),
		Payload: map[string]any{"reason": "terminated by operator"},
	})
}

func (s *serverState) failWorker(m *mission.Mission, worker *mission.Agent, reason string) {
	now := time.Now()
	s.mu.Lock()
	worker.Status = mission.StatusFailed
	worker.Outcome = mission.StatusFailed
	worker.FinalAssistantText = reason
	worker.TerminatedAt = &now
	s.mu.Unlock()
	slog.Warn("worker failed",
		"mission", m.ID, "agent", worker.ID, "reason", reason)
	s.publish(mission.Event{
		ID: s.nextEventID(), MissionID: m.ID, AgentID: worker.ID,
		Kind: "agent.terminated", Ts: time.Now(),
		Payload: map[string]any{"reason": reason, "outcome": "failed"},
	})
}

// --- recovery ---

// recoverFromBhatti scans existing bhatti sandboxes and rebuilds
// the Karkhana state for any tagged with our metadata. Useful
// when Karkhana restarts mid-mission. We do NOT re-attach the
// pi-rpc driver here; that's a future enhancement (the bhatti
// session reattach pattern from `Karkhana.AgentRPC`).
func (s *serverState) recoverFromBhatti() {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	sbs, err := s.bhatti.ListSandboxes(ctx)
	if err != nil {
		slog.Warn("recovery: list sandboxes failed", "err", err)
		return
	}
	recovered := 0
	for _, sb := range sbs {
		if !strings.HasPrefix(sb.Name, "kk-") {
			continue
		}
		if sb.Status != "running" {
			continue
		}
		// Reconstruct the agent ID from the sandbox name (last 8
		// chars of agent_id were used as alias; we have to do a
		// best effort here since metadata isn't returned in list).
		// Use a synthetic ID; the operator can still see the tile.
		workerID := "agent_recovered_" + sb.Name[3:]
		missionID := "msn_recovered_" + sb.Name[3:]
		now := time.Now()

		s.mu.Lock()
		if _, exists := s.agents[workerID]; exists {
			s.mu.Unlock()
			continue
		}
		s.missions[missionID] = &mission.Mission{
			ID:        missionID,
			Goal:      "(recovered) " + sb.Name,
			Status:    mission.StatusRunning,
			CreatedBy: "recovery",
			CreatedAt: sb.CreatedAt,
		}
		s.agents[workerID] = &mission.Agent{
			ID:               workerID,
			MissionID:        missionID,
			Role:             mission.RoleWorker,
			SpawnKind:        mission.SpawnSpawn,
			Task:             "(recovered: original task lost)",
			Recipe:           "computer-use",
			BhattiSandboxID:  sb.ID,
			KasmVNCProxyPath: "/proxy/" + workerID + "/",
			Status:           mission.StatusRunning,
			StartedAt:        sb.CreatedAt,
		}
		s.mu.Unlock()

		// Fetch creds for the proxy to work
		go func(workerID, sbID string, sb bhatti.Sandbox) {
			fctx, fcancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer fcancel()
			user, pass, err := s.fetchKasmCreds(fctx, sbID)
			if err != nil {
				slog.Warn("recovery: vnc-creds failed", "agent", workerID, "err", err)
				return
			}
			kasmURL := ""
			if len(sb.URLs) > 0 {
				kasmURL = sb.URLs[0]
			}
			s.mu.Lock()
			if a, ok := s.agents[workerID]; ok {
				a.KasmVNCURL = kasmURL
				a.KasmVNCUser = user
				a.KasmVNCPass = pass
			}
			s.mu.Unlock()
			s.publish(mission.Event{
				ID: s.nextEventID(), MissionID: "msn_recovered_" + sb.Name[3:], AgentID: workerID,
				Kind: "agent.spawned", Ts: now,
				Payload: map[string]any{
					"role":             "worker",
					"task":             "(recovered)",
					"sandbox_id":       sbID,
					"kasmvnc_url":      "/proxy/" + workerID + "/",
					"kasmvnc_upstream": kasmURL,
				},
			})
		}(workerID, sb.ID, sb)

		recovered++
	}
	if recovered > 0 {
		slog.Info("recovery: rebuilt agents from bhatti", "count", recovered)
	}
}

// --- helpers ---

func (s *serverState) publish(e mission.Event) {
	s.bus.Publish(e)
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
