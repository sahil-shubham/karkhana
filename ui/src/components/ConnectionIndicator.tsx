// ConnectionIndicator — small floating widget showing the WS
// connection state. With the sidebar gone (v0.6), this is the
// only chrome where the operator can see whether the canvas is
// receiving live events.
//
// Rendered top-left, low-key. Color = state, label appears on
// hover.

import type { ConnState } from "../lib/ws";

const LABEL: Record<ConnState, string> = {
  connecting: "connecting",
  open: "live",
  closed: "disconnected",
  error: "error",
};

const COLOR: Record<ConnState, string> = {
  connecting: "var(--status-suspended)",
  open: "var(--status-running)",
  closed: "var(--status-fail)",
  error: "var(--status-fail)",
};

export function ConnectionIndicator({ state }: { state: ConnState }) {
  const label = LABEL[state] ?? "?";
  const color = COLOR[state] ?? "var(--text-4)";

  return (
    <div
      title={`canvas: ${label}`}
      style={{
        position: "fixed",
        top: 14,
        left: 14,
        zIndex: 999,
        display: "flex",
        alignItems: "center",
        gap: 8,
        padding: "5px 10px",
        background: "var(--bg-1)",
        border: "1px solid var(--border)",
        borderRadius: "var(--radius)",
        fontSize: 10,
        color: "var(--text-3)",
        textTransform: "uppercase",
        letterSpacing: 0.5,
        userSelect: "none",
        cursor: "default",
      }}
    >
      <span
        style={{
          display: "inline-block",
          width: 7,
          height: 7,
          borderRadius: "50%",
          background: color,
          boxShadow: state === "open" ? `0 0 4px ${color}` : "none",
        }}
      />
      <span>karkhana · {label}</span>
    </div>
  );
}
