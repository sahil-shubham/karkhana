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
import type { Agent, Artifact, KEvent, Mission, Note } from "./lib/types";

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
  if (!agent.kasmvnc_url || agent.kasmvnc_url === "about:blank")
    return undefined;
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

  // v0.7: per-mission blackboard contents + artifact list +
  // most-recent-write cue. Notes accumulate as worker.note_write
  // events arrive on the WS; artifacts arrive via
  // artifact.created events. Hydrated from REST on initial
  // mount.
  const [notesByMission, setNotesByMission] = useState<Map<string, Note[]>>(
    new Map(),
  );
  const [artifactsByMission, setArtifactsByMission] = useState<
    Map<string, Artifact[]>
  >(new Map());
  const [lastNoteWriteByMission, setLastNoteWriteByMission] = useState<
    Map<string, { agentID: string; ts: string }>
  >(new Map());

  // Driver activity tracking for canvas edge pulses + tile glow.
  // - driverStreamingByAgent: did the driver just emit a turn_start
  //   without a matching agent_end? Used to glow the driver tile.
  // - lastDriverActionByAgent: per-worker, the latest action the
  //   driver took (steer/terminate/spawn). Drives the
  //   driver→worker spawn edge pulse, mirroring the worker→
  //   blackboard contribution pulse.
  const [driverStreamingByAgent, setDriverStreamingByAgent] = useState<
    Map<string, boolean>
  >(new Map());
  const [lastDriverActionByAgent, setLastDriverActionByAgent] = useState<
    Map<string, { kind: string; ts: string }>
  >(new Map());

  // Per-agent live thinking buffer. Streamed in via
  // agent.thinking_delta events while pi is mid-thinking-block.
  // Cleared on worker.message (the finalized assistant text
  // takes over) or on the next agent.thinking_start. Gives the
  // operator a real-time view of the supervisor's reasoning so
  // there's no 20-60s dead air between agent.streaming and the
  // first assistant token.
  const [liveThinkingByAgent, setLiveThinkingByAgent] = useState<
    Map<string, string>
  >(new Map());

  // Right-click dispatch state. Non-null while the popover is
  // open. Holds BOTH screen coords (for popover positioning) and
  // canvas-flow coords (for the mission's spawn origin).
  const [newMissionAt, setNewMissionAt] = useState<{
    screenX: number;
    screenY: number;
    flowX: number;
    flowY: number;
  } | null>(null);

  // v0.6 persistence: canvas position lives on the driver agent
  // (canvas_x / canvas_y). The backend stores it; the WS event
  // for agent.spawning carries it; Canvas reads it off the agent
  // record. We don't need a client-side Map anymore.

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
              const cx = event.payload?.canvas_x;
              const cy = event.payload?.canvas_y;
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
                canvas_x: typeof cx === "number" ? cx : undefined,
                canvas_y: typeof cy === "number" ? cy : undefined,
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

        // Live thinking stream. These events are transient
        // (server doesn't persist them) so they only appear in
        // the live WS feed, not on reload — which is fine since
        // the consolidated assistant text in worker.message IS
        // persisted.
        if (event.kind === "agent.thinking_start" && event.agent_id) {
          setLiveThinkingByAgent((cur) => {
            const next = new Map(cur);
            next.set(event.agent_id!, "");
            return next;
          });
        }
        if (event.kind === "agent.thinking_delta" && event.agent_id) {
          const delta = (event.payload as Record<string, unknown> | undefined)
            ?.delta;
          if (typeof delta === "string" && delta.length > 0) {
            setLiveThinkingByAgent((cur) => {
              const next = new Map(cur);
              const prev = cur.get(event.agent_id!) ?? "";
              next.set(event.agent_id!, prev + delta);
              return next;
            });
          }
        }
        // Clear the live thinking buffer when the assistant
        // message lands (worker.message is the persisted final
        // text — it supersedes the streamed thinking preview).
        if (event.kind === "worker.message" && event.agent_id) {
          setLiveThinkingByAgent((cur) => {
            if (!cur.has(event.agent_id!)) return cur;
            const next = new Map(cur);
            next.delete(event.agent_id!);
            return next;
          });
        }

        // Per-agent streaming/idle tracking. Karkhana emits
        // agent.streaming on pi's agent_start and agent.idle on
        // agent_end, role-independent. The driver tile uses this
        // to glow + pulse outgoing edges; worker tiles ignore it
        // (their iframe already shows live activity).
        if (event.agent_id && event.kind === "agent.streaming") {
          setDriverStreamingByAgent((cur) => {
            const next = new Map(cur);
            next.set(event.agent_id!, true);
            return next;
          });
        }
        if (
          event.agent_id &&
          (event.kind === "agent.idle" || event.kind === "agent.completed")
        ) {
          setDriverStreamingByAgent((cur) => {
            if (!cur.has(event.agent_id!)) return cur;
            const next = new Map(cur);
            next.delete(event.agent_id!);
            return next;
          });
        }

        // driver.steer_worker / driver.terminate_worker:
        // remember the most-recent action per target worker so
        // the canvas can pulse the driver→worker edge.
        if (
          event.agent_id &&
          (event.kind === "driver.steer_worker" ||
            event.kind === "driver.terminate_worker")
        ) {
          setLastDriverActionByAgent((cur) => {
            const next = new Map(cur);
            next.set(event.agent_id!, {
              kind: event.kind,
              ts: event.ts,
            });
            return next;
          });
        }

        // worker.note_write: a worker/driver wrote to the
        // mission blackboard. Append the note locally so the
        // blackboard tile renders it without a roundtrip,
        // and remember who wrote so the edge can pulse.
        if (event.kind === "worker.note_write" && event.payload) {
          const p = event.payload as Record<string, unknown>;
          const noteID = p.note_id as number | undefined;
          const key = p.key as string | undefined;
          if (noteID != null && key) {
            const newNote: Note = {
              id: noteID,
              mission_id: event.mission_id,
              key,
              // We don't get the full content in this event
              // payload to keep replay light; fetch on demand
              // when the operator expands the row. For now use
              // the summary as the preview.
              content: (p.content as string) ?? (p.summary as string) ?? "",
              summary: p.summary as string | undefined,
              agent_id: event.agent_id,
              ts: event.ts,
            };
            setNotesByMission((cur) => {
              const next = new Map(cur);
              const arr = next.get(event.mission_id) ?? [];
              if (arr.some((n) => n.id === newNote.id)) return cur;
              next.set(event.mission_id, [...arr, newNote]);
              return next;
            });
            if (event.agent_id) {
              setLastNoteWriteByMission((cur) => {
                const next = new Map(cur);
                next.set(event.mission_id, {
                  agentID: event.agent_id!,
                  ts: event.ts,
                });
                return next;
              });
            }
          }
        }

        // worker.tool_call: when a worker calls write_note,
        // we ALSO get the full content here in payload.args.
        // Stash it so expanding the note shows full content
        // without a network fetch.
        if (
          event.kind === "worker.tool_call" &&
          event.payload &&
          (event.payload as Record<string, unknown>).tool === "write_note"
        ) {
          const p = event.payload as Record<string, unknown>;
          const args = (p.args as Record<string, unknown>) ?? {};
          const key = args.key as string | undefined;
          const content = args.content as string | undefined;
          if (key && content) {
            // Find the most recent note for this mission+key
            // matching this agent and back-fill its content.
            setNotesByMission((cur) => {
              const arr = cur.get(event.mission_id);
              if (!arr) return cur;
              const next = new Map(cur);
              const updated = arr.map((n) =>
                n.agent_id === event.agent_id &&
                n.key === key &&
                (!n.content || n.content === (n.summary ?? ""))
                  ? { ...n, content }
                  : n,
              );
              next.set(event.mission_id, updated);
              return next;
            });
          }
        }

        // artifact.created: a new artifact is available. We get
        // metadata in the payload; the ArtifactTile fetches
        // full content on mount via api.getArtifact.
        if (event.kind === "artifact.created" && event.payload) {
          const p = event.payload as Record<string, unknown>;
          const artID = p.artifact_id as string | undefined;
          if (artID) {
            const newArt: Artifact = {
              id: artID,
              mission_id: event.mission_id,
              type: (p.type as string) ?? "markdown:report",
              title: p.title as string | undefined,
              content: "", // fetched on mount
              summary: p.summary as string | undefined,
              produced_by: event.agent_id,
              created_at: event.ts,
            };
            setArtifactsByMission((cur) => {
              const next = new Map(cur);
              const arr = next.get(event.mission_id) ?? [];
              if (arr.some((a) => a.id === newArt.id)) return cur;
              next.set(event.mission_id, [...arr, newArt]);
              return next;
            });
          }
        }

        // Transient lifecycle/streaming events are intercepted
        // by the dedicated state setters above (liveThinking,
        // driverStreaming, lastDriverAction) — they MUST NOT
        // also flow into the visible event log, or the driver
        // chat fills with hundreds of "agent.thinking_delta"
        // dim rows during a single thinking turn. These match
        // the kinds skipped by the server's publish() persist
        // filter; they're for animation only.
        const TRANSIENT_KINDS = new Set([
          "agent.thinking_start",
          "agent.thinking_delta",
          "agent.thinking_end",
          "agent.text_delta",
          "agent.streaming",
          "agent.idle",
        ]);

        // append to per-agent event log. Dedup by event.id
        // because the WS sends a replay batch on connect (post-
        // restart hydration) and live events may overlap with
        // the replayed snapshot. See pkg/canvas/ws.go.
        if (event.agent_id && !TRANSIENT_KINDS.has(event.kind)) {
          setEventsByAgent((cur) => {
            const next = new Map(cur);
            const arr = next.get(event.agent_id!) ?? [];
            if (arr.some((e) => e.id === event.id)) return cur;
            // Insert in id order; events arrive monotonically
            // most of the time so a simple append is fine, but
            // be defensive: sort if a tail event arrives out of
            // order.
            const merged = [...arr, event];
            if (
              merged.length >= 2 &&
              merged[merged.length - 1].id < merged[merged.length - 2].id
            ) {
              merged.sort((a, b) => a.id - b.id);
            }
            next.set(event.agent_id!, merged.slice(-200));
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
        // For each mission, fan out a one-shot hydrate of
        // its blackboard + artifacts. Cheap; runs in parallel.
        for (const m of sorted) {
          api
            .listNotes(m.id)
            .then((notes) => {
              if (notes.length === 0) return;
              setNotesByMission((cur) => {
                const next = new Map(cur);
                next.set(m.id, notes);
                return next;
              });
            })
            .catch(() => {});
          api
            .listArtifacts(m.id)
            .then((arts) => {
              if (arts.length === 0) return;
              setArtifactsByMission((cur) => {
                const next = new Map(cur);
                next.set(m.id, arts);
                return next;
              });
            })
            .catch(() => {});
        }
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
        const m = await api.createMission(goal, origin);
        setMissions((ms) => [m, ...ms.filter((x) => x.id !== m.id)]);
      } catch (e) {
        console.error("createMission failed", e);
      }
    },
    [],
  );

  const handleTerminateAgent = useCallback(async (agentID: string) => {
    if (!confirm("Terminate this agent? The sandbox will be destroyed."))
      return;
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
        setNotesByMission((cur) => {
          if (!cur.has(id)) return cur;
          const next = new Map(cur);
          next.delete(id);
          return next;
        });
        setArtifactsByMission((cur) => {
          if (!cur.has(id)) return cur;
          const next = new Map(cur);
          next.delete(id);
          return next;
        });
        setLastNoteWriteByMission((cur) => {
          if (!cur.has(id)) return cur;
          const next = new Map(cur);
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
          notesByMission={notesByMission}
          artifactsByMission={artifactsByMission}
          lastNoteWriteByMission={lastNoteWriteByMission}
          driverStreamingByAgent={driverStreamingByAgent}
          lastDriverActionByAgent={lastDriverActionByAgent}
          liveThinkingByAgent={liveThinkingByAgent}
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
