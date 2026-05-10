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
import type { Agent, KEvent, Mission } from "../lib/types";

// v0.6 iteration: workers used to have a separate AgentLogTile
// connected by a dashed view-edge. Merged into the main tile so
// each worker is one bounded box (desktop on top, log below).
const nodeTypes: NodeTypes = {
  agent: AgentTile,
};

interface Props {
  agents: Map<string, Agent>;
  missions: Mission[];
  eventsByAgent: Map<string, KEvent[]>;
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

export function Canvas({
  agents,
  missions,
  eventsByAgent,
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
      focusedID,
      onTerminateAgent,
      onDeleteMission,
      onPrompt,
    ],
  );

  // Merge the desired layout into existing node state, preserving
  // operator-edited position/size for tiles we've already placed.
  useEffect(() => {
    setNodes((prev) => {
      const prevByID = new Map(prev.map((n) => [n.id, n]));
      const merged: Node[] = [];
      for (const want of desired.nodes) {
        const before = prevByID.get(want.id);
        if (before) {
          merged.push({ ...before, data: want.data, type: want.type });
        } else {
          merged.push(want);
        }
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

  for (const d of sortedDepths) {
    const row = rows.get(d)!;
    const y = yByDepth.get(d)!;
    const tileW = rowTileW(row);
    const rowW = row.length * tileW + (row.length - 1) * COL_GAP;
    let cursorX = laneCenterX - rowW / 2;

    // Pre-compute the mission-cumulative cost + worker counts
    // so the driver tile can surface the rollup in its header.
    // Operators want "this whole mission cost $X", not "the
    // driver's own LLM call cost $0.04".
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

    for (const agent of row) {
      const isMissionRoot =
        !agent.parent_agent_id || !byID.has(agent.parent_agent_id);
      const isDriver = agent.role === "driver";
      const tH = isDriver ? DRIVER_H_DEFAULT : TILE_H_DEFAULT;
      const tW = isDriver ? DRIVER_W_DEFAULT : TILE_W_DEFAULT;

      const data = {
        agent,
        recentEvents: eventsByAgent.get(agent.id) ?? [],
        focused: focusedID === agent.id,
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

      cursorX += tW + COL_GAP;
    }
  }

  // Edges within this mission only. Spawn edges only — the
  // dashed view-edge to a separate log tile is gone.
  for (const a of missionAgents) {
    if (a.parent_agent_id && byID.has(a.parent_agent_id)) {
      edges.push({
        id: `${a.parent_agent_id}->${a.id}`,
        source: a.parent_agent_id,
        target: a.id,
        animated: a.status === "running",
        style: {
          stroke:
            a.spawn_kind === "fork" ? "var(--accent)" : "var(--border)",
          strokeWidth: 1.5,
          strokeDasharray: a.spawn_kind === "fork" ? "4 4" : undefined,
        },
      });
    }
  }

  return { nodes, edges, laneWidth };
}
