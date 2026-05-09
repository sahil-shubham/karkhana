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
  createMission: (goal: string) =>
    jsonFetch<Mission>("/api/missions", {
      method: "POST",
      body: JSON.stringify({ goal }),
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
};
