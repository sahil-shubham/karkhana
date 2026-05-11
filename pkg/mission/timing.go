// Mission timing — derives latency milestones from the events
// stream so operators can answer questions like "how long did
// the driver take to react?" without reading log files.
//
// The events table is the source of truth: every event has a
// monotonic id and a timestamp, and we already record the
// milestones we care about as part of normal operation. This
// file just consolidates the math.

package mission

import "time"

// MissionTiming is the per-mission latency breakdown.
//
// Milestones are nullable because not every mission reaches
// every phase (e.g. a mission that hangs before driver_connect
// has those fields nil). Durations are nil when either bound
// is missing.
type MissionTiming struct {
	MissionID string `json:"mission_id"`

	// Wall-clock anchors (UTC).
	CreatedAt              time.Time  `json:"created_at"`
	DriverSpawnedAt        *time.Time `json:"driver_spawned_at,omitempty"`
	DriverConnectedAt      *time.Time `json:"driver_connected_at,omitempty"`
	FirstPromptSentAt      *time.Time `json:"first_prompt_sent_at,omitempty"`
	FirstAssistantTokenAt  *time.Time `json:"first_assistant_token_at,omitempty"`
	FirstWorkerSpawnedAt   *time.Time `json:"first_worker_spawned_at,omitempty"`
	FirstWorkerConnectedAt *time.Time `json:"first_worker_connected_at,omitempty"`
	FirstWorkerActionAt    *time.Time `json:"first_worker_action_at,omitempty"`
	DriverFinishAt         *time.Time `json:"driver_finish_at,omitempty"`
	CompletedAt            *time.Time `json:"completed_at,omitempty"`

	// Computed durations (ms). Each answers a question the
	// operator might ask:
	//
	//   driver_warmup_ms       host pi spawn + handshake. The
	//                          fixed cost of starting a mission.
	//   driver_first_token_ms  prompt sent → first thinking/text
	//                          arrives. LLM provider latency.
	//   driver_first_action_ms prompt sent → first spawn_worker
	//                          tool call. Driver "thinking time"
	//                          before acting.
	//   first_worker_boot_ms   spawn → worker pi connected.
	//                          Sandbox boot + KasmVNC + pi conn.
	//   first_worker_react_ms  worker connected → first tool call.
	//                          Worker LLM time-to-action.
	//   end_to_end_ms          mission created → driver finish.
	//                          The thing the operator timed.
	DriverWarmupMs      *int64 `json:"driver_warmup_ms,omitempty"`
	DriverFirstTokenMs  *int64 `json:"driver_first_token_ms,omitempty"`
	DriverFirstActionMs *int64 `json:"driver_first_action_ms,omitempty"`
	FirstWorkerBootMs   *int64 `json:"first_worker_boot_ms,omitempty"`
	FirstWorkerReactMs  *int64 `json:"first_worker_react_ms,omitempty"`
	EndToEndMs          *int64 `json:"end_to_end_ms,omitempty"`

	// Per-worker breakdown for parallel-fanout missions. Sorted
	// by spawn order. Each entry's BootMs measures how long that
	// individual worker took from agent.spawning to its first
	// real action — useful to spot the slow one in a fanout.
	Workers []WorkerTiming `json:"workers,omitempty"`
}

// WorkerTiming is one worker's milestone breakdown within a mission.
type WorkerTiming struct {
	AgentID         string     `json:"agent_id"`
	SpawnedAt       *time.Time `json:"spawned_at,omitempty"`
	ConnectedAt     *time.Time `json:"connected_at,omitempty"`
	FirstActionAt   *time.Time `json:"first_action_at,omitempty"`
	TerminatedAt    *time.Time `json:"terminated_at,omitempty"`
	BootMs          *int64     `json:"boot_ms,omitempty"`
	FirstReactMs    *int64     `json:"first_react_ms,omitempty"`
	TotalDurationMs *int64     `json:"total_duration_ms,omitempty"`
}

// ComputeMissionTiming walks an event stream and produces the
// timing breakdown. Caller passes the mission's CreatedAt as the
// anchor + all events for the mission ordered by id ascending.
//
// We deliberately key on event.kind (the one stable identifier
// for a milestone) and the agent ID where relevant. Adding new
// kinds is non-breaking; missing ones leave fields nil.
func ComputeMissionTiming(missionID string, createdAt time.Time, events []Event) MissionTiming {
	t := MissionTiming{MissionID: missionID, CreatedAt: createdAt}

	// driver agent ID is the first agent.spawning event with
	// role=driver. We use it to disambiguate worker events.
	var driverID string
	type workerSlot struct {
		idx int
		w   WorkerTiming
	}
	workersByID := map[string]*workerSlot{}
	var workerOrder []string

	getWorker := func(id string) *workerSlot {
		if w, ok := workersByID[id]; ok {
			return w
		}
		ws := &workerSlot{idx: len(workerOrder), w: WorkerTiming{AgentID: id}}
		workersByID[id] = ws
		workerOrder = append(workerOrder, id)
		return ws
	}

	for _, ev := range events {
		ts := ev.Ts
		payload, _ := ev.Payload.(map[string]any)
		role := ""
		if payload != nil {
			role, _ = payload["role"].(string)
		}

		switch ev.Kind {
		case "agent.spawning":
			if role == "driver" && t.DriverSpawnedAt == nil {
				t.DriverSpawnedAt = ptr(ts)
				driverID = ev.AgentID
			} else if role == "worker" {
				ws := getWorker(ev.AgentID)
				if ws.w.SpawnedAt == nil {
					ws.w.SpawnedAt = ptr(ts)
				}
				if t.FirstWorkerSpawnedAt == nil {
					t.FirstWorkerSpawnedAt = ptr(ts)
				}
			}

		case "agent.driver_connected":
			if ev.AgentID == driverID && t.DriverConnectedAt == nil {
				t.DriverConnectedAt = ptr(ts)
			} else if ev.AgentID != driverID && ev.AgentID != "" {
				ws := getWorker(ev.AgentID)
				if ws.w.ConnectedAt == nil {
					ws.w.ConnectedAt = ptr(ts)
				}
				if t.FirstWorkerConnectedAt == nil {
					t.FirstWorkerConnectedAt = ptr(ts)
				}
			}

		case "driver.prompt_sent":
			// Only the FIRST one (initial goal) is the start of
			// timing. Follow-up prompts don't reset the clock.
			if ev.AgentID == driverID && t.FirstPromptSentAt == nil {
				t.FirstPromptSentAt = ptr(ts)
			}

		case "worker.thinking", "worker.message":
			// First "production" output from the driver \u2014
			// thinking blocks count too because they're streamed
			// before the assistant text and represent first-token.
			if ev.AgentID == driverID && t.FirstAssistantTokenAt == nil {
				t.FirstAssistantTokenAt = ptr(ts)
			}

		case "worker.tool_call":
			if ev.AgentID == driverID {
				// We'll catch the actual spawn via
				// agent.spawning, but a tool_call from the
				// driver is a useful proxy too. Skipped for now.
				_ = payload
			} else if ev.AgentID != "" {
				ws := getWorker(ev.AgentID)
				if ws.w.FirstActionAt == nil {
					ws.w.FirstActionAt = ptr(ts)
				}
				if t.FirstWorkerActionAt == nil {
					t.FirstWorkerActionAt = ptr(ts)
				}
			}

		case "driver.finish":
			if ev.AgentID == driverID && t.DriverFinishAt == nil {
				t.DriverFinishAt = ptr(ts)
			}

		case "agent.completed", "agent.terminated":
			if ev.AgentID != "" && ev.AgentID != driverID {
				ws := getWorker(ev.AgentID)
				if ws.w.TerminatedAt == nil {
					ws.w.TerminatedAt = ptr(ts)
				}
			}
		}
	}

	// Compute durations.
	t.DriverWarmupMs = msBetween(&t.CreatedAt, t.DriverConnectedAt)
	t.DriverFirstTokenMs = msBetween(t.FirstPromptSentAt, t.FirstAssistantTokenAt)
	t.DriverFirstActionMs = msBetween(t.FirstPromptSentAt, t.FirstWorkerSpawnedAt)
	t.FirstWorkerBootMs = msBetween(t.FirstWorkerSpawnedAt, t.FirstWorkerConnectedAt)
	t.FirstWorkerReactMs = msBetween(t.FirstWorkerConnectedAt, t.FirstWorkerActionAt)
	t.EndToEndMs = msBetween(&t.CreatedAt, t.DriverFinishAt)

	// Worker breakdown.
	for _, id := range workerOrder {
		ws := workersByID[id]
		ws.w.BootMs = msBetween(ws.w.SpawnedAt, ws.w.ConnectedAt)
		ws.w.FirstReactMs = msBetween(ws.w.ConnectedAt, ws.w.FirstActionAt)
		ws.w.TotalDurationMs = msBetween(ws.w.SpawnedAt, ws.w.TerminatedAt)
		t.Workers = append(t.Workers, ws.w)
	}

	return t
}

func ptr(t time.Time) *time.Time { return &t }

func msBetween(a, b *time.Time) *int64 {
	if a == nil || b == nil || a.IsZero() || b.IsZero() {
		return nil
	}
	d := b.Sub(*a).Milliseconds()
	if d < 0 {
		return nil
	}
	return &d
}
