// tick.go — the active-driver loop.
//
// Concept: the driver is not a one-shot batch coordinator. It's
// a live supervisor that wakes whenever something material
// happens on the mission (a worker writes a note, a worker
// terminates, a heartbeat elapses) and is given a structured
// briefing about what changed. It narrates a reaction and may
// take an action (steer/terminate/spawn/finish) — then idles
// again, ready for the next tick.
//
// Why this matters: every other research agent on the market
// runs its supervisor invisibly between worker boots. Karkhana's
// supervisor runs IN FRONT of the operator, narrating reasoning
// as it reacts to live blackboard updates. The tick loop is
// the substrate that makes that watchable.
//
// Implementation:
//   - One TickDispatcher per (mission, driver) pair. Owned by
//     serverState; created when a driver is spawned, cancelled
//     when the mission terminates / is deleted.
//   - Events arrive via enqueueTick (called from
//     appendBlackboardNote, markWorkerCompleted, and a wall-clock
//     heartbeat).
//   - The dispatcher COALESCES bursts: ticks arriving within a
//     short window (tickCoalesceWindow) are merged into a single
//     prompt. This avoids waking the driver 8× when 8 workers
//     write notes simultaneously.
//   - Each tick fires via driver.FollowUp() — pi-rpc's natural
//     "queue this message for after the current turn idles"
//     primitive. The dispatcher does NOT need to manually wait
//     for IsStreaming() to be false; pi handles serialization.
//   - On Karkhana restart, dispatchers are re-created by the
//     recovery path; in-flight pending ticks are LOST (they're
//     in-memory only). This is acceptable: a fresh heartbeat
//     fires within tickHeartbeatInterval to re-sync the driver.

package main

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/sahil-shubham/karkhana/pkg/agent/driver"
	"github.com/sahil-shubham/karkhana/pkg/mission"
	"github.com/sahil-shubham/karkhana/pkg/store"
)

// Tunables. Conservative defaults; revisit after operator feedback.
const (
	// How long to wait after a tick lands before firing the
	// prompt. Short enough to feel real-time, long enough to
	// coalesce rapid bursts (e.g. 5 workers writing notes within
	// a 1s window after a spawn_workers fan-out).
	tickCoalesceWindow = 2500 * time.Millisecond

	// Minimum spacing between two driver follow_up prompts.
	// Prevents runaway cost if the workers write very rapidly.
	// If many ticks land during this period, they all coalesce
	// into the next prompt.
	tickMinSpacing = 4 * time.Second

	// Wall-clock heartbeat. Even with no events, ping the driver
	// every interval so it narrates progress (or notices a stalled
	// worker). Skipped if there are no running workers.
	tickHeartbeatInterval = 45 * time.Second

	// Queue capacity per dispatcher. Bursts above this drop
	// oldest; survival of the freshest is the right policy.
	tickQueueCapacity = 256
)

// TickReason enumerates the kinds of events that trigger a
// dispatcher wake. Used only for log + prompt-context labelling.
type TickReason string

const (
	tickReasonNoteWrite        TickReason = "note_write"
	tickReasonWorkerTerminated TickReason = "worker_terminated"
	tickReasonWorkerSpawned    TickReason = "worker_spawned"
	tickReasonHeartbeat        TickReason = "heartbeat"
)

// Tick is one queued wake-up event.
type Tick struct {
	Reason  TickReason
	Ts      time.Time
	AgentID string         // owning agent (worker that wrote, terminated, etc.)
	Payload map[string]any // event-specific context (note_id, key, summary, …)
}

// TickDispatcher runs one supervisor loop for a single driver.
// All public methods are safe to call from any goroutine.
type TickDispatcher struct {
	missionID string
	driverID  string

	state *serverState // for mission-state lookups (workers, notes, …)
	drv   *driver.Driver

	queue chan Tick

	ctx    context.Context
	cancel context.CancelFunc

	// lastFiredAt is when we last sent a follow_up prompt to the
	// driver. Used to enforce tickMinSpacing. Protected by mu.
	mu          sync.Mutex
	lastFiredAt time.Time
}

func newTickDispatcher(s *serverState, m *mission.Mission, drv *driver.Driver, driverAgentID string) *TickDispatcher {
	ctx, cancel := context.WithCancel(s.ctx)
	return &TickDispatcher{
		missionID: m.ID,
		driverID:  driverAgentID,
		state:     s,
		drv:       drv,
		queue:     make(chan Tick, tickQueueCapacity),
		ctx:       ctx,
		cancel:    cancel,
	}
}

// Enqueue is non-blocking; if the queue is full, the newest
// tick replaces the oldest. We don't want a slow driver to
// permanently lock event delivery.
func (d *TickDispatcher) Enqueue(t Tick) {
	if t.Ts.IsZero() {
		t.Ts = time.Now()
	}
	select {
	case d.queue <- t:
	default:
		// Queue full — drop the oldest, enqueue the new.
		select {
		case <-d.queue:
		default:
		}
		select {
		case d.queue <- t:
		default:
			// If even the second push fails, give up; another
			// tick will arrive soon anyway.
			slog.Warn("tick dropped: dispatcher queue saturated",
				"mission", d.missionID, "reason", t.Reason)
		}
	}
}

// Stop terminates the dispatcher. Idempotent.
func (d *TickDispatcher) Stop() {
	d.cancel()
}

// Run drives the dispatcher loop. Blocks until ctx is cancelled.
func (d *TickDispatcher) Run() {
	var pending []Tick
	var coalesceTimer *time.Timer
	var heartbeatTimer = time.NewTimer(tickHeartbeatInterval)
	defer heartbeatTimer.Stop()

	resetCoalesce := func() {
		if coalesceTimer == nil {
			coalesceTimer = time.NewTimer(tickCoalesceWindow)
		} else {
			if !coalesceTimer.Stop() {
				select {
				case <-coalesceTimer.C:
				default:
				}
			}
			coalesceTimer.Reset(tickCoalesceWindow)
		}
	}

	clearCoalesce := func() {
		if coalesceTimer == nil {
			return
		}
		if !coalesceTimer.Stop() {
			select {
			case <-coalesceTimer.C:
			default:
			}
		}
		coalesceTimer = nil
	}

	fire := func(reason string) {
		clearCoalesce()
		if len(pending) == 0 {
			return
		}
		// Respect minimum spacing between follow_ups.
		d.mu.Lock()
		since := time.Since(d.lastFiredAt)
		d.mu.Unlock()
		if since < tickMinSpacing {
			// Re-arm the coalesce timer for the remaining time;
			// pending will fire then with the accumulated batch.
			remaining := tickMinSpacing - since
			if coalesceTimer == nil {
				coalesceTimer = time.NewTimer(remaining)
			} else {
				coalesceTimer.Reset(remaining)
			}
			return
		}

		// Build and send. Snapshot pending so concurrent Enqueues
		// don't mutate while buildTickPrompt reads.
		batch := pending
		pending = nil

		prompt := d.buildTickPrompt(batch, reason)
		// PromptOrQueue: starts a new run if the driver is idle
		// (which is the common case after each turn ends), or
		// queues via pi's follow-up semantics if a turn is still
		// in flight. Raw FollowUp can NOT wake an idle agent
		// because pi only drains the follow-up queue between
		// turns within a single run — after agent_end fires the
		// run is done and follow_up is a no-op.
		if err := d.drv.PromptOrQueue(d.ctx, prompt); err != nil {
			slog.Warn("tick prompt failed",
				"mission", d.missionID, "driver", d.driverID, "err", err)
			return
		}
		d.mu.Lock()
		d.lastFiredAt = time.Now()
		d.mu.Unlock()
		slog.Info("tick fired",
			"mission", d.missionID, "driver", d.driverID,
			"reason", reason, "batch_size", len(batch))
	}

	for {
		var coalesceC <-chan time.Time
		if coalesceTimer != nil {
			coalesceC = coalesceTimer.C
		}

		select {
		case <-d.ctx.Done():
			return

		case t := <-d.queue:
			pending = append(pending, t)
			resetCoalesce()

		case <-coalesceC:
			fire("coalesce_window")

		case <-heartbeatTimer.C:
			// Heartbeat: enqueue a synthetic tick IF there are
			// running workers; otherwise the driver is either
			// in idle synthesis or post-mission and shouldn't
			// be poked.
			if d.state.missionHasRunningWorkers(d.missionID) {
				pending = append(pending, Tick{
					Reason: tickReasonHeartbeat,
					Ts:     time.Now(),
				})
				// Don't wait for coalesce window on heartbeat.
				fire("heartbeat")
			}
			heartbeatTimer.Reset(tickHeartbeatInterval)
		}
	}
}

// buildTickPrompt synthesizes one "live supervisor briefing"
// prompt from a coalesced batch of ticks plus a fresh snapshot
// of mission state.
//
// Format goals:
//   - Compact. Driver's context is precious; don't repeat the
//     full mission goal here (it's already in conversation
//     history).
//   - High-signal. Lead with what's NEW (the events that woke
//     us); follow with a state snapshot so the driver doesn't
//     have to call list_notes every tick.
//   - Action-oriented. End with the supervisor protocol so the
//     LLM is reminded of its options.
func (d *TickDispatcher) buildTickPrompt(batch []Tick, fireReason string) string {
	var sb strings.Builder
	now := time.Now().UTC().Format("15:04:05Z")
	sb.WriteString(fmt.Sprintf("[karkhana tick · %s · reason=%s]\n\n", now, fireReason))

	// Section: what just changed.
	sb.WriteString("Since your last check-in:\n")
	if len(batch) == 0 {
		sb.WriteString("- (heartbeat, no new events)\n")
	} else {
		// De-duplicate verbose floods: collapse repeated
		// note_write events from the same agent+key into one
		// line with a count. Worker_terminated and heartbeat
		// always render verbatim.
		type key struct {
			agent string
			k     string
		}
		noteCount := map[key]int{}
		var noteOrder []key
		noteLatest := map[key]string{}

		for _, t := range batch {
			switch t.Reason {
			case tickReasonNoteWrite:
				k := key{
					agent: t.AgentID,
					k:     stringOr(t.Payload, "key", "?"),
				}
				if _, exists := noteCount[k]; !exists {
					noteOrder = append(noteOrder, k)
				}
				noteCount[k]++
				if summ := stringOr(t.Payload, "summary", ""); summ != "" {
					noteLatest[k] = summ
				}
			case tickReasonWorkerTerminated:
				reason := stringOr(t.Payload, "reason", "(text-only response)")
				final := stringOr(t.Payload, "final_text", "")
				if final != "" && len(final) > 200 {
					final = final[:200] + "…"
				}
				sb.WriteString(fmt.Sprintf("- worker %s TERMINATED. final: %q (reason: %s)\n",
					shortID(t.AgentID), final, reason))
			case tickReasonWorkerSpawned:
				task := stringOr(t.Payload, "task", "")
				if len(task) > 120 {
					task = task[:120] + "…"
				}
				sb.WriteString(fmt.Sprintf("- worker %s SPAWNED. task: %q\n",
					shortID(t.AgentID), task))
			case tickReasonHeartbeat:
				// rendered later
			}
		}
		// Render note_writes
		for _, k := range noteOrder {
			latest := noteLatest[k]
			if latest == "" {
				latest = "(no summary)"
			}
			c := noteCount[k]
			if c == 1 {
				sb.WriteString(fmt.Sprintf("- worker %s wrote note under '%s': %s\n",
					shortID(k.agent), k.k, latest))
			} else {
				sb.WriteString(fmt.Sprintf("- worker %s wrote %d notes under '%s' (latest: %s)\n",
					shortID(k.agent), c, k.k, latest))
			}
		}
		// Heartbeat lines (typically 1).
		for _, t := range batch {
			if t.Reason == tickReasonHeartbeat {
				sb.WriteString("- (heartbeat)\n")
				break // collapse repeated heartbeats
			}
		}
	}

	// Section: state snapshot.
	sb.WriteString("\nMission state:\n")
	d.state.writeTickSnapshot(&sb, d.missionID, d.driverID)

	// Section: supervisor protocol reminder. Short.
	sb.WriteString("\n")
	sb.WriteString("Supervisor protocol:\n")
	sb.WriteString("- Narrate your reasoning in 1-2 sentences (the operator is watching live).\n")
	sb.WriteString("- If nothing material requires action, end with '(watching)' and call no tools.\n")
	sb.WriteString("- If you want to act, use one tool then end your turn: spawn_worker(s), steer_worker, terminate_worker, write_note, or finish (when ready to synthesize).\n")
	sb.WriteString("- DO NOT call wait_for_workers; Karkhana auto-ticks you on every material event.\n")
	return sb.String()
}

// missionHasRunningWorkers is a state helper used by the
// heartbeat path. Locks serverState briefly.
func (s *serverState) missionHasRunningWorkers(missionID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, a := range s.agents {
		if a.MissionID != missionID {
			continue
		}
		if a.Role != mission.RoleWorker {
			continue
		}
		if a.Status == mission.StatusRunning {
			return true
		}
	}
	return false
}

// writeTickSnapshot composes the "current state" section of the
// tick prompt: worker statuses, blackboard manifest, basic
// timings/cost. Caller holds no locks; we acquire as needed.
func (s *serverState) writeTickSnapshot(sb *strings.Builder, missionID, driverAgentID string) {
	// --- workers ---
	s.mu.Lock()
	type wrow struct {
		id, status, finalText string
	}
	var workers []wrow
	var totalCost float64
	var m *mission.Mission
	for _, a := range s.agents {
		if a.MissionID != missionID {
			continue
		}
		totalCost += a.CostUSD
		if a.Role != mission.RoleWorker {
			if a.Role == mission.RoleDriver {
				// stash mission ref via map; not actually needed
				_ = a
			}
			continue
		}
		workers = append(workers, wrow{
			id:        a.ID,
			status:    string(a.Status),
			finalText: a.FinalAssistantText,
		})
	}
	m = s.missions[missionID]
	s.mu.Unlock()

	if len(workers) == 0 {
		sb.WriteString("- no workers yet (you haven't spawned any).\n")
	} else {
		sb.WriteString(fmt.Sprintf("- workers (%d):\n", len(workers)))
		for _, w := range workers {
			line := fmt.Sprintf("    %s: %s", shortID(w.id), w.status)
			if w.status != "running" && w.finalText != "" {
				ft := w.finalText
				if len(ft) > 180 {
					ft = ft[:180] + "…"
				}
				line += fmt.Sprintf(" — final: %q", ft)
			}
			sb.WriteString(line + "\n")
		}
	}

	// --- blackboard manifest ---
	if s.store != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		manifest, err := s.store.NoteManifest(ctx, missionID)
		if err != nil {
			sb.WriteString(fmt.Sprintf("- blackboard: (read failed: %v)\n", err))
		} else if len(manifest) == 0 {
			sb.WriteString("- blackboard: empty\n")
		} else {
			sb.WriteString("- blackboard:\n")
			for _, e := range manifest {
				sb.WriteString(fmt.Sprintf("    %s ×%d (latest by %s: %s)\n",
					e.Key, e.Count, shortID(e.LatestAgent),
					truncate(e.LatestSummary, 80)))
			}
		}
	}

	// --- timings / cost ---
	if m != nil {
		elapsed := time.Since(m.CreatedAt).Truncate(time.Second)
		sb.WriteString(fmt.Sprintf("- elapsed: %s · workers cost: $%.3f\n", elapsed, totalCost))
	}
}

// --- helpers ---

func stringOr(m map[string]any, k, fallback string) string {
	if m == nil {
		return fallback
	}
	if v, ok := m[k].(string); ok {
		return v
	}
	return fallback
}

func shortID(id string) string {
	if len(id) <= 6 {
		return id
	}
	return id[len(id)-6:]
}

// --- serverState glue ---

// enqueueTick is the entry point used by appendBlackboardNote /
// markWorkerCompleted / etc. to wake the active driver. No-op if
// there's no dispatcher for the mission (e.g. driver hasn't been
// spawned yet, or mission was already torn down).
func (s *serverState) enqueueTick(missionID string, t Tick) {
	s.tickMu.Lock()
	d := s.tickDispatchers[missionID]
	s.tickMu.Unlock()
	if d == nil {
		return
	}
	d.Enqueue(t)
}

// startTickDispatcher creates and runs the dispatcher for a
// mission's driver. Called from runMission once the driver is
// connected.
func (s *serverState) startTickDispatcher(m *mission.Mission, drv *driver.Driver, driverAgentID string) {
	d := newTickDispatcher(s, m, drv, driverAgentID)
	s.tickMu.Lock()
	// Cancel any stale dispatcher (recovery flow re-spawns).
	if old := s.tickDispatchers[m.ID]; old != nil {
		old.Stop()
	}
	s.tickDispatchers[m.ID] = d
	s.tickMu.Unlock()
	go d.Run()
	slog.Info("tick dispatcher started",
		"mission", m.ID, "driver", driverAgentID)
}

// stopTickDispatcher tears down a mission's dispatcher. Called
// from mission deletion or driver disconnect.
func (s *serverState) stopTickDispatcher(missionID string) {
	s.tickMu.Lock()
	d := s.tickDispatchers[missionID]
	delete(s.tickDispatchers, missionID)
	s.tickMu.Unlock()
	if d != nil {
		d.Stop()
	}
}

// (sanity: store interface satisfied; if NoteManifest signature
// changes upstream this fails to compile and we catch it.)
var _ interface {
	NoteManifest(ctx context.Context, missionID string) ([]store.NoteManifestEntry, error)
} = (*store.Store)(nil)
