// AgentTile — the primary tile per agent.
//
//   Driver  → body is a chat-shaped conversation surface
//             (scrolling event stream + always-visible input).
//   Worker  → body is two stacked regions in the SAME tile:
//             (a) KasmVNC desktop iframe on top  (~60% height)
//             (b) auto-scrolling event log below (~40% height)
//
// v0.6 iteration: workers used to have a separate log tile
// connected by a dashed view-edge. Operator feedback: "why is
// it two tiles connected by an edge when they're conceptually
// one thing?" — right. Merged into a single tile with an
// internal divider; the edge clutter goes away.
//
// Pointer-event handling: KasmVNC's iframe captures every click;
// we use the .drag-handle header strip as react-flow's drag
// origin, plus a transparent overlay shield over the iframe when
// the tile isn't focused (click anywhere → focus → shield clears
// → KasmVNC takes over). Standard pattern.

import {
  Handle,
  NodeResizer,
  Position,
  type NodeProps,
} from "@xyflow/react";
import { useEffect, useRef, useState } from "react";
import type { Agent, KEvent } from "../lib/types";
import { apiURL } from "../lib/config";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuSeparator,
  ContextMenuTrigger,
} from "./ui/ContextMenu";

export interface AgentTileData extends Record<string, unknown> {
  agent: Agent;
  recentEvents: KEvent[];
  focused: boolean;
  // True while pi is mid-turn for this agent (driver only —
  // workers ignore this since their iframe shows live state).
  // Drives the border-glow animation.
  streaming?: boolean;
  // Live-thinking buffer accumulated from agent.thinking_delta
  // events while pi is streaming a thinking block. Empty when
  // no active stream. Rendered as a faded italic preview at the
  // bottom of the driver chat so the operator sees the
  // supervisor reasoning in real time during the 20-60s
  // thinking phase that would otherwise look like dead air.
  liveThinking?: string;
  onFocus: () => void;
  onTerminate?: () => void;
  // Set on the root tile of a mission only (the agent that has
  // no parent). v0.6 has no sidebar; this is how the operator
  // ends a whole mission — right-click the root → Delete mission.
  onDeleteMission?: () => void;
  // Driver tiles only — send an operator chat message to the
  // driver agent. Backend decides prompt vs steer based on
  // streaming state. See lib/api.ts:promptAgent.
  onPrompt?: (text: string) => Promise<void>;
  // Driver tiles only — cumulative LLM cost across the driver
  // and all its descendants in this mission. Worker tiles get
  // undefined here and fall back to agent.cost_usd, which IS
  // their own cost. Set in Canvas.layoutMissionLane.
  missionCostUSD?: number;
  // Driver tiles only — worker counts for the mission. Helps
  // the operator see "3 of 5 workers running" at a glance in
  // the header. Set in Canvas.layoutMissionLane.
  missionWorkers?: { running: number; total: number };
}

export function AgentTile({ data, selected }: NodeProps) {
  const {
    agent,
    recentEvents,
    focused,
    streaming,
    liveThinking,
    onFocus,
    onTerminate,
    onDeleteMission,
    onPrompt,
    missionCostUSD,
    missionWorkers,
  } = data as AgentTileData;
  const isDriver = agent.role === "driver";
  const accent = isDriver ? "var(--accent)" : "var(--accent-worker)";
  // Driver-only: while streaming, the border softly glows in
  // the accent color so the operator can see at a glance that
  // the supervisor is mid-thought. Implemented as an animated
  // CSS keyframe defined in index.css (see .tile-streaming).
  const driverStreaming = isDriver && !!streaming;

  // KasmVNC URL only used for the right-click "Open in new tab"
  // context-menu item. The actual iframe is owned by App.tsx's
  // iframe pool (see kasmIframeID + buildKasmURL there) and
  // reparented into our WorkerView slot on mount.
  const desktopURL = (() => {
    if (!agent.kasmvnc_url || agent.kasmvnc_url === "about:blank")
      return undefined;
    const base = agent.kasmvnc_url.startsWith("/")
      ? apiURL(agent.kasmvnc_url)
      : agent.kasmvnc_url;
    const sep = base.includes("?") ? "&" : "?";
    return `${base}${sep}resize=remote&autoconnect=1`;
  })();

  const tile = (
    <div
      className={
        "tile" + (driverStreaming ? " tile-streaming" : "")
      }
      style={{
        background: "var(--bg-1)",
        border: `1px solid ${
          driverStreaming
            ? accent
            : focused
              ? accent
              : "var(--border)"
        }`,
        borderRadius: "var(--radius)",
        width: "100%",
        height: "100%",
        display: "flex",
        flexDirection: "column",
        boxShadow: driverStreaming
          ? `0 0 0 2px ${accent}55, 0 0 16px ${accent}44`
          : focused
            ? `0 0 0 2px ${accent}33`
            : "none",
        overflow: "hidden",
        position: "relative",
        transition: "border-color 200ms, box-shadow 250ms",
      }}
    >
      <NodeResizer
        isVisible={selected}
        minWidth={320}
        minHeight={220}
        maxWidth={3200}
        maxHeight={2000}
        handleStyle={{
          width: 8,
          height: 8,
          background: accent,
          border: "none",
          borderRadius: 1,
        }}
        lineStyle={{ borderColor: accent, borderWidth: 1 }}
      />

      <TileHeader
        accent={accent}
        roleLabel={isDriver ? "DRIVER" : "WORKER"}
        agent={agent}
        onTerminate={onTerminate}
        missionCostUSD={isDriver ? missionCostUSD : undefined}
        missionWorkers={isDriver ? missionWorkers : undefined}
      />

      {/* Body region. For drivers: scrolling chat. For workers:
          two stacked regions — desktop iframe on top, log
          below. Both share one bounding tile. */}
      {isDriver ? (
        <div style={{ flex: 1, position: "relative", overflow: "hidden" }}>
          <ConversationStream
            events={recentEvents}
            liveThinking={liveThinking ?? ""}
            streaming={streaming ?? false}
          />
        </div>
      ) : (
        <>
          <div
            style={{
              // 60% of remaining tile height. KasmVNC is native
              // 1280x720 — with `resize=remote` the X server
              // xrandrs to whatever the iframe ends up being,
              // so this region is flexible.
              flex: "3 0 0",
              minHeight: 200,
              position: "relative",
              overflow: "hidden",
            }}
          >
            <WorkerView
              agentID={agent.id}
              hasURL={!!desktopURL}
              focused={focused}
              onFocus={onFocus}
            />
          </div>
          <div
            style={{
              // 40% — worker's reasoning / tool calls / final text.
              // Min height keeps the log readable when the
              // operator drags the tile small.
              flex: "2 0 0",
              minHeight: 120,
              borderTop: "1px solid var(--border)",
              background: "var(--bg-1)",
              overflow: "hidden",
            }}
          >
            <EventStream events={recentEvents} />
          </div>
        </>
      )}

      {/* Drivers get a chat input footer; worker desktops have
          their paired log tile so no footer needed there. */}
      {isDriver && onPrompt && (
        <DriverChatInput
          agent={agent}
          recentEvents={recentEvents}
          onPrompt={onPrompt}
        />
      )}

      {/* spawn edges (driver → worker, worker → sub-worker).
          The view-edge to a separate log tile was removed when
          workers merged log + desktop into one tile.

          The Right source handle is dedicated to blackboard
          contribution edges: in v0.7 the blackboard sits to the
          right of the worker grid, so right-side egress keeps
          contribution stubs near-horizontal and visually
          distinct from spawn edges (which run top-bottom). */}
      <Handle
        type="target"
        position={Position.Top}
        style={{ background: "var(--border)", width: 6, height: 6 }}
      />
      <Handle
        type="source"
        position={Position.Bottom}
        style={{ background: "var(--border)", width: 6, height: 6 }}
      />
      <Handle
        type="source"
        id="contrib"
        position={Position.Right}
        style={{
          background: "var(--accent-blackboard, var(--accent))",
          width: 6,
          height: 6,
          top: 36, // anchor near the header so the edge enters above the iframe
        }}
      />
    </div>
  );

  return (
    <ContextMenu>
      <ContextMenuTrigger asChild>{tile}</ContextMenuTrigger>
      <ContextMenuContent>
        <ContextMenuItem onSelect={onFocus}>
          {focused ? "Already focused" : "Focus"}
        </ContextMenuItem>
        {desktopURL && (
          <ContextMenuItem
            onSelect={() => window.open(desktopURL, "_blank", "noopener")}
          >
            Open desktop in new tab
          </ContextMenuItem>
        )}
        <ContextMenuItem
          onSelect={() =>
            navigator.clipboard.writeText(agent.id).catch(() => {})
          }
        >
          Copy agent ID
        </ContextMenuItem>
        {agent.bhatti_sandbox_id && (
          <ContextMenuItem
            onSelect={() =>
              navigator.clipboard
                .writeText(agent.bhatti_sandbox_id!)
                .catch(() => {})
            }
          >
            Copy sandbox ID
          </ContextMenuItem>
        )}
        {(onTerminate && agent.status === "running") || onDeleteMission ? (
          <ContextMenuSeparator />
        ) : null}
        {onTerminate && agent.status === "running" && (
          <ContextMenuItem variant="danger" onSelect={onTerminate}>
            Terminate {agent.role === "driver" ? "driver" : "worker"}
          </ContextMenuItem>
        )}
        {onDeleteMission && (
          <ContextMenuItem variant="danger" onSelect={onDeleteMission}>
            Delete mission
          </ContextMenuItem>
        )}
      </ContextMenuContent>
    </ContextMenu>
  );
}

// --- shared sub-components (also imported by AgentLogTile) ---

export function TileHeader({
  accent,
  roleLabel,
  agent,
  onTerminate,
  missionCostUSD,
  missionWorkers,
}: {
  accent: string;
  roleLabel: string;
  agent: Agent;
  onTerminate?: () => void;
  // When set, the cost shown in the header is the cumulative
  // cost across the entire mission (driver + all its workers),
  // not just this agent's own cost. Driver tiles get this.
  missionCostUSD?: number;
  missionWorkers?: { running: number; total: number };
}) {
  // Driver tiles show mission-cumulative cost; worker tiles
  // show their own per-agent cost. Operator's mental model is
  // "the driver IS the mission" so the rollup belongs there.
  const displayCost = missionCostUSD ?? agent.cost_usd ?? 0;
  return (
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
      <span style={{ color: accent, fontWeight: 600 }}>{roleLabel}</span>
      <span style={{ color: "var(--text-3)" }}>·</span>
      <span
        style={{
          color: "var(--text-2)",
          fontWeight: 500,
          flex: 1,
          overflow: "hidden",
          textOverflow: "ellipsis",
          whiteSpace: "nowrap",
        }}
      >
        {agent.task ?? agent.id}
      </span>
      {missionWorkers && missionWorkers.total > 0 && (
        <span
          style={{ color: "var(--text-4)", fontSize: 10 }}
          title={`${missionWorkers.running} of ${missionWorkers.total} workers running`}
        >
          {missionWorkers.running}/{missionWorkers.total} ●
        </span>
      )}
      <span
        style={{ color: "var(--text-4)", fontSize: 10 }}
        title={
          missionCostUSD !== undefined
            ? "mission total LLM cost (driver + workers)"
            : "this agent's LLM cost"
        }
      >
        ${displayCost.toFixed(2)}
      </span>
      {onTerminate && agent.status === "running" && (
        <button
          onClick={(e) => {
            e.stopPropagation();
            onTerminate();
          }}
          title="Terminate worker (destroys sandbox)"
          style={{
            background: "transparent",
            color: "var(--text-4)",
            border: "1px solid var(--border)",
            borderRadius: 3,
            padding: "1px 6px",
            fontSize: 10,
            cursor: "pointer",
          }}
        >
          ✕
        </button>
      )}
    </header>
  );
}

export function TileFooter({
  agent,
  recentEvents,
}: {
  agent: Agent;
  recentEvents: KEvent[];
}) {
  return (
    <footer
      style={{
        padding: "5px 10px",
        background: "var(--bg-2)",
        borderTop: "1px solid var(--border)",
        fontSize: 11,
        color: "var(--text-3)",
        whiteSpace: "nowrap",
        overflow: "hidden",
        textOverflow: "ellipsis",
        flexShrink: 0,
      }}
    >
      {agent.final_assistant_text ?? lastEventText(recentEvents) ?? "…"}
    </footer>
  );
}

export function StatusDot({ status }: { status: string }) {
  let color = "var(--status-terminated)";
  if (status === "running") color = "var(--status-running)";
  else if (status === "failed") color = "var(--status-fail)";
  else if (status === "suspended") color = "var(--status-suspended)";
  else if (status === "terminated") color = "var(--status-success)";

  return (
    <span
      title={status}
      style={{
        display: "inline-block",
        width: 8,
        height: 8,
        borderRadius: "50%",
        background: color,
        boxShadow: status === "running" ? `0 0 4px ${color}` : "none",
        flexShrink: 0,
      }}
    />
  );
}

export function EventStream({ events }: { events: KEvent[] }) {
  // Auto-scroll to the bottom on new events — but only if the
  // operator hasn't scrolled up. Scrolling up locks auto-scroll;
  // scrolling back to the bottom re-enables it. Mirrors how every
  // chat / log viewer worth using behaves.
  const scrollRef = useRef<HTMLDivElement>(null);
  const [stick, setStick] = useState(true);

  const handleScroll = () => {
    const el = scrollRef.current;
    if (!el) return;
    const distance = el.scrollHeight - el.scrollTop - el.clientHeight;
    setStick(distance < 40);
  };

  useEffect(() => {
    if (!stick) return;
    const el = scrollRef.current;
    if (!el) return;
    // requestAnimationFrame so the new content has been laid out
    // before we measure scrollHeight.
    const raf = requestAnimationFrame(() => {
      el.scrollTop = el.scrollHeight;
    });
    return () => cancelAnimationFrame(raf);
  }, [events.length, stick]);

  return (
    <div
      ref={scrollRef}
      onScroll={handleScroll}
      style={{
        height: "100%",
        overflowY: "auto",
        padding: "8px 10px",
        fontSize: 11,
        color: "var(--text-3)",
        lineHeight: 1.5,
        position: "relative",
      }}
    >
      {events.length === 0 ? (
        <div style={{ color: "var(--text-4)", fontStyle: "italic" }}>
          waiting for events…
        </div>
      ) : (
        events.slice(-100).map((ev) => <EventRow key={ev.id} ev={ev} />)
      )}
      {!stick && events.length > 5 && (
        <button
          onClick={() => {
            const el = scrollRef.current;
            if (!el) return;
            el.scrollTop = el.scrollHeight;
            setStick(true);
          }}
          style={{
            position: "sticky",
            bottom: 4,
            left: "50%",
            transform: "translateX(-50%)",
            display: "block",
            margin: "4px auto 0",
            padding: "3px 10px",
            background: "var(--bg-2)",
            color: "var(--text-2)",
            border: "1px solid var(--border)",
            borderRadius: 12,
            fontSize: 10,
            cursor: "pointer",
          }}
        >
          ↓ jump to latest
        </button>
      )}
    </div>
  );
}

function EventRow({ ev }: { ev: KEvent }) {
  const kind = ev.kind;
  const p = (ev.payload ?? {}) as Record<string, unknown>;
  const time = formatTime(ev.ts);

  // Per-kind rendering — operator-readable, structured.
  if (kind === "worker.tool_call") {
    return (
      <div style={{ marginBottom: 6 }}>
        <span style={{ color: "var(--text-4)" }}>{time}</span>
        <span
          style={{
            color: "var(--accent-worker)",
            marginLeft: 6,
            fontWeight: 500,
          }}
        >
          ↪ tool
        </span>
        <pre
          style={{
            margin: "2px 0 0 16px",
            color: "var(--text-2)",
            fontSize: 11,
            whiteSpace: "pre-wrap",
            wordBreak: "break-word",
            fontFamily: "inherit",
          }}
        >
          {(p.text as string) ?? ""}
        </pre>
      </div>
    );
  }

  if (kind === "worker.message") {
    return (
      <div style={{ marginBottom: 8 }}>
        <span style={{ color: "var(--text-4)" }}>{time}</span>
        <span
          style={{
            color: "var(--accent)",
            marginLeft: 6,
            fontWeight: 500,
          }}
        >
          assistant
        </span>
        <div
          style={{
            margin: "2px 0 0 16px",
            color: "var(--text)",
            whiteSpace: "pre-wrap",
            wordBreak: "break-word",
          }}
        >
          {(p.text as string) ?? ""}
        </div>
      </div>
    );
  }

  if (kind === "worker.thinking") {
    return (
      <div style={{ marginBottom: 4 }}>
        <span style={{ color: "var(--text-4)" }}>{time}</span>
        <span
          style={{ color: "var(--text-3)", marginLeft: 6, fontStyle: "italic" }}
        >
          {(p.text as string) ?? "(thinking)"}
        </span>
      </div>
    );
  }

  if (kind === "driver.report_progress" || kind === "driver.finish") {
    return (
      <div style={{ marginBottom: 6 }}>
        <span style={{ color: "var(--text-4)" }}>{time}</span>
        <span style={{ color: "var(--accent)", marginLeft: 6 }}>
          {(p.message as string) ?? (p.result as string) ?? ""}
        </span>
      </div>
    );
  }

  if (
    kind === "agent.spawning" ||
    kind === "agent.spawned" ||
    kind === "agent.driver_connected" ||
    kind === "agent.completed" ||
    kind === "agent.terminated" ||
    kind === "agent.disconnected" ||
    kind === "sandbox.created" ||
    kind === "worker.installing" ||
    kind === "worker.installed" ||
    kind === "worker.retry" ||
    kind === "worker.compacting"
  ) {
    return (
      <div style={{ marginBottom: 4, color: "var(--text-4)", fontSize: 10 }}>
        {time} · {kind} {(p.text as string) ?? ""}
      </div>
    );
  }

  // Default: render kind + any text we can find.
  const fallbackText =
    typeof p.text === "string"
      ? p.text
      : typeof p.message === "string"
        ? p.message
        : "";
  return (
    <div style={{ marginBottom: 4 }}>
      <span style={{ color: "var(--text-4)" }}>
        {time} {kind}
      </span>
      {fallbackText && (
        <div style={{ color: "var(--text-2)", paddingLeft: 8 }}>
          {fallbackText}
        </div>
      )}
    </div>
  );
}

// Worker desktop view. The actual <iframe> lives in App.tsx's
// hidden pool, keyed by agent ID. Here we render a slot div and
// reparent the iframe DOM node into it on mount; on unmount we
// hand it back to the pool. This way switching missions, zooming
// the canvas, or any other re-render that unmounts our tile does
// NOT tear down the KasmVNC WebSocket. The iframe is alive for
// the lifetime of the agent, not the lifetime of this component.
function WorkerView({
  agentID,
  hasURL,
  focused,
  onFocus,
}: {
  agentID: string;
  hasURL: boolean;
  focused: boolean;
  onFocus: () => void;
}) {
  const slotRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!hasURL) return;
    const slot = slotRef.current;
    if (!slot) return;

    let stopped = false;
    let attached: HTMLIFrameElement | null = null;

    // App.tsx's pool effect runs after children's effects on the
    // first frame an agent acquires its kasmvnc_url, so the
    // iframe may not exist yet when we first try to grab it.
    // Retry on rAF until it shows up (capped to ~2s).
    let attempts = 0;
    const tryAttach = () => {
      if (stopped) return;
      const iframe = document.getElementById(
        `kasm-iframe-${agentID}`,
      ) as HTMLIFrameElement | null;
      if (!iframe) {
        if (attempts++ > 120) return; // give up after ~2s @ 60fps
        requestAnimationFrame(tryAttach);
        return;
      }
      // Take the iframe out of the pool, drop it into our slot.
      // appendChild moves rather than copies — the existing DOM
      // node, including its alive WebSocket, comes with us.
      slot.appendChild(iframe);
      attached = iframe;
    };
    tryAttach();

    return () => {
      stopped = true;
      if (!attached) return;
      const pool = document.getElementById("karkhana-iframe-pool");
      // If the agent has been terminated while we were mounted,
      // App.tsx's pool effect will have already removed this
      // iframe. Guard against that: only re-park if the iframe
      // is still in the document.
      if (pool && attached.isConnected) {
        pool.appendChild(attached);
      }
    };
  }, [agentID, hasURL]);

  if (!hasURL) {
    return (
      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          height: "100%",
          color: "var(--text-4)",
          background:
            "repeating-linear-gradient(45deg, var(--bg-1), var(--bg-1) 6px, var(--bg) 6px, var(--bg) 12px)",
          fontSize: 11,
          textAlign: "center",
          padding: 16,
        }}
      >
        waiting for desktop…
      </div>
    );
  }
  return (
    <div style={{ position: "relative", width: "100%", height: "100%" }}>
      <div
        ref={slotRef}
        style={{ width: "100%", height: "100%" }}
      />
      {!focused && (
        <div
          onClick={onFocus}
          style={{
            position: "absolute",
            inset: 0,
            cursor: "pointer",
            background: "transparent",
          }}
        />
      )}
    </div>
  );
}

// ConversationStream is the driver tile's body — the same
// auto-scrolling event log as the worker log tile, but with
// special-case rendering for operator messages, ask_operator
// blocks, report_progress, and finish so the driver chat reads
// like a chat instead of a log.
//
// `liveThinking` is the incrementally-accumulated thinking
// stream from agent.thinking_delta events (transient — server
// doesn't persist them). Rendered as a faded italic bubble at
// the bottom of the list while the supervisor is reasoning;
// disappears when the consolidated worker.message lands.
function ConversationStream({
  events,
  liveThinking,
  streaming,
}: {
  events: KEvent[];
  liveThinking: string;
  streaming: boolean;
}) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const [stick, setStick] = useState(true);

  const handleScroll = () => {
    const el = scrollRef.current;
    if (!el) return;
    setStick(el.scrollHeight - el.scrollTop - el.clientHeight < 40);
  };

  useEffect(() => {
    if (!stick) return;
    const el = scrollRef.current;
    if (!el) return;
    const raf = requestAnimationFrame(() => {
      el.scrollTop = el.scrollHeight;
    });
    return () => cancelAnimationFrame(raf);
    // Re-scroll on event count or live-thinking length change
    // so streaming deltas auto-follow the bottom.
  }, [events.length, liveThinking.length, stick]);

  return (
    <div
      ref={scrollRef}
      onScroll={handleScroll}
      style={{
        height: "100%",
        overflowY: "auto",
        padding: "10px 12px",
        fontSize: 12,
        color: "var(--text-2)",
        lineHeight: 1.55,
        position: "relative",
      }}
    >
      {events.length === 0 && !liveThinking ? (
        <div
          style={{
            color: "var(--text-4)",
            fontStyle: "italic",
            fontSize: 11,
          }}
        >
          waiting for driver…
        </div>
      ) : (
        events.map((ev) => <ConversationRow key={ev.id} ev={ev} />)
      )}
      {/* Streaming thinking preview. Visible only while pi is
          mid-thinking-block AND a worker.message hasn't yet
          replaced it. We show even a tiny stream so the
          operator sees motion immediately after agent.streaming
          (the LLM may take 5+ seconds before the first delta
          arrives, which is OK — the typing-cursor below covers
          that gap). */}
      {streaming && (
        <LiveThinkingBubble text={liveThinking} />
      )}
      {!stick && events.length > 5 && (
        <button
          onClick={() => {
            const el = scrollRef.current;
            if (!el) return;
            el.scrollTop = el.scrollHeight;
            setStick(true);
          }}
          style={{
            position: "sticky",
            bottom: 4,
            left: "50%",
            transform: "translateX(-50%)",
            display: "block",
            margin: "4px auto 0",
            padding: "3px 10px",
            background: "var(--bg-2)",
            color: "var(--text-2)",
            border: "1px solid var(--border)",
            borderRadius: 12,
            fontSize: 10,
            cursor: "pointer",
          }}
        >
          ↓ jump to latest
        </button>
      )}
    </div>
  );
}

// LiveThinkingBubble — in-progress streaming preview of the
// supervisor's thinking. Shown beneath the latest chat row
// while pi is mid-thinking-block. The empty state (no text
// yet, but agent.streaming is true) still renders so the
// operator sees the typing cursor immediately on prompt send;
// otherwise the canvas looks frozen during the 1-5s warmup
// before the first thinking_delta arrives.
function LiveThinkingBubble({ text }: { text: string }) {
  // Truncate display to keep the bubble compact — the LLM can
  // produce huge thinking blocks. We show a tail-clipped view
  // (last ~800 chars) so the most-recent reasoning is always
  // visible. The full content lives on the server for now and
  // can be surfaced via expand-on-click later if needed.
  const MAX_PREVIEW = 800;
  const display =
    text.length > MAX_PREVIEW
      ? "…" + text.slice(text.length - MAX_PREVIEW)
      : text;
  const isEmpty = text.length === 0;

  return (
    <div
      style={{
        marginTop: 6,
        marginBottom: 6,
        padding: "6px 10px",
        background: "color-mix(in srgb, var(--accent) 7%, var(--bg-1))",
        borderLeft: "2px solid var(--accent)",
        borderRadius: 4,
        fontSize: 11,
        lineHeight: 1.5,
        color: "var(--text-3)",
        fontStyle: "italic",
        whiteSpace: "pre-wrap",
        wordBreak: "break-word",
      }}
    >
      <div
        style={{
          color: "var(--accent)",
          fontStyle: "normal",
          fontWeight: 600,
          fontSize: 9,
          textTransform: "uppercase",
          letterSpacing: 0.5,
          marginBottom: isEmpty ? 0 : 2,
        }}
      >
        thinking… <span className="blink-cursor">▊</span>
      </div>
      {!isEmpty && display}
    </div>
  );
}

function ConversationRow({ ev }: { ev: KEvent }) {
  const kind = ev.kind;
  const p = (ev.payload ?? {}) as Record<string, unknown>;
  const time = formatTime(ev.ts);

  // operator typed something. NOTE: driver.prompt_sent is an
  // internal timing marker that the backend emits AFTER the
  // operator's prompt is sent to pi; it carries the same text
  // as the operator.message we already rendered, so showing it
  // as a chat bubble would double-render the operator's first
  // message. Kept out of the chat stream on purpose.
  if (kind === "operator.message") {
    return (
      <ChatBubble role="operator" time={time} text={(p.text as string) ?? ""} />
    );
  }

  // driver replied with assistant text
  if (kind === "worker.message") {
    return (
      <ChatBubble role="assistant" time={time} text={(p.text as string) ?? ""} />
    );
  }

  // worker.thinking events are pi's agent_start marker we
  // re-emit with placeholder text "(agent started)". They're
  // redundant in the driver chat now that we stream real
  // thinking deltas (rendered as a LiveThinkingBubble) and
  // pulse the tile border on agent.streaming. Drop them — the
  // chat reads much cleaner without the noise.
  if (kind === "worker.thinking") {
    return null;
  }

  // driver tool call (spawn_worker, wait_for_workers, etc.)
  if (kind === "worker.tool_call") {
    return (
      <div style={{ marginBottom: 6 }}>
        <span style={{ color: "var(--text-4)", fontSize: 10 }}>{time}</span>
        <span
          style={{
            color: "var(--accent)",
            marginLeft: 6,
            fontWeight: 500,
            fontSize: 11,
          }}
        >
          → {(p.text as string) ?? ""}
        </span>
      </div>
    );
  }

  // driver report_progress — status pill
  if (kind === "driver.report_progress") {
    return (
      <div
        style={{
          margin: "6px 0",
          padding: "4px 10px",
          background: "var(--bg-2)",
          border: "1px solid var(--border)",
          borderRadius: 4,
          fontSize: 11,
          color: "var(--text-2)",
        }}
      >
        <span style={{ color: "var(--accent)", fontWeight: 500 }}>
          progress
        </span>
        <span style={{ marginLeft: 8 }}>{(p.message as string) ?? ""}</span>
      </div>
    );
  }

  // driver ask_operator — yellow blocked-on-you box
  if (kind === "driver.ask_operator") {
    return (
      <div
        style={{
          margin: "6px 0",
          padding: "6px 10px",
          background: "var(--status-suspended)22",
          border: "1px solid var(--status-suspended)",
          borderRadius: 4,
          fontSize: 12,
          color: "var(--text)",
        }}
      >
        <div
          style={{
            color: "var(--status-suspended)",
            fontWeight: 600,
            fontSize: 10,
            textTransform: "uppercase",
            letterSpacing: 0.5,
            marginBottom: 2,
          }}
        >
          ❓ driver asks
        </div>
        {(p.question as string) ?? ""}
      </div>
    );
  }

  // driver finish — result rendered as the last assistant turn
  if (kind === "driver.finish") {
    return (
      <ChatBubble
        role="assistant"
        time={time}
        text={(p.result as string) ?? ""}
        terminal
      />
    );
  }

  // lifecycle events — small dim line
  if (
    kind === "agent.spawning" ||
    kind === "agent.spawned" ||
    kind === "agent.driver_connected" ||
    kind === "agent.completed" ||
    kind === "agent.terminated"
  ) {
    return (
      <div style={{ marginBottom: 4, color: "var(--text-4)", fontSize: 10 }}>
        {time} · {kind} {(p.text as string) ?? ""}
      </div>
    );
  }

  // default: dim, just for visibility
  return (
    <div style={{ marginBottom: 4, color: "var(--text-4)", fontSize: 10 }}>
      {time} {kind}
    </div>
  );
}

function ChatBubble({
  role,
  time,
  text,
  terminal,
}: {
  role: "operator" | "assistant";
  time: string;
  text: string;
  terminal?: boolean;
}) {
  const isOp = role === "operator";
  return (
    <div style={{ marginBottom: 10 }}>
      <div
        style={{
          display: "flex",
          alignItems: "baseline",
          gap: 6,
          marginBottom: 2,
        }}
      >
        <span
          style={{
            color: isOp ? "var(--text-2)" : "var(--accent)",
            fontWeight: 600,
            fontSize: 10,
            textTransform: "uppercase",
            letterSpacing: 0.5,
          }}
        >
          {isOp ? "you" : terminal ? "driver ✓" : "driver"}
        </span>
        <span style={{ color: "var(--text-4)", fontSize: 10 }}>{time}</span>
      </div>
      <div
        style={{
          color: "var(--text)",
          whiteSpace: "pre-wrap",
          wordBreak: "break-word",
          paddingLeft: 0,
        }}
      >
        {text}
      </div>
    </div>
  );
}

// DriverChatInput is the always-visible footer on driver tiles.
// Pressing Enter (without shift) sends the operator's message
// via api.promptAgent; the backend decides prompt vs. steer.
function DriverChatInput({
  agent,
  recentEvents,
  onPrompt,
}: {
  agent: Agent;
  recentEvents: KEvent[];
  onPrompt: (text: string) => Promise<void>;
}) {
  const [draft, setDraft] = useState("");
  const [sending, setSending] = useState(false);
  const inputRef = useRef<HTMLTextAreaElement>(null);

  // Are we waiting for the operator to answer an ask_operator?
  const lastAskIdx = (() => {
    for (let i = recentEvents.length - 1; i >= 0; i--) {
      const k = recentEvents[i].kind;
      if (k === "driver.ask_operator") return i;
      if (k === "operator.message") return -1; // already answered
    }
    return -1;
  })();
  const awaitingOperator = lastAskIdx >= 0;
  const status = agent.status;

  const send = async () => {
    const text = draft.trim();
    if (!text || sending) return;
    setSending(true);
    try {
      await onPrompt(text);
      setDraft("");
    } catch (e) {
      console.error("prompt failed", e);
    } finally {
      setSending(false);
      inputRef.current?.focus();
    }
  };

  const placeholder =
    status === "terminated" || status === "failed"
      ? "driver has ended — start a new mission"
      : awaitingOperator
        ? "answer the driver's question…"
        : "send a follow-up to the driver…";

  const disabled = status === "terminated" || status === "failed";

  return (
    <footer
      style={{
        display: "flex",
        gap: 6,
        alignItems: "flex-end",
        padding: 8,
        background: "var(--bg-2)",
        borderTop: `1px solid ${
          awaitingOperator ? "var(--status-suspended)" : "var(--border)"
        }`,
        flexShrink: 0,
      }}
      // Stop drag/click bubbling so typing in the textarea
      // doesn't try to drag the tile.
      onMouseDown={(e) => e.stopPropagation()}
      onClick={(e) => e.stopPropagation()}
    >
      <textarea
        ref={inputRef}
        value={draft}
        onChange={(e) => setDraft(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && !e.shiftKey) {
            e.preventDefault();
            send();
          }
        }}
        disabled={disabled}
        placeholder={placeholder}
        rows={2}
        style={{
          flex: 1,
          background: "var(--bg)",
          color: "var(--text)",
          border: "1px solid var(--border)",
          borderRadius: 4,
          padding: "6px 8px",
          fontSize: 12,
          fontFamily: "inherit",
          resize: "none",
          outline: "none",
          opacity: disabled ? 0.5 : 1,
        }}
      />
      <button
        onClick={send}
        disabled={disabled || !draft.trim() || sending}
        style={{
          background:
            !disabled && draft.trim() && !sending
              ? "var(--accent)"
              : "var(--bg-2)",
          color:
            !disabled && draft.trim() && !sending
              ? "var(--bg)"
              : "var(--text-4)",
          border: "1px solid var(--border)",
          borderRadius: 3,
          padding: "6px 10px",
          fontSize: 11,
          fontWeight: 600,
          cursor:
            !disabled && draft.trim() && !sending
              ? "pointer"
              : "not-allowed",
          textTransform: "uppercase",
          letterSpacing: 0.5,
          flexShrink: 0,
        }}
      >
        {sending ? "…" : "send"}
      </button>
    </footer>
  );
}

// --- exported helpers ---

export function lastEventText(events: KEvent[]): string | null {
  if (events.length === 0) return null;
  const last = events[events.length - 1];
  const p = last.payload as Record<string, unknown> | undefined;
  const text = (p?.text ?? p?.message) as string | undefined;
  return text ?? last.kind;
}

export function formatTime(ts: string): string {
  try {
    const d = new Date(ts);
    return d.toLocaleTimeString("en-US", {
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hour12: false,
    });
  } catch {
    return ts.slice(11, 19);
  }
}
