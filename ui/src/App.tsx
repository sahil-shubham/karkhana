// App — top-level shell.
//
// v0.6: no sidebar. The canvas is the only operator surface.
// Right-click on empty canvas → NewMissionPopover → dispatch.
// All missions render simultaneously in their own canvas lanes;
// the operator pans / zooms / uses the minimap to navigate.
// Connection state hides in a small top-left indicator.

import { useCallback, useEffect, useRef, useState } from "react";
import { ReactFlowProvider } from "@xyflow/react";

import { Canvas } from "./components/Canvas";
import { NewMissionPopover } from "./components/NewMissionPopover";
import { ConnectionIndicator } from "./components/ConnectionIndicator";
import { connectEvents, type ConnState } from "./lib/ws";
import { api } from "./lib/api";
import { apiURL } from "./lib/config";
import type { Agent, KEvent, Mission } from "./lib/types";

// Each running worker gets exactly one <iframe> on the page,
// keyed by agent ID and parked in this hidden pool. AgentTile
// reparents the iframe into its slot on mount and back to the
// pool on unmount — so canvas re-renders, zoom changes, or any
// other React reconciliation that touches the tile DOES NOT tear
// down the live KasmVNC connection. With v0.6's single canvas
// the mission-switch case (which originally motivated this) is
// gone, but the pool still helps for resize / zoom / drag edges.
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
  const [agents, setAgents] = useState<Map<string, Agent>>(new Map());
  const [eventsByAgent, setEventsByAgent] = useState<Map<string, KEvent[]>>(
    new Map(),
  );
  const [connState, setConnState] = useState<ConnState>("connecting");

  // Right-click dispatch state. Non-null while the popover is
  // open. Holds BOTH screen coords (for popover positioning) and
  // canvas-flow coords (for the mission's spawn origin).
  const [newMissionAt, setNewMissionAt] = useState<{
    screenX: number;
    screenY: number;
    flowX: number;
    flowY: number;
  } | null>(null);

  // Per-mission canvas origin. When the operator dispatches via
  // right-click, we remember WHERE they clicked so the mission's
  // driver tile lands there. Missions without an entry (e.g.
  // recovered ones) auto-position. In-memory only for v0.6;
  // moves to the persistence layer later.
  const [missionOrigins, setMissionOrigins] = useState<
    Map<string, { x: number; y: number }>
  >(new Map());

  // ---- WS subscription ----
  useEffect(() => {
    const ws = connectEvents({
      onConnState: setConnState,
      onEvent: (event) => {
        // mission lifecycle
        if (event.kind === "mission.created") {
          api
            .listMissions()
            .then(setMissions)
            .catch(() => {});
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

  // ---- mount: hydrate all missions + agents ----
  // v0.5 fetched per-mission on select; v0.6 fetches everything
  // because everything is on screen.
  useEffect(() => {
    api
      .listMissions()
      .then((ms) => {
        const sorted = [...ms].sort((a, b) =>
          b.created_at.localeCompare(a.created_at),
        );
        setMissions(sorted);
      })
      .catch((e) => console.warn("listMissions failed", e));

    api
      .listAgents()
      .then((list) => {
        setAgents((cur) => {
          const next = new Map(cur);
          for (const a of list) {
            const existing = next.get(a.id);
            if (existing && existing.terminated_at && !a.terminated_at) {
              continue;
            }
            next.set(a.id, a);
          }
          return next;
        });
      })
      .catch((e) => console.warn("listAgents failed", e));
  }, []);

  // ---- callbacks ----

  const handleCreateMission = useCallback(
    async (goal: string, origin?: { x: number; y: number }) => {
      try {
        const m = await api.createMission(goal);
        setMissions((ms) => [m, ...ms.filter((x) => x.id !== m.id)]);
        if (origin) {
          setMissionOrigins((prev) => {
            const next = new Map(prev);
            next.set(m.id, origin);
            return next;
          });
        }
      } catch (e) {
        console.error("createMission failed", e);
      }
    },
    [],
  );

  const handleTerminateAgent = useCallback(async (agentID: string) => {
    if (!confirm("Terminate this agent? The sandbox will be destroyed.")) return;
    try {
      await api.terminateAgent(agentID);
    } catch (e) {
      console.error("terminate failed", e);
    }
  }, []);

  // Operator chat — send a follow-up to a driver. Backend
  // decides between prompt (idle) and steer (streaming).
  const handlePromptAgent = useCallback(
    async (agentID: string, text: string) => {
      await api.promptAgent(agentID, text);
    },
    [],
  );

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
        setMissionOrigins((prev) => {
          if (!prev.has(id)) return prev;
          const next = new Map(prev);
          next.delete(id);
          return next;
        });
      } catch (e) {
        console.error("deleteMission failed", e);
      }
    },
    [missions],
  );

  // Right-click on empty canvas pane. Canvas converts the
  // event's screen coords to canvas-flow coords (using
  // useReactFlow().screenToFlowPosition under the hood) and
  // passes both up here.
  const handlePaneContextMenu = useCallback(
    (
      event: React.MouseEvent | MouseEvent,
      flowPos: { x: number; y: number },
    ) => {
      if ("preventDefault" in event) event.preventDefault();
      setNewMissionAt({
        screenX: event.clientX,
        screenY: event.clientY,
        flowX: flowPos.x,
        flowY: flowPos.y,
      });
    },
    [],
  );

  // ---- iframe pool reconciliation ----
  const poolRef = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    const pool = poolRef.current;
    if (!pool) return;

    const desired = new Map<string, string>();
    agents.forEach((a) => {
      if (a.role !== "worker") return;
      if (a.status !== "running") return;
      const url = buildKasmURL(a);
      if (!url) return;
      desired.set(a.id, url);
    });

    document
      .querySelectorAll<HTMLIFrameElement>(`iframe[data-kasm-agent]`)
      .forEach((el) => {
        const id = el.dataset.kasmAgent!;
        if (!desired.has(id)) el.remove();
      });

    desired.forEach((url, agentID) => {
      if (document.getElementById(kasmIframeID(agentID))) return;
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

  return (
    <div
      style={{
        position: "relative",
        height: "100vh",
        width: "100vw",
        background: "var(--bg)",
        overflow: "hidden",
      }}
    >
      {/* hidden iframe pool */}
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

      {/* the only chrome: minimap-friendly, low-key */}
      <ConnectionIndicator state={connState} />

      {/* the canvas IS the surface */}
      <ReactFlowProvider>
        <Canvas
          agents={agents}
          missions={missions}
          eventsByAgent={eventsByAgent}
          missionOrigins={missionOrigins}
          onTerminateAgent={handleTerminateAgent}
          onDeleteMission={handleDeleteMission}
          onPaneContextMenu={handlePaneContextMenu}
          onPrompt={handlePromptAgent}
        />
      </ReactFlowProvider>

      {/* empty-canvas hint */}
      {missions.length === 0 && (
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
            zIndex: 1,
          }}
        >
          right-click anywhere to start a conversation
        </div>
      )}

      {/* dispatch popover */}
      {newMissionAt && (
        <NewMissionPopover
          screenX={newMissionAt.screenX}
          screenY={newMissionAt.screenY}
          onSubmit={(goal) => {
            handleCreateMission(goal, {
              x: newMissionAt.flowX,
              y: newMissionAt.flowY,
            });
            setNewMissionAt(null);
          }}
          onCancel={() => setNewMissionAt(null)}
        />
      )}
    </div>
  );
}
