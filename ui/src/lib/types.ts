// Mirrors `pkg/mission/types.go`. Keep in sync; the Go side is
// the source of truth.

export type AgentRole = "driver" | "worker";

export interface Mission {
  id: string;
  goal: string;
  status: string;
  driver_agent_id?: string;
  created_by: string;
  created_at: string;
  completed_at?: string;
}

export interface Agent {
  id: string;
  mission_id: string;
  parent_agent_id?: string;
  role: AgentRole;
  spawn_kind: string;

  bhatti_sandbox_id?: string;
  spawned_from_snapshot_id?: string;
  kasmvnc_url?: string;
  agent_endpoint_url?: string;

  task?: string;
  recipe?: string;

  status: string;
  outcome?: string;
  final_assistant_text?: string;

  tokens_input: number;
  tokens_output: number;
  cost_usd: number;

  started_at: string;
  terminated_at?: string;
}

export interface KEvent {
  id: number;
  mission_id: string;
  agent_id?: string;
  kind: string;
  payload: Record<string, unknown>;
  ts: string;
}

// Flat list of event-kind strings the canvas reacts to. Keep in
// sync with the kinds Go emits. Unknown kinds are ignored
// (forward-compat).
export const KNOWN_EVENT_KINDS = [
  "mission.created",
  "mission.completed",
  "mission.abandoned",

  "agent.spawned",
  "agent.forked",
  "agent.terminated",
  "agent.completed",
  "agent.outcome",

  "driver.report_progress",
  "driver.prompt_sent",
  "driver.followup_sent",
  "driver.finish",

  "worker.thinking",
  "worker.tool_call",
  "worker.message",
] as const;
