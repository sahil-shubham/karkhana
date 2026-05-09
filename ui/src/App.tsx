// App — top-level layout. Two columns: ChatPanel on the left
// (operator's side), Canvas on the right (the agent fleet).

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ReactFlowProvider } from "@xyflow/react";

import { ChatPanel } from "./components/ChatPanel";
import { Canvas } from "./components/Canvas";
import { connectEvents, type ConnState } from "./lib/ws";
import { api } from "./lib/api";
import { apiURL } from "./lib/config";
import type { Agent, KEvent, Mission } from "./lib/types";

// Each running worker gets exactly one <iframe> on the page,
// keyed by agent ID and parked in this hidden pool. AgentTile
// reparents the iframe into its slot on mount and back to the
// pool on unmount — so switching missions or zooming the canvas
// never tears down a live KasmVNC connection. See WorkerView in
// AgentTile.tsx for the slot-side of this dance.
const IFRAME_POOL_ID = "karkhana-iframe-pool";
function kasmIframeID(agentID: string): string {
  return `kasm-iframe-${agentID}`;
}
function buildKasmURL(agent: Agent): string | undefined {
  if (!agent.kasmvnc_url || agent.kasmvnc_url === "about:blank") return undefined;
  const base = agent.kasmvnc_url.startsWith("/")
    ? apiURL(agent.kasmvnc_url)
    : agent.kasmvnc_url;
  const sep = base.includes("?") ? "&" : "?";
  return `${base}${sep}resize=remote&autoconnect=1`;
}

export default function App() {
  const [missions, setMissions] = useState<Mission[]>([]);
  const [activeMissionID, setActiveMissionID] = useState<string | null>(null);
  const [agents, setAgents] = useState<Map<string, Agent>>(new Map());
  const [eventsByAgent, setEventsByAgent] = useState<Map<string, KEvent[]>>(
    new Map(),
  );
  const [connState, setConnState] = useState<ConnState>("connecting");

  // ---- WS subscription ----
  useEffect(() => {
    const ws = connectEvents({
      onConnState: setConnState,
      onEvent: (event) => {
        // mission lifecycle
        if (event.kind === "mission.created") {
          // Fetch the new mission record (the WS event doesn't have
          // the full Mission). Best-effort.
          api
            .listMissions()
            .then(setMissions)
            .catch(() => {});
          setActiveMissionID((cur) => cur ?? event.mission_id);
        }
        if (event.kind === "mission.completed") {
          setMissions((ms) =>
            ms.map((m) =>
              m.id === event.mission_id ? { ...m, status: "done" } : m,
            ),
          );
        }

        // agent lifecycle (incremental — also handles refresh-recovered agents)
        if (
          (event.kind === "agent.spawning" ||
            event.kind === "agent.spawned" ||
            event.kind === "agent.completed" ||
            event.kind === "agent.terminated" ||
            event.kind === "agent.disconnected" ||
            event.kind === "agent.driver_connected" ||
            event.kind === "agent.forked") &&
          event.agent_id
        ) {
          const agentID = event.agent_id;
          setAgents((cur) => {
            const next = new Map(cur);
            const existing = next.get(agentID);
            const role =
              (event.payload?.role as string) === "driver"
                ? "driver"
                : "worker";
            const kasmURL = event.payload?.kasmvnc_url as string | undefined;
            const sandboxID = event.payload?.sandbox_id as string | undefined;

            if (event.kind === "agent.spawning" && !existing) {
              next.set(agentID, {
                id: agentID,
                mission_id: event.mission_id,
                parent_agent_id: event.payload?.parent as string | undefined,
                role,
                spawn_kind: role === "driver" ? "root" : "spawn",
                task: event.payload?.task as string | undefined,
                recipe: role === "worker" ? "computer-use" : undefined,
                kasmvnc_url: undefined,
                status: "running",
                tokens_input: 0,
                tokens_output: 0,
                cost_usd: 0,
                started_at: event.ts,
              });
            } else if (event.kind === "agent.spawned") {
              const base = existing ?? {
                id: agentID,
                mission_id: event.mission_id,
                role,
                spawn_kind: role === "driver" ? "root" : "spawn",
                task: event.payload?.task as string | undefined,
                recipe: role === "worker" ? "computer-use" : undefined,
                tokens_input: 0,
                tokens_output: 0,
                cost_usd: 0,
                started_at: event.ts,
                status: "running",
              };
              next.set(agentID, {
                ...base,
                bhatti_sandbox_id: sandboxID ?? base.bhatti_sandbox_id,
                kasmvnc_url: kasmURL ?? base.kasmvnc_url,
              });
            } else if (existing) {
              if (event.kind === "agent.completed") {
                next.set(agentID, {
                  ...existing,
                  status: "terminated",
                  outcome: "done",
                  final_assistant_text: event.payload?.final_assistant_text as
                    | string
                    | undefined,
                  terminated_at: event.ts,
                });
              } else if (
                event.kind === "agent.terminated" ||
                event.kind === "agent.disconnected"
              ) {
                next.set(agentID, {
                  ...existing,
                  status: "failed",
                  outcome:
                    (event.payload?.outcome as string | undefined) ?? "failed",
                  final_assistant_text:
                    (event.payload?.reason as string | undefined) ??
                    (event.payload?.err as string | undefined) ??
                    existing.final_assistant_text,
                  terminated_at: event.ts,
                });
              }
            }
            return next;
          });
        }

        // append to per-agent event log
        if (event.agent_id) {
          setEventsByAgent((cur) => {
            const next = new Map(cur);
            const arr = next.get(event.agent_id!) ?? [];
            const trimmed = [...arr, event].slice(-200);
            next.set(event.agent_id!, trimmed);
            return next;
          });
        }
      },
    });
    return () => ws.close();
  }, []);

  // ---- mount: load missions, auto-select latest ----
  useEffect(() => {
    api
      .listMissions()
      .then((ms) => {
        // Sort by created_at desc; auto-select the most recent.
        const sorted = [...ms].sort((a, b) =>
          b.created_at.localeCompare(a.created_at),
        );
        setMissions(sorted);
        if (sorted.length > 0) {
          setActiveMissionID((cur) => cur ?? sorted[0].id);
        }
      })
      .catch((e) => console.warn("listMissions failed", e));
  }, []);

  // ---- on mission select: hydrate agents from server ----
  // Without this, refreshing the browser leaves the canvas empty
  // because the WS only streams *new* events, not historical state.
  const lastFetchedMissionRef = useRef<string | null>(null);
  useEffect(() => {
    if (!activeMissionID) return;
    if (lastFetchedMissionRef.current === activeMissionID) return;
    lastFetchedMissionRef.current = activeMissionID;

    api
      .listAgents(activeMissionID)
      .then((list) => {
        setAgents((cur) => {
          const next = new Map(cur);
          for (const a of list) {
            // Don't clobber a more-recent in-memory copy if we have one
            const existing = next.get(a.id);
            if (
              existing &&
              existing.terminated_at &&
              !a.terminated_at
            ) {
              continue;
            }
            next.set(a.id, a);
          }
          return next;
        });
      })
      .catch((e) => console.warn("listAgents failed", e));
  }, [activeMissionID]);

  // ---- callbacks ----
  const handleCreate = useCallback(async (goal: string) => {
    try {
      const m = await api.createMission(goal);
      setMissions((ms) => [m, ...ms.filter((x) => x.id !== m.id)]);
      setActiveMissionID(m.id);
    } catch (e) {
      console.error("createMission failed", e);
    }
  }, []);

  const handleTerminateAgent = useCallback(async (agentID: string) => {
    if (!confirm("Terminate this agent? The sandbox will be destroyed.")) return;
    try {
      await api.terminateAgent(agentID);
    } catch (e) {
      console.error("terminate failed", e);
    }
  }, []);

  const handleDeleteMission = useCallback(
    async (id: string) => {
      const m = missions.find((x) => x.id === id);
      const label = m ? `"${m.goal.slice(0, 60)}"` : id;
      if (
        !confirm(
          `Delete mission ${label}? All worker sandboxes will be terminated.`,
        )
      ) {
        return;
      }
      try {
        await api.deleteMission(id);
        setMissions((ms) => ms.filter((x) => x.id !== id));
        setAgents((cur) => {
          const next = new Map(cur);
          next.forEach((a, aid) => {
            if (a.mission_id === id) next.delete(aid);
          });
          return next;
        });
        setActiveMissionID((cur) => (cur === id ? null : cur));
      } catch (e) {
        console.error("deleteMission failed", e);
      }
    },
    [missions],
  );

  const handleHome = useCallback(() => {
    setActiveMissionID(null);
  }, []);

  // ---- iframe pool reconciliation ----
  // For every running worker with a KasmVNC URL, ensure exactly
  // one <iframe> exists in the pool; for every iframe whose agent
  // is gone (terminated, deleted, mission deleted), tear it down.
  // We do this imperatively (createElement, appendChild, remove)
  // because React re-renders + xyflow node mounts cannot be
  // trusted to preserve iframe lifecycle through their
  // reconciliation cycles.
  const poolRef = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    const pool = poolRef.current;
    if (!pool) return;

    const desired = new Map<string, string>(); // agentID -> URL
    agents.forEach((a) => {
      if (a.role !== "worker") return;
      if (a.status !== "running") return;
      const url = buildKasmURL(a);
      if (!url) return;
      desired.set(a.id, url);
    });

    // Remove iframes whose agent is no longer running. Note:
    // they may currently be reparented INTO a tile slot, so we
    // search the whole document, not just the pool.
    const all = document.querySelectorAll<HTMLIFrameElement>(
      `iframe[data-kasm-agent]`,
    );
    all.forEach((el) => {
      const id = el.dataset.kasmAgent!;
      if (!desired.has(id)) {
        el.remove();
      }
    });

    // Add iframes for new running workers.
    desired.forEach((url, agentID) => {
      if (document.getElementById(kasmIframeID(agentID))) return; // already alive
      const iframe = document.createElement("iframe");
      iframe.id = kasmIframeID(agentID);
      iframe.dataset.kasmAgent = agentID;
      iframe.src = url;
      iframe.allow = "clipboard-read; clipboard-write";
      iframe.style.cssText =
        "width:100%;height:100%;border:none;background:#000;display:block;";
      pool.appendChild(iframe);
    });
  }, [agents]);

  const visibleAgents = useMemo(() => {
    if (!activeMissionID) return new Map<string, Agent>();
    const out = new Map<string, Agent>();
    agents.forEach((a) => {
      if (a.mission_id === activeMissionID) out.set(a.id, a);
    });
    return out;
  }, [agents, activeMissionID]);

  return (
    <div
      style={{
        display: "flex",
        height: "100vh",
        width: "100vw",
        background: "var(--bg)",
      }}
    >
      <ChatPanel
        missions={missions}
        activeMissionID={activeMissionID}
        onCreateMission={handleCreate}
        onSelectMission={setActiveMissionID}
        onDeleteMission={handleDeleteMission}
        onHome={handleHome}
        connState={connState}
      />
      {/* Hidden iframe pool. Iframes live here when no tile is
          showing them; tile slots reparent them in/out by ID. */}
      <div
        ref={poolRef}
        id={IFRAME_POOL_ID}
        aria-hidden="true"
        style={{
          position: "fixed",
          left: "-99999px",
          top: 0,
          width: 1280,
          height: 720,
          pointerEvents: "none",
          visibility: "hidden",
        }}
      />
      <main style={{ flex: 1, position: "relative" }}>
        <ReactFlowProvider>
          <Canvas
            agents={visibleAgents}
            eventsByAgent={eventsByAgent}
            onTerminateAgent={handleTerminateAgent}
          />
        </ReactFlowProvider>
        {!activeMissionID && (
          <div
            style={{
              position: "absolute",
              inset: 0,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              color: "var(--text-4)",
              fontSize: 13,
              pointerEvents: "none",
            }}
          >
            {missions.length === 0
              ? "type a goal in the left panel to dispatch a mission"
              : "select a mission on the left, or dispatch a new one"}
          </div>
        )}
      </main>
    </div>
  );
}
