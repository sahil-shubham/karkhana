// Thin fetch wrapper for /api/* endpoints.

import type { Agent, Mission } from "./types";
import { apiURL } from "./config";

async function jsonFetch<T>(path: string, init?: RequestInit): Promise<T> {
  const resp = await fetch(apiURL(path), {
    headers: { "content-type": "application/json", ...init?.headers },
    ...init,
  });
  if (!resp.ok) {
    const body = await resp.text();
    throw new Error(`${resp.status} ${resp.statusText}: ${body}`);
  }
  return resp.json() as Promise<T>;
}

export const api = {
  // Optional canvas_x / canvas_y come from the right-click drop
  // point. The backend stores them on the driver agent so the
  // mission tile lands at that point on the next page-load.
  createMission: (
    goal: string,
    origin?: { x: number; y: number },
  ) =>
    jsonFetch<Mission>("/api/missions", {
      method: "POST",
      body: JSON.stringify({
        goal,
        canvas_x: origin?.x,
        canvas_y: origin?.y,
      }),
    }),

  listMissions: () => jsonFetch<Mission[]>("/api/missions"),

  getMission: (id: string) => jsonFetch<Mission>(`/api/missions/${id}`),

  deleteMission: (id: string) =>
    fetch(apiURL(`/api/missions/${encodeURIComponent(id)}`), {
      method: "DELETE",
    }),

  listAgents: (missionID?: string) =>
    jsonFetch<Agent[]>(
      missionID
        ? `/api/agents?mission_id=${encodeURIComponent(missionID)}`
        : "/api/agents",
    ),

  terminateAgent: (agentID: string) =>
    fetch(apiURL(`/api/agents/${encodeURIComponent(agentID)}`), {
      method: "DELETE",
    }),

  // Send an operator message to a driver. The backend decides
  // between pi-rpc `prompt` (idle) and `steer` (streaming) based
  // on the driver's IsStreaming() state. If the driver has an
  // outstanding ask_operator, this resolves it instead.
  promptAgent: (agentID: string, text: string) =>
    jsonFetch<{ ok: boolean; resolved_ask?: boolean }>(
      `/api/agents/${encodeURIComponent(agentID)}/prompt`,
      {
        method: "POST",
        body: JSON.stringify({ text }),
      },
    ),
};
