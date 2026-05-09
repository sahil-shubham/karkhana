// Canvas — the react-flow surface.
//
// Switched from controlled `nodes={...}` (recomputed via useMemo
// every render) to uncontrolled `useNodesState` so user-driven
// edits — drag, resize via NodeResizer — persist between renders.
// We sync the agents map into the node state via a single effect:
// new agents append, removed agents drop, existing agents have
// their `data` refreshed but position + dimensions preserved.

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
import type { Agent, KEvent } from "../lib/types";

const nodeTypes: NodeTypes = {
  agent: AgentTile,
  agentLog: AgentLogTile,
};

interface Props {
  agents: Map<string, Agent>;
  eventsByAgent: Map<string, KEvent[]>;
  onTerminateAgent?: (agentID: string) => void;
}

// Tile dimensions: desktop tile renders KasmVNC at native 1:1.
// KasmVNC's bhatti config is `Xkasmvnc :99 -geometry 1280x720`,
// so 1280 wide and 720 + header gives the iframe its full HD
// canvas without xrandr resampling or bitmap upscaling. The
// canvas zoom handles fitting it into your monitor; the actual
// pixels stay 1:1 inside the tile.
const DESKTOP_PX_W = 1280;
const DESKTOP_PX_H = 720;
const HEADER_PX = 32; // header strip above the iframe
const TILE_W_DEFAULT = DESKTOP_PX_W;
const TILE_H_DEFAULT = DESKTOP_PX_H + HEADER_PX;
// Log tile sits below the desktop, same width, generous height
// (room for tool calls + assistant text without scrolling).
const LOG_W_DEFAULT = TILE_W_DEFAULT;
const LOG_H_DEFAULT = 480;
// Vertical gap between the worker tile and its paired log tile.
const PAIR_GAP_Y = 28;
// Gap between agent units within a row.
const COL_GAP = 64;
// Gap between depth rows (independent of paired-log height).
const ROW_GAP = 140;

export function Canvas({
  agents,
  eventsByAgent,
  onTerminateAgent,
}: Props) {
  const [nodes, setNodes, onNodesChange] = useNodesState<Node>([]);
  const [edges, setEdges, onEdgesChange] = useEdgesState<Edge>([]);
  const [focusedID, setFocusedID] = useState<string | null>(null);

  // Layout-derived nodes (default position + tile size). Syncs into
  // `nodes` via the effect below; user edits (drag, resize) survive
  // because we merge instead of replacing.
  const desired = useMemo(
    () =>
      buildGraph(agents, eventsByAgent, focusedID, setFocusedID, onTerminateAgent),
    [agents, eventsByAgent, focusedID, onTerminateAgent],
  );

  useEffect(() => {
    setNodes((prev) => {
      const prevByID = new Map(prev.map((n) => [n.id, n]));
      const merged: Node[] = [];
      for (const want of desired.nodes) {
        const before = prevByID.get(want.id);
        if (before) {
          // Preserve operator-edited position + size; refresh data only.
          merged.push({
            ...before,
            data: want.data,
            // Keep `type` and other static fields from `want`.
            type: want.type,
          });
        } else {
          merged.push(want);
        }
      }
      return merged;
    });
    setEdges(desired.edges);
  }, [desired, setNodes, setEdges]);

  // Allow the AgentTile's NodeResizer to write back. We don't need
  // explicit handlers — onNodesChange (passed to ReactFlow) routes
  // dimension changes into `nodes` automatically.
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
        fitView
        fitViewOptions={{ padding: 0.2 }}
        minZoom={0.2}
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
        />
      </ReactFlow>
    </div>
  );
}

// --- layout (initial positions + sizes) ---

function buildGraph(
  agents: Map<string, Agent>,
  eventsByAgent: Map<string, KEvent[]>,
  focusedID: string | null,
  setFocusedID: (id: string) => void,
  onTerminateAgent?: (agentID: string) => void,
): { nodes: Node[]; edges: Edge[] } {
  const all = Array.from(agents.values());
  if (all.length === 0) return { nodes: [], edges: [] };

  // Group by depth from the root.
  const depth = new Map<string, number>();
  const computeDepth = (id: string): number => {
    if (depth.has(id)) return depth.get(id)!;
    const a = agents.get(id);
    if (!a || !a.parent_agent_id) {
      depth.set(id, 0);
      return 0;
    }
    const d = 1 + computeDepth(a.parent_agent_id);
    depth.set(id, d);
    return d;
  };
  all.forEach((a) => computeDepth(a.id));

  const rows = new Map<number, Agent[]>();
  all.forEach((a) => {
    const d = depth.get(a.id)!;
    if (!rows.has(d)) rows.set(d, []);
    rows.get(d)!.push(a);
  });
  for (const arr of rows.values()) {
    arr.sort((a, b) => a.started_at.localeCompare(b.started_at));
  }

  // Compute per-depth Y positions, accounting for paired log tiles
  // below worker rows. A row with any worker takes
  //   TILE_H + PAIR_GAP_Y + LOG_H
  // worth of vertical space; driver-only rows take just TILE_H.
  const rowHasWorker = (r: Agent[]) =>
    r.some((a) => a.role === "worker");
  const yByDepth = new Map<number, number>();
  let yCursor = 0;
  const sortedDepths = [...rows.keys()].sort((a, b) => a - b);
  for (const d of sortedDepths) {
    yByDepth.set(d, yCursor);
    const r = rows.get(d)!;
    const rowH = rowHasWorker(r)
      ? TILE_H_DEFAULT + PAIR_GAP_Y + LOG_H_DEFAULT
      : TILE_H_DEFAULT;
    yCursor += rowH + ROW_GAP;
  }

  const nodes: Node[] = [];
  for (const d of sortedDepths) {
    const row = rows.get(d)!;
    const y = yByDepth.get(d)!;
    const totalW =
      row.length * TILE_W_DEFAULT + (row.length - 1) * COL_GAP;
    let cursorX = -totalW / 2;

    for (const agent of row) {
      const data = {
        agent,
        recentEvents: eventsByAgent.get(agent.id) ?? [],
        focused: focusedID === agent.id,
        onFocus: () => setFocusedID(agent.id),
        onTerminate: onTerminateAgent
          ? () => onTerminateAgent(agent.id)
          : undefined,
      } as AgentTileData;

      // Primary tile (worker desktop OR driver event-stream).
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
        // Paired log tile *below* the desktop, same width.
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

  const edges: Edge[] = [];
  for (const a of all) {
    // spawn edge: parent -> child
    if (a.parent_agent_id) {
      edges.push({
        id: `${a.parent_agent_id}->${a.id}`,
        source: a.parent_agent_id,
        target: a.id,
        animated: a.status === "running",
        style: {
          stroke: a.spawn_kind === "fork" ? "var(--accent)" : "var(--border)",
          strokeWidth: 1.5,
          strokeDasharray: a.spawn_kind === "fork" ? "4 4" : undefined,
        },
      });
    }
    // view edge: worker desktop -> its log sibling
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

  return { nodes, edges };
}
