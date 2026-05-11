// Canvas — the react-flow surface.
//
// v0.6: a SINGLE canvas for ALL missions. Each mission is laid
// out as a vertical "lane" (its own column of canvas space);
// lanes are placed left-to-right in mission-creation order with
// a fixed gap between them. Within a lane, the existing
// depth-based layout still applies — driver/root at the top,
// workers in the next row, paired logs below those.
//
// We keep `useNodesState` (uncontrolled) so operator drag /
// resize edits persist across re-renders. The desired layout
// from `buildGraph` is merged into existing nodes by ID:
// position + dimensions of an already-placed tile are
// preserved; new tiles get their default lane position.

import {
  Background,
  BackgroundVariant,
  Controls,
  MiniMap,
  ReactFlow,
  type Edge,
  type Node,
  type NodeTypes,
  useEdgesState,
  useNodesState,
  useReactFlow,
} from "@xyflow/react";
import { useCallback, useEffect, useMemo, useState } from "react";

import { AgentTile, type AgentTileData } from "./AgentTile";
import { BlackboardTile, type BlackboardTileData } from "./BlackboardTile";
import { ArtifactTile, type ArtifactTileData } from "./ArtifactTile";
import type { Agent, Artifact, KEvent, Mission, Note } from "../lib/types";

// v0.6 iteration: workers used to have a separate AgentLogTile
// connected by a dashed view-edge. Merged into the main tile so
// each worker is one bounded box (desktop on top, log below).
const nodeTypes: NodeTypes = {
  agent: AgentTile,
  blackboard: BlackboardTile,
  artifact: ArtifactTile,
};

interface Props {
  agents: Map<string, Agent>;
  missions: Mission[];
  eventsByAgent: Map<string, KEvent[]>;
  // Per-mission blackboard contents + artifact list, kept in App.
  // The note count drives the blackboard tile body; artifacts
  // (if any) spawn their own tiles.
  notesByMission: Map<string, Note[]>;
  artifactsByMission: Map<string, Artifact[]>;
  // Per-mission "last write" cue: agent_id + ts of the most recent
  // worker.note_write event. Drives the blackboard tile flash and
  // the worker→blackboard edge pulse.
  lastNoteWriteByMission: Map<string, { agentID: string; ts: string }>;
  // Per-agent "is currently mid-turn" flag (true when pi emits
  // agent_start, cleared on agent_end). Drives the driver tile
  // border glow + outgoing edge pulse.
  driverStreamingByAgent: Map<string, boolean>;
  // Per-worker "the driver just acted on me" cue. Drives the
  // driver→worker spawn edge pulse, mirroring how the worker→
  // blackboard edge pulses on note_write.
  lastDriverActionByAgent: Map<string, { kind: string; ts: string }>;
  // Per-agent live thinking buffer. The driver tile renders
  // this as a streaming preview bubble so the operator sees
  // the supervisor's reasoning land word-by-word during the
  // long thinking phase. Empty / missing = no active stream.
  liveThinkingByAgent: Map<string, string>;
  onTerminateAgent?: (agentID: string) => void;
  onDeleteMission?: (missionID: string) => void;
  // Called on right-click. The handler receives both screen coords
  // (for popover positioning) and the canvas-coordinate point
  // (for mission origin). screenToFlowPosition is converted here
  // because Canvas is inside the ReactFlowProvider.
  onPaneContextMenu?: (
    event: React.MouseEvent | MouseEvent,
    flowPos: { x: number; y: number },
  ) => void;
  onPrompt?: (agentID: string, text: string) => Promise<void>;
}

// Tile dimensions. Worker tile holds both the desktop iframe
// (top, KasmVNC native 1280x720) AND the event log (bottom),
// so default height = header + iframe + log split (~60/40).
const HEADER_PX = 32;
const TILE_W_DEFAULT = 1280;
// 720 (iframe) + 32 (header) + 480 (log) = 1232. Operator can
// resize via NodeResizer; iframe and log share the body via
// flex 3:2 so they scale proportionally.
const TILE_H_DEFAULT = 720 + HEADER_PX + 480;
// Driver tile is chat-shaped — narrower than worker, but tall
// enough that operator + driver messages have room to breathe
// without scrolling for typical 2-3 turn missions. Operator
// can resize via NodeResizer.
const DRIVER_W_DEFAULT = 720;
const DRIVER_H_DEFAULT = 600;
// Horizontal gap between sibling tiles within a row of one mission.
const COL_GAP = 64;
// Vertical gap between depth rows within one mission.
const ROW_GAP = 140;
// Horizontal gap BETWEEN missions on the canvas (lane separator).
const MISSION_GAP = 320;
// Maximum columns when laying out workers as a grid. With 4
// columns the bounding box stays under ~5500px wide for the
// common N=8 case, which fits at ~25% zoom on a typical
// monitor. We could go to 5+ but the operator generally wants
// to scan workers at readable size, not as thumbnails.
const WORKER_GRID_MAX_COLS = 4;

// Blackboard tile dimensions — chat-shaped, sibling to the
// driver tile (positioned to its right by default).
const BLACKBOARD_W_DEFAULT = 520;
const BLACKBOARD_H_DEFAULT = 600;

// Artifact tile dimensions — the final report; should feel
// substantial since it's the deliverable. Operator can resize.
const ARTIFACT_W_DEFAULT = 1100;
const ARTIFACT_H_DEFAULT = 720;

// gridLayout decides how to arrange N worker tiles. Up to 3 in
// a single row (the common cases stay flat); 4+ get squared
// into a grid using ceil(sqrt(N)) columns capped at
// WORKER_GRID_MAX_COLS. Returns (cols, rows).
//
//   N=1 → 1×1      N=4 → 2×2      N=9 → 3×3
//   N=2 → 2×1      N=6 → 3×2      N=12 → 4×3
//   N=3 → 3×1      N=8 → 3×3      N=16 → 4×4
function gridLayout(n: number): { cols: number; rows: number } {
  if (n <= 0) return { cols: 0, rows: 0 };
  if (n <= 3) return { cols: n, rows: 1 };
  const sq = Math.ceil(Math.sqrt(n));
  const cols = Math.min(WORKER_GRID_MAX_COLS, sq);
  const rows = Math.ceil(n / cols);
  return { cols, rows };
}

export function Canvas({
  agents,
  missions,
  eventsByAgent,
  notesByMission,
  artifactsByMission,
  lastNoteWriteByMission,
  driverStreamingByAgent,
  lastDriverActionByAgent,
  liveThinkingByAgent,
  onTerminateAgent,
  onDeleteMission,
  onPaneContextMenu,
  onPrompt,
}: Props) {
  const [nodes, setNodes, onNodesChange] = useNodesState<Node>([]);
  const [edges, setEdges, onEdgesChange] = useEdgesState<Edge>([]);
  const [focusedID, setFocusedID] = useState<string | null>(null);
  const rf = useReactFlow();

  const desired = useMemo(
    () =>
      buildGraph(
        agents,
        missions,
        eventsByAgent,
        notesByMission,
        artifactsByMission,
        lastNoteWriteByMission,
        driverStreamingByAgent,
        lastDriverActionByAgent,
        liveThinkingByAgent,
        focusedID,
        setFocusedID,
        onTerminateAgent,
        onDeleteMission,
        onPrompt,
      ),
    [
      agents,
      missions,
      eventsByAgent,
      notesByMission,
      artifactsByMission,
      lastNoteWriteByMission,
      driverStreamingByAgent,
      lastDriverActionByAgent,
      liveThinkingByAgent,
      focusedID,
      onTerminateAgent,
      onDeleteMission,
      onPrompt,
    ],
  );

  // Merge the desired layout into existing node state.
  //
  // Position policy:
  //   - DRIVER tiles preserve their previous position. The
  //     driver lands at the operator's right-click point on
  //     spawn (canvas_x/y from the server), and any in-session
  //     drag should stick.
  //   - WORKER tiles ALWAYS take the freshly-computed grid
  //     position. The grid (cols, rows) depends on the worker
  //     count, which grows as the driver spawns more workers.
  //     If we preserved old positions, workers laid out under a
  //     smaller grid would stay there while new workers used the
  //     bigger grid — causing overlap. Re-layout every render.
  //
  // Dimensions (NodeResizer edits) always come from prev when
  // available so resizes persist for both roles.
  useEffect(() => {
    setNodes((prev) => {
      const prevByID = new Map(prev.map((n) => [n.id, n]));
      const merged: Node[] = [];
      for (const want of desired.nodes) {
        const before = prevByID.get(want.id);
        if (!before) {
          merged.push(want);
          continue;
        }
        const data = want.data as AgentTileData;
        const isDriver = data?.agent?.role === "driver";
        merged.push({
          ...before,
          data: want.data,
          type: want.type,
          // Drivers: keep prev position (operator drag preserved
          // in-session; canvas_x/y persisted across restarts).
          // Workers: always re-layout from the current grid.
          position: isDriver ? before.position : want.position,
        });
      }
      return merged;
    });
    setEdges(desired.edges);
  }, [desired, setNodes, setEdges]);

  const handleNodesChange = useCallback(
    (changes: any) => onNodesChange(changes),
    [onNodesChange],
  );

  // Translate the right-click's screen coords to canvas
  // coordinates so the new mission can land where the operator
  // clicked. screenToFlowPosition accounts for current viewport
  // pan + zoom.
  const handlePaneContextMenu = useCallback(
    (event: React.MouseEvent | MouseEvent) => {
      if (!onPaneContextMenu) return;
      const flowPos = rf.screenToFlowPosition({
        x: event.clientX,
        y: event.clientY,
      });
      onPaneContextMenu(event, flowPos);
    },
    [onPaneContextMenu, rf],
  );

  return (
    <div style={{ width: "100%", height: "100%" }}>
      <ReactFlow
        nodes={nodes}
        edges={edges}
        nodeTypes={nodeTypes}
        onNodesChange={handleNodesChange}
        onEdgesChange={onEdgesChange}
        onPaneContextMenu={handlePaneContextMenu}
        fitView
        fitViewOptions={{ padding: 0.2 }}
        minZoom={0.05}
        maxZoom={2}
        proOptions={{ hideAttribution: true }}
      >
        <Background
          variant={BackgroundVariant.Dots}
          gap={20}
          size={1.5}
          color="#3f3f46"
        />
        <Controls
          style={{
            background: "var(--bg-1)",
            border: "1px solid var(--border)",
          }}
        />
        <MiniMap
          style={{
            background: "var(--bg-1)",
            border: "1px solid var(--border)",
          }}
          maskColor="rgba(0,0,0,0.5)"
          nodeColor={(n) => {
            const role = (n.data as AgentTileData)?.agent?.role;
            return role === "driver"
              ? "var(--accent)"
              : "var(--accent-worker)";
          }}
          pannable
          zoomable
        />
      </ReactFlow>
    </div>
  );
}

// --- multi-mission lane layout ---

function buildGraph(
  agents: Map<string, Agent>,
  missions: Mission[],
  eventsByAgent: Map<string, KEvent[]>,
  notesByMission: Map<string, Note[]>,
  artifactsByMission: Map<string, Artifact[]>,
  lastNoteWriteByMission: Map<string, { agentID: string; ts: string }>,
  driverStreamingByAgent: Map<string, boolean>,
  lastDriverActionByAgent: Map<string, { kind: string; ts: string }>,
  liveThinkingByAgent: Map<string, string>,
  focusedID: string | null,
  setFocusedID: (id: string) => void,
  onTerminateAgent?: (agentID: string) => void,
  onDeleteMission?: (missionID: string) => void,
  onPrompt?: (agentID: string, text: string) => Promise<void>,
): { nodes: Node[]; edges: Edge[] } {
  if (agents.size === 0) return { nodes: [], edges: [] };

  // Group agents by mission_id. Use the missions array as the
  // ordering source so lane placement is deterministic across
  // renders. Any agents whose mission isn't in the missions list
  // (which can happen on initial WS event before listMissions
  // hydrate finishes) get bucketed under their own mission_id
  // and placed at the end.
  const agentsByMission = new Map<string, Agent[]>();
  agents.forEach((a) => {
    const arr = agentsByMission.get(a.mission_id) ?? [];
    arr.push(a);
    agentsByMission.set(a.mission_id, arr);
  });

  const orderedMissionIDs: string[] = [];
  const seen = new Set<string>();
  // Missions in their canonical (created_at desc) order — Apple to
  // the left, newest to the right? Actually we want OLDEST left so
  // new dispatches grow rightward. Reverse the array we get.
  const missionsByOldestFirst = [...missions].sort((a, b) =>
    a.created_at.localeCompare(b.created_at),
  );
  for (const m of missionsByOldestFirst) {
    if (agentsByMission.has(m.id)) {
      orderedMissionIDs.push(m.id);
      seen.add(m.id);
    }
  }
  // Bucket any orphan agents under their mission_id.
  agentsByMission.forEach((_, mid) => {
    if (!seen.has(mid)) orderedMissionIDs.push(mid);
  });

  const nodes: Node[] = [];
  const edges: Edge[] = [];

  // Mission origin source-of-truth: the driver agent's
  // canvas_x/y. Backend persists these on right-click dispatch;
  // they survive Karkhana restart. Missions whose driver has
  // null coords (programmatic dispatches, pre-persistence rows)
  // get auto-positioned in next-free-column order.
  const missionOrigin = (missionID: string): { x: number; y: number } | null => {
    const driver = (agentsByMission.get(missionID) ?? []).find(
      (a) => a.role === "driver",
    );
    if (!driver) return null;
    if (driver.canvas_x == null || driver.canvas_y == null) return null;
    return { x: driver.canvas_x, y: driver.canvas_y };
  };

  // Two-pass layout. Missions with an explicit origin land where
  // the operator clicked; missions without one auto-position.
  let autoCursorX = 0;
  for (const mid of orderedMissionIDs) {
    const o = missionOrigin(mid);
    if (!o) continue;
    const rightEdge = o.x + TILE_W_DEFAULT;
    if (rightEdge > autoCursorX) autoCursorX = rightEdge + MISSION_GAP;
  }

  for (const missionID of orderedMissionIDs) {
    const missionAgents = agentsByMission.get(missionID) ?? [];
    const origin = missionOrigin(missionID);

    // Pre-compute lane width to know where to anchor the lane
    // when origin'd. Layout function computes width again
    // internally; cheap.
    const laneW = computeLaneWidth(missionAgents);

    let laneOriginX: number;
    let laneOriginY: number;
    if (origin) {
      // Center the lane horizontally around the click point;
      // anchor Y at click point (driver tile starts there).
      laneOriginX = origin.x - laneW / 2;
      laneOriginY = origin.y;
    } else {
      laneOriginX = autoCursorX;
      laneOriginY = 0;
    }

    const result = layoutMissionLane(
      missionID,
      missionAgents,
      eventsByAgent,
      notesByMission.get(missionID) ?? [],
      artifactsByMission.get(missionID) ?? [],
      lastNoteWriteByMission.get(missionID),
      driverStreamingByAgent,
      lastDriverActionByAgent,
      liveThinkingByAgent,
      focusedID,
      setFocusedID,
      onTerminateAgent,
      onDeleteMission,
      onPrompt,
      laneOriginX,
      laneOriginY,
    );
    nodes.push(...result.nodes);
    edges.push(...result.edges);

    if (!origin) {
      autoCursorX += result.laneWidth + MISSION_GAP;
    }
  }

  return { nodes, edges };
}

// computeLaneWidth predicts how wide a mission's lane will be
// before laying it out, so origin'd missions can anchor their
// driver tile at the click point. Mirrors the rowTileW logic in
// layoutMissionLane.
function computeLaneWidth(missionAgents: Agent[]): number {
  if (missionAgents.length === 0) return TILE_W_DEFAULT;

  const byID = new Map<string, Agent>();
  missionAgents.forEach((a) => byID.set(a.id, a));

  // Same depth computation as in layoutMissionLane.
  const depth = new Map<string, number>();
  const computeDepth = (id: string): number => {
    if (depth.has(id)) return depth.get(id)!;
    const a = byID.get(id);
    if (!a || !a.parent_agent_id || !byID.has(a.parent_agent_id)) {
      depth.set(id, 0);
      return 0;
    }
    const d = 1 + computeDepth(a.parent_agent_id);
    depth.set(id, d);
    return d;
  };
  missionAgents.forEach((a) => computeDepth(a.id));

  const rows = new Map<number, Agent[]>();
  missionAgents.forEach((a) => {
    const d = depth.get(a.id)!;
    if (!rows.has(d)) rows.set(d, []);
    rows.get(d)!.push(a);
  });

  let laneWidth = TILE_W_DEFAULT;
  rows.forEach((row) => {
    const tileW =
      row.length > 0 && row[0].role === "driver"
        ? DRIVER_W_DEFAULT
        : TILE_W_DEFAULT;
    const w = row.length * tileW + (row.length - 1) * COL_GAP;
    if (w > laneWidth) laneWidth = w;
  });
  return laneWidth;
}

function layoutMissionLane(
  missionID: string,
  missionAgents: Agent[],
  eventsByAgent: Map<string, KEvent[]>,
  notes: Note[],
  artifacts: Artifact[],
  lastNoteWrite: { agentID: string; ts: string } | undefined,
  driverStreamingByAgent: Map<string, boolean>,
  lastDriverActionByAgent: Map<string, { kind: string; ts: string }>,
  liveThinkingByAgent: Map<string, string>,
  focusedID: string | null,
  setFocusedID: (id: string) => void,
  onTerminateAgent: ((agentID: string) => void) | undefined,
  onDeleteMission: ((missionID: string) => void) | undefined,
  onPrompt: ((agentID: string, text: string) => Promise<void>) | undefined,
  laneOriginX: number,
  laneOriginY: number,
): { nodes: Node[]; edges: Edge[]; laneWidth: number } {
  // Local agent map for parent-lookup convenience.
  const byID = new Map<string, Agent>();
  missionAgents.forEach((a) => byID.set(a.id, a));

  // Depth from the mission's root.
  const depth = new Map<string, number>();
  const computeDepth = (id: string): number => {
    if (depth.has(id)) return depth.get(id)!;
    const a = byID.get(id);
    if (!a || !a.parent_agent_id || !byID.has(a.parent_agent_id)) {
      depth.set(id, 0);
      return 0;
    }
    const d = 1 + computeDepth(a.parent_agent_id);
    depth.set(id, d);
    return d;
  };
  missionAgents.forEach((a) => computeDepth(a.id));

  const rows = new Map<number, Agent[]>();
  missionAgents.forEach((a) => {
    const d = depth.get(a.id)!;
    if (!rows.has(d)) rows.set(d, []);
    rows.get(d)!.push(a);
  });
  for (const arr of rows.values()) {
    arr.sort((a, b) => a.started_at.localeCompare(b.started_at));
  }

  const sortedDepths = [...rows.keys()].sort((a, b) => a - b);

  // Compute Y for each depth. Driver rows are shorter
  // (DRIVER_H_DEFAULT) than worker rows (TILE_H_DEFAULT,
  // which now bundles desktop + log). Y is relative to
  // laneOriginY so origin'd missions stack downward from the
  // click point.
  const yByDepth = new Map<number, number>();
  let yCursor = laneOriginY;
  for (const d of sortedDepths) {
    yByDepth.set(d, yCursor);
    const r = rows.get(d)!;
    const rowH =
      r.length > 0 && r[0].role === "driver"
        ? DRIVER_H_DEFAULT
        : TILE_H_DEFAULT;
    yCursor += rowH + ROW_GAP;
  }

  // Lane width = the widest row in this mission. Each row's
  // tile widths depend on whether the row holds the driver
  // (DRIVER_W_DEFAULT, narrower) or workers (TILE_W_DEFAULT,
  // 1280 wide for KasmVNC).
  const rowTileW = (r: Agent[]) =>
    r.length > 0 && r[0].role === "driver" ? DRIVER_W_DEFAULT : TILE_W_DEFAULT;
  let laneWidth = TILE_W_DEFAULT;
  for (const d of sortedDepths) {
    const row = rows.get(d)!;
    const w = row.length * rowTileW(row) + (row.length - 1) * COL_GAP;
    if (w > laneWidth) laneWidth = w;
  }
  const laneCenterX = laneOriginX + laneWidth / 2;

  const nodes: Node[] = [];
  const edges: Edge[] = [];

  // Pre-compute the mission-cumulative cost + worker counts so
  // the driver tile can surface the rollup in its header.
  // (Loop-invariant; pull out of the depth loop.)
  const missionCostUSD = missionAgents.reduce(
    (sum, a) => sum + (a.cost_usd ?? 0),
    0,
  );
  const missionWorkers = (() => {
    let running = 0;
    let total = 0;
    for (const a of missionAgents) {
      if (a.role !== "worker") continue;
      total += 1;
      if (a.status === "running") running += 1;
    }
    return { running, total };
  })();

  for (const d of sortedDepths) {
    const row = rows.get(d)!;
    const y0 = yByDepth.get(d)!;
    const tileW = rowTileW(row);
    const isWorkerRow = row.length > 0 && row[0].role === "worker";
    // Worker rows fan out as a grid (cols capped at
    // WORKER_GRID_MAX_COLS); other rows stay flat.
    const grid = isWorkerRow
      ? gridLayout(row.length)
      : { cols: row.length, rows: 1 };
    const gridRowW = grid.cols * tileW + (grid.cols - 1) * COL_GAP;
    const startX = laneCenterX - gridRowW / 2;

    let i = 0;
    for (const agent of row) {
      const isMissionRoot =
        !agent.parent_agent_id || !byID.has(agent.parent_agent_id);
      const isDriver = agent.role === "driver";
      const tH = isDriver ? DRIVER_H_DEFAULT : TILE_H_DEFAULT;
      const tW = isDriver ? DRIVER_W_DEFAULT : TILE_W_DEFAULT;

      // Grid cell coords. Driver row is always 1×1; worker
      // rows wrap every `grid.cols` tiles into the next
      // grid-row. Cells are top-left-anchored within the row.
      const col = i % grid.cols;
      const gridRow = Math.floor(i / grid.cols);
      const cursorX = startX + col * (tW + COL_GAP);
      const y = y0 + gridRow * (tH + ROW_GAP);

      const data = {
        agent,
        recentEvents: eventsByAgent.get(agent.id) ?? [],
        focused: focusedID === agent.id,
        // Driver tile uses this to glow the border while pi is
        // mid-turn. Workers ignore it (their iframe already
        // shows live state). Set by agent.streaming /
        // agent.idle events from forwardPiEvent.
        streaming: driverStreamingByAgent.get(agent.id) ?? false,
        // Driver tile only. Empty string when no active thinking.
        liveThinking: liveThinkingByAgent.get(agent.id) ?? "",
        onFocus: () => setFocusedID(agent.id),
        onTerminate: onTerminateAgent
          ? () => onTerminateAgent(agent.id)
          : undefined,
        // Mission-level deletion only on the root tile of the
        // mission. Bypassing the sidebar (gone in v0.6) means
        // the operator deletes a mission via this context menu.
        onDeleteMission:
          isMissionRoot && onDeleteMission
            ? () => onDeleteMission(missionID)
            : undefined,
        // Drivers get the operator chat plumbing; workers ignore
        // it (their AgentTile branch doesn't render the input).
        onPrompt:
          isDriver && onPrompt
            ? (text: string) => onPrompt(agent.id, text)
            : undefined,
        // Driver-only roll-ups for the header.
        missionCostUSD: isDriver ? missionCostUSD : undefined,
        missionWorkers: isDriver ? missionWorkers : undefined,
      } as AgentTileData;

      nodes.push({
        id: agent.id,
        type: "agent",
        dragHandle: ".drag-handle",
        position: { x: cursorX, y },
        width: tW,
        height: tH,
        style: { width: tW, height: tH },
        data,
      });

      i++;
    }
  }

  // Spawn edges (driver → worker). These also pulse when the
  // driver acts on the worker (steer/terminate within the last
  // ~1.5s), giving the operator a visual cue that mirrors the
  // worker→blackboard contribution pulse.
  const pulseHorizonMs = 1500;
  const now = Date.now();
  for (const a of missionAgents) {
    if (a.parent_agent_id && byID.has(a.parent_agent_id)) {
      const lastAction = lastDriverActionByAgent.get(a.id);
      const driverActed =
        !!lastAction &&
        now - Date.parse(lastAction.ts) < pulseHorizonMs;
      // Also pulse briefly when the driver spawns this worker.
      const recentlySpawned = now - Date.parse(a.started_at) < 4000;
      const pulsing =
        driverActed || (a.status === "running" && recentlySpawned);
      const isTerminate = lastAction?.kind === "driver.terminate_worker";
      edges.push({
        id: `${a.parent_agent_id}->${a.id}`,
        source: a.parent_agent_id,
        target: a.id,
        type: "smoothstep",
        animated: pulsing,
        style: {
          stroke: isTerminate
            ? "var(--status-fail, #d96f6f)"
            : a.spawn_kind === "fork"
              ? "var(--accent)"
              : "var(--accent-blackboard, var(--accent))",
          strokeWidth: pulsing ? 2.5 : 1.5,
          strokeDasharray: a.spawn_kind === "fork" ? "4 4" : undefined,
          opacity: pulsing ? 0.95 : 0.45,
        },
      });
    }
  }

  // --- blackboard tile (one per mission) ---
  //
  // Positioning rules:
  //   - If workers exist, the blackboard sits to the RIGHT of
  //     the worker grid at the worker row's Y. Each worker's
  //     right-edge "contrib" source handle aims at the
  //     blackboard's left-edge "contrib" target handle, so
  //     writes render as short ~horizontal stubs (smoothstep
  //     routed) that are individually legible — not a fan of
  //     bezier curves all collapsing to one point.
  //   - If no workers yet (mission just dispatched, driver
  //     hasn't fanned out), fall back to sibling-of-driver
  //     placement so the tile exists from the start.
  //   - Blackboard height stretches to match the worker grid
  //     height when there are 2+ rows of workers, capped so
  //     it doesn't dominate single-worker missions.
  const driver = missionAgents.find((a) => a.role === "driver");
  if (driver) {
    const driverDepth = depth.get(driver.id) ?? 0;
    const driverY = yByDepth.get(driverDepth) ?? laneOriginY;

    // Find the worker row (if any).
    const workerRow = missionAgents.filter(
      (a) => a.role === "worker" && byID.has(a.parent_agent_id ?? ""),
    );
    const hasWorkers = workerRow.length > 0;

    let bbX: number;
    let bbY: number;
    let bbH = BLACKBOARD_H_DEFAULT;
    if (hasWorkers) {
      // Use the FIRST worker's depth as the worker row.
      // v0.7 has a single worker depth (drivers don't spawn
      // sub-workers yet) so this is unambiguous.
      const wDepth = depth.get(workerRow[0].id) ?? driverDepth + 1;
      const wY = yByDepth.get(wDepth) ?? driverY + DRIVER_H_DEFAULT + ROW_GAP;
      const grid = gridLayout(workerRow.length);
      const gridW =
        grid.cols * TILE_W_DEFAULT + (grid.cols - 1) * COL_GAP;
      const gridH =
        grid.rows * TILE_H_DEFAULT + (grid.rows - 1) * ROW_GAP;
      // Right edge of the worker grid (worker tiles are
      // centered on laneCenterX in the depth loop above).
      const workerGridRightX = laneCenterX + gridW / 2;
      bbX = workerGridRightX + COL_GAP;
      bbY = wY;
      // Match height to worker grid, but clamp so single-row
      // missions don't get a stubby blackboard.
      bbH = Math.max(BLACKBOARD_H_DEFAULT, gridH);
    } else {
      bbX =
        laneCenterX - DRIVER_W_DEFAULT / 2 + DRIVER_W_DEFAULT + COL_GAP;
      bbY = driverY;
    }

    nodes.push({
      id: missionID + ":blackboard",
      type: "blackboard",
      dragHandle: ".drag-handle",
      position: { x: bbX, y: bbY },
      width: BLACKBOARD_W_DEFAULT,
      height: bbH,
      style: { width: BLACKBOARD_W_DEFAULT, height: bbH },
      data: {
        missionID,
        notes,
        lastWriteAt: lastNoteWrite?.ts,
      } as BlackboardTileData,
    });

    // Driver → blackboard: enters via the top "driver" handle.
    // Smoothstep so it doesn't bezier-curve across the canvas.
    edges.push({
      id: `${driver.id}->${missionID}:blackboard`,
      source: driver.id,
      target: missionID + ":blackboard",
      targetHandle: "driver",
      type: "smoothstep",
      animated: false,
      style: {
        stroke: "var(--accent-blackboard, var(--accent))",
        strokeWidth: 1.25,
        opacity: 0.45,
      },
    });

    // Worker → blackboard contribution edges. One per worker
    // that has actually written a note; pulsing on most-recent.
    // Source handle = worker's "contrib" (right side).
    // Target handle = blackboard's "contrib" (left side).
    // Smoothstep routes them as right-angle stubs that don't
    // overlap each other.
    const contributors = new Set<string>();
    for (const n of notes) {
      if (n.agent_id && n.agent_id !== driver.id) {
        contributors.add(n.agent_id);
      }
    }
    for (const wid of contributors) {
      if (!byID.has(wid)) continue;
      const pulsing = lastNoteWrite?.agentID === wid;
      edges.push({
        id: `${wid}->${missionID}:blackboard:contrib`,
        source: wid,
        sourceHandle: "contrib",
        target: missionID + ":blackboard",
        targetHandle: "contrib",
        type: "smoothstep",
        animated: pulsing,
        style: {
          stroke: "var(--accent-blackboard, var(--accent))",
          strokeWidth: pulsing ? 2.5 : 1.75,
          strokeDasharray: "6 4",
          opacity: pulsing ? 0.95 : 0.6,
        },
      });
    }
  }

  // --- artifact tile (one per mission, if produced) ---
  //
  // The artifact represents the mission's deliverable; we
  // position it BELOW the workers (after all depth rows have
  // been laid out). For v0.7 we expect at most one artifact
  // per mission; loop to be future-proof.
  if (artifacts.length > 0 && driver) {
    // yCursor after the depth loop above gives us the bottom of
    // the workers area. Place artifact a bit below.
    const artifactY = yCursor + 40;
    let artifactX = laneCenterX - ARTIFACT_W_DEFAULT / 2;
    for (const a of artifacts) {
      nodes.push({
        id: "artifact:" + a.id,
        type: "artifact",
        dragHandle: ".drag-handle",
        position: { x: artifactX, y: artifactY },
        width: ARTIFACT_W_DEFAULT,
        height: ARTIFACT_H_DEFAULT,
        style: {
          width: ARTIFACT_W_DEFAULT,
          height: ARTIFACT_H_DEFAULT,
        },
        data: {
          artifactID: a.id,
          type: a.type,
          title: a.title ?? "(untitled)",
          summary: a.summary,
          createdAt: a.created_at,
        } as ArtifactTileData,
      });
      // Production edge: driver -> artifact, slightly bolder so
      // it reads as "this is the deliverable."
      edges.push({
        id: `${driver.id}->artifact:${a.id}`,
        source: driver.id,
        target: "artifact:" + a.id,
        animated: false,
        style: {
          stroke: "var(--accent-artifact, #e6b800)",
          strokeWidth: 2,
          opacity: 0.7,
        },
      });
      // Multi-artifact case (v1): step right for the next one.
      artifactX += ARTIFACT_W_DEFAULT + COL_GAP;
      if (artifactX + ARTIFACT_W_DEFAULT > laneCenterX + laneWidth) {
        // Wrap to next row.
        artifactX = laneCenterX - ARTIFACT_W_DEFAULT / 2;
      }
    }
    // The blackboard width contribution to the lane is handled
    // implicitly by NodeResizer; for v0.7 we don't grow the
    // lane to include the blackboard / artifact (they overflow
    // to the right / below). Operator drags if it's a problem.
  }
  return { nodes, edges, laneWidth };
}
