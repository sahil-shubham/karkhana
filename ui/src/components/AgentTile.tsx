// AgentTile — the primary tile per agent.
//
//   Driver  → body is the scrolling event stream (no sandbox).
//   Worker  → body is the KasmVNC desktop iframe.
//
// Workers also get a sibling AgentLogTile (right of this one)
// that renders the same event-stream view, so the operator can
// watch the desktop AND read the agent's reasoning without
// flipping back and forth. Both tiles are independently
// resizable via NodeResizer.
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
  onFocus: () => void;
  onTerminate?: () => void;
  // Set on the root tile of a mission only (the agent that has
  // no parent). v0.6 has no sidebar; this is how the operator
  // ends a whole mission — right-click the root → Delete mission.
  onDeleteMission?: () => void;
}

export function AgentTile({ data, selected }: NodeProps) {
  const { agent, recentEvents, focused, onFocus, onTerminate, onDeleteMission } =
    data as AgentTileData;
  const isDriver = agent.role === "driver";
  const accent = isDriver ? "var(--accent)" : "var(--accent-worker)";

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
      className="tile"
      style={{
        background: "var(--bg-1)",
        border: `1px solid ${focused ? accent : "var(--border)"}`,
        borderRadius: "var(--radius)",
        width: "100%",
        height: "100%",
        display: "flex",
        flexDirection: "column",
        boxShadow: focused ? `0 0 0 2px ${accent}33` : "none",
        overflow: "hidden",
        position: "relative",
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
      />

      <div style={{ flex: 1, position: "relative", overflow: "hidden" }}>
        {isDriver ? (
          <EventStream events={recentEvents} />
        ) : (
          <WorkerView
            agentID={agent.id}
            hasURL={!!desktopURL}
            focused={focused}
            onFocus={onFocus}
          />
        )}
      </div>

      {/* Footer (last assistant message) only on the driver tile.
          Worker tiles have a paired log sibling that already shows
          the full stream; a one-line redundant footer below the
          desktop iframe just steals vertical space. */}
      {isDriver && <TileFooter agent={agent} recentEvents={recentEvents} />}

      {/* spawn edges (driver → worker, worker → sub-worker) */}
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
      {/* view edge to the paired log tile (workers only).
          Bottom-center, immediately below the spawn handle so it
          looks like one logical attachment point. */}
      {!isDriver && (
        <Handle
          id="log"
          type="source"
          position={Position.Bottom}
          style={{
            background: "var(--accent-worker)",
            width: 6,
            height: 6,
            // Center horizontally; sit right at the edge so the
            // edge to the log tile drops straight down.
          }}
        />
      )}
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
}: {
  accent: string;
  roleLabel: string;
  agent: Agent;
  onTerminate?: () => void;
}) {
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
      <span style={{ color: "var(--text-4)", fontSize: 10 }}>
        ${(agent.cost_usd ?? 0).toFixed(2)}
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
