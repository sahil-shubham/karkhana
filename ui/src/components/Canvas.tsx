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
} from "@xyflow/react";
import { useCallback, useEffect, useMemo, useState } from "react";

import { AgentTile, type AgentTileData } from "./AgentTile";
import { AgentLogTile } from "./AgentLogTile";
import type { Agent, KEvent, Mission } from "../lib/types";

const nodeTypes: NodeTypes = {
  agent: AgentTile,
  agentLog: AgentLogTile,
};

interface Props {
  agents: Map<string, Agent>;
  missions: Mission[];
  eventsByAgent: Map<string, KEvent[]>;
  onTerminateAgent?: (agentID: string) => void;
  onDeleteMission?: (missionID: string) => void;
  onPaneContextMenu?: (event: React.MouseEvent | MouseEvent) => void;
}

// Tile dimensions. Worker desktops render KasmVNC at native 1:1
// (KasmVNC's bhatti config is `Xkasmvnc :99 -geometry 1280x720`).
const DESKTOP_PX_W = 1280;
const DESKTOP_PX_H = 720;
const HEADER_PX = 32;
const TILE_W_DEFAULT = DESKTOP_PX_W;
const TILE_H_DEFAULT = DESKTOP_PX_H + HEADER_PX;
const LOG_W_DEFAULT = TILE_W_DEFAULT;
const LOG_H_DEFAULT = 480;
// Vertical gap between a worker and its paired log tile.
const PAIR_GAP_Y = 28;
// Horizontal gap between sibling tiles within a row of one mission.
const COL_GAP = 64;
// Vertical gap between depth rows within one mission.
const ROW_GAP = 140;
// Horizontal gap BETWEEN missions on the canvas (lane separator).
// Big enough that a mission with one worker doesn't visually merge
// with its neighbour.
const MISSION_GAP = 320;

export function Canvas({
  agents,
  missions,
  eventsByAgent,
  onTerminateAgent,
  onDeleteMission,
  onPaneContextMenu,
}: Props) {
  const [nodes, setNodes, onNodesChange] = useNodesState<Node>([]);
  const [edges, setEdges, onEdgesChange] = useEdgesState<Edge>([]);
  const [focusedID, setFocusedID] = useState<string | null>(null);

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
      ),
    [
      agents,
      missions,
      eventsByAgent,
      focusedID,
      onTerminateAgent,
      onDeleteMission,
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

  return (
    <div style={{ width: "100%", height: "100%" }}>
      <ReactFlow
        nodes={nodes}
        edges={edges}
        nodeTypes={nodeTypes}
        onNodesChange={handleNodesChange}
        onEdgesChange={onEdgesChange}
        onPaneContextMenu={onPaneContextMenu}
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
  let cursorX = 0;

  for (const missionID of orderedMissionIDs) {
    const missionAgents = agentsByMission.get(missionID) ?? [];

    // Per-mission depth-based row layout. Same algorithm as v0.5,
    // just operating on this mission's agents only and placed
    // inside the mission's lane (not centered around X=0).
    const result = layoutMissionLane(
      missionID,
      missionAgents,
      eventsByAgent,
      focusedID,
      setFocusedID,
      onTerminateAgent,
      onDeleteMission,
      cursorX,
    );
    nodes.push(...result.nodes);
    edges.push(...result.edges);
    cursorX += result.laneWidth + MISSION_GAP;
  }

  return { nodes, edges };
}

function layoutMissionLane(
  missionID: string,
  missionAgents: Agent[],
  eventsByAgent: Map<string, KEvent[]>,
  focusedID: string | null,
  setFocusedID: (id: string) => void,
  onTerminateAgent: ((agentID: string) => void) | undefined,
  onDeleteMission: ((missionID: string) => void) | undefined,
  laneOriginX: number,
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
  const rowHasWorker = (r: Agent[]) =>
    r.some((a) => a.role === "worker");

  // Compute Y for each depth, accounting for paired-log space.
  const yByDepth = new Map<number, number>();
  let yCursor = 0;
  for (const d of sortedDepths) {
    yByDepth.set(d, yCursor);
    const r = rows.get(d)!;
    const rowH = rowHasWorker(r)
      ? TILE_H_DEFAULT + PAIR_GAP_Y + LOG_H_DEFAULT
      : TILE_H_DEFAULT;
    yCursor += rowH + ROW_GAP;
  }

  // Lane width = the widest row in this mission. We'll center each
  // row inside this width.
  let laneWidth = TILE_W_DEFAULT;
  for (const d of sortedDepths) {
    const row = rows.get(d)!;
    const w = row.length * TILE_W_DEFAULT + (row.length - 1) * COL_GAP;
    if (w > laneWidth) laneWidth = w;
  }
  const laneCenterX = laneOriginX + laneWidth / 2;

  const nodes: Node[] = [];
  const edges: Edge[] = [];

  for (const d of sortedDepths) {
    const row = rows.get(d)!;
    const y = yByDepth.get(d)!;
    const rowW = row.length * TILE_W_DEFAULT + (row.length - 1) * COL_GAP;
    let cursorX = laneCenterX - rowW / 2;

    for (const agent of row) {
      const isMissionRoot =
        !agent.parent_agent_id || !byID.has(agent.parent_agent_id);
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
      } as AgentTileData;

      nodes.push({
        id: agent.id,
        type: "agent",
        dragHandle: ".drag-handle",
        position: { x: cursorX, y },
        width: TILE_W_DEFAULT,
        height: TILE_H_DEFAULT,
        style: { width: TILE_W_DEFAULT, height: TILE_H_DEFAULT },
        data,
      });

      if (agent.role === "worker") {
        nodes.push({
          id: agent.id + ":log",
          type: "agentLog",
          dragHandle: ".drag-handle",
          position: { x: cursorX, y: y + TILE_H_DEFAULT + PAIR_GAP_Y },
          width: LOG_W_DEFAULT,
          height: LOG_H_DEFAULT,
          style: { width: LOG_W_DEFAULT, height: LOG_H_DEFAULT },
          data,
        });
      }

      cursorX += TILE_W_DEFAULT + COL_GAP;
    }
  }

  // Edges within this mission only.
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
    if (a.role === "worker") {
      edges.push({
        id: `${a.id}->${a.id}:log`,
        source: a.id,
        sourceHandle: "log",
        target: `${a.id}:log`,
        targetHandle: "log",
        animated: false,
        style: {
          stroke: "var(--accent-worker)",
          strokeWidth: 1,
          strokeDasharray: "2 3",
          opacity: 0.5,
        },
      });
    }
  }

  return { nodes, edges, laneWidth };
}
