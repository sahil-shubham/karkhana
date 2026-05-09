// AgentLogTile — sibling node attached to each WORKER's primary
// AgentTile. Renders the agent's event stream (same view drivers
// get) so the operator can read the agent's reasoning + tool
// calls + assistant messages in dedicated space rather than the
// one-line footer of the desktop tile.
//
// Drivers don't get one of these (their primary tile already IS
// an event stream). Only workers.

import {
  Handle,
  NodeResizer,
  Position,
  type NodeProps,
} from "@xyflow/react";
import {
  EventStream,
  StatusDot,
  TileFooter,
  type AgentTileData,
} from "./AgentTile";

export function AgentLogTile({ data, selected }: NodeProps) {
  const { agent, recentEvents } = data as AgentTileData;
  const accent = "var(--accent-worker)";

  return (
    <div
      className="tile log-tile"
      style={{
        background: "var(--bg-1)",
        border: "1px solid var(--border)",
        borderRadius: "var(--radius)",
        width: "100%",
        height: "100%",
        display: "flex",
        flexDirection: "column",
        overflow: "hidden",
      }}
    >
      <NodeResizer
        isVisible={selected}
        minWidth={260}
        minHeight={180}
        maxWidth={1200}
        maxHeight={1200}
        handleStyle={{
          width: 8,
          height: 8,
          background: accent,
          border: "none",
          borderRadius: 1,
        }}
        lineStyle={{ borderColor: accent, borderWidth: 1 }}
      />

      <header
        className="drag-handle"
        style={{
          display: "flex",
          alignItems: "center",
          gap: 8,
          padding: "6px 10px",
          background: "var(--bg-2)",
          borderBottom: "1px solid var(--border)",
          fontSize: 11,
          textTransform: "uppercase",
          letterSpacing: 0.5,
          cursor: "move",
          userSelect: "none",
          flexShrink: 0,
        }}
      >
        <StatusDot status={agent.status} />
        <span style={{ color: accent, fontWeight: 600 }}>LOG</span>
        <span style={{ color: "var(--text-3)" }}>·</span>
        <span
          style={{
            color: "var(--text-3)",
            flex: 1,
            overflow: "hidden",
            textOverflow: "ellipsis",
            whiteSpace: "nowrap",
            fontWeight: 500,
          }}
        >
          {recentEvents.length} events
        </span>
        <span style={{ color: "var(--text-4)", fontSize: 10 }}>
          {agent.tokens_input + agent.tokens_output > 0
            ? `${formatTokens(agent.tokens_input + agent.tokens_output)} tok`
            : "—"}
        </span>
      </header>

      <div style={{ flex: 1, overflow: "hidden" }}>
        <EventStream events={recentEvents} />
      </div>

      <TileFooter agent={agent} recentEvents={recentEvents} />

      {/* Receive the view edge from the desktop tile (above) */}
      <Handle
        id="log"
        type="target"
        position={Position.Top}
        style={{ background: "var(--accent-worker)", width: 6, height: 6 }}
      />
    </div>
  );
}

function formatTokens(n: number): string {
  if (n < 1000) return String(n);
  if (n < 10000) return (n / 1000).toFixed(1) + "k";
  return Math.round(n / 1000) + "k";
}
