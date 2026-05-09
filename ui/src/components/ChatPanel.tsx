// ChatPanel — the operator's side panel for typing goals.
//
// At v0 (POC), it's a textarea + submit button that POSTs to
// /api/missions and clears. Mission history shows below. When the
// driver agent lands, the panel evolves into a chat surface for
// talking to the driver mid-mission.

import { useState } from "react";
import type { Mission } from "../lib/types";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuSeparator,
  ContextMenuTrigger,
} from "./ui/ContextMenu";

interface Props {
  missions: Mission[];
  activeMissionID: string | null;
  onCreateMission: (goal: string) => void;
  onSelectMission: (id: string) => void;
  onDeleteMission: (id: string) => void;
  onHome: () => void;
  connState: string;
}

export function ChatPanel({
  missions,
  activeMissionID,
  onCreateMission,
  onSelectMission,
  onDeleteMission,
  onHome,
  connState,
}: Props) {
  const [draft, setDraft] = useState("");

  const submit = () => {
    const goal = draft.trim();
    if (!goal) return;
    onCreateMission(goal);
    setDraft("");
  };

  return (
    <aside
      style={{
        width: 320,
        height: "100%",
        background: "var(--bg)",
        borderRight: "1px solid var(--border)",
        display: "flex",
        flexDirection: "column",
      }}
    >
      <header
        style={{
          padding: "10px 14px",
          borderBottom: "1px solid var(--border)",
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          fontSize: 12,
          textTransform: "uppercase",
          letterSpacing: 0.5,
          color: "var(--text-3)",
        }}
      >
        <button
          onClick={onHome}
          style={{
            background: "transparent",
            color: "var(--text-2)",
            border: "none",
            padding: 0,
            fontSize: 12,
            textTransform: "uppercase",
            letterSpacing: 0.5,
            cursor: "pointer",
            fontWeight: 600,
          }}
          title="Back to home (deselect mission)"
        >
          Karkhana
        </button>
        <ConnIndicator state={connState} />
      </header>

      {/* Mission input */}
      <div style={{ padding: 12, borderBottom: "1px solid var(--border)" }}>
        <textarea
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          placeholder="Describe a goal — e.g. 'research top 8 PM tools and compare'"
          rows={4}
          style={{ width: "100%", resize: "vertical" }}
          onKeyDown={(e) => {
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
              e.preventDefault();
              submit();
            }
          }}
        />
        <button
          onClick={submit}
          disabled={!draft.trim()}
          style={{
            marginTop: 8,
            padding: "6px 12px",
            background: "var(--accent)",
            color: "var(--bg)",
            border: "none",
            borderRadius: "var(--radius)",
            fontWeight: 600,
            opacity: draft.trim() ? 1 : 0.4,
            width: "100%",
          }}
        >
          Dispatch  ⌘↵
        </button>
      </div>

      {/* Mission list */}
      <div style={{ flex: 1, overflowY: "auto", padding: 8 }}>
        <div
          style={{
            fontSize: 11,
            textTransform: "uppercase",
            letterSpacing: 0.5,
            color: "var(--text-4)",
            padding: "4px 6px",
          }}
        >
          Missions ({missions.length})
        </div>
        {missions.length === 0 && (
          <div
            style={{
              padding: 12,
              fontSize: 12,
              color: "var(--text-4)",
              fontStyle: "italic",
            }}
          >
            no missions yet
          </div>
        )}
        {missions.map((m) => (
          <ContextMenu key={m.id}>
            <ContextMenuTrigger asChild>
              <button
                onClick={() => onSelectMission(m.id)}
                style={{
                  display: "block",
                  width: "100%",
                  textAlign: "left",
                  padding: "8px 10px",
                  marginTop: 2,
                  background:
                    activeMissionID === m.id ? "var(--bg-2)" : "transparent",
                  color: "var(--text-2)",
                  border: "none",
                  borderRadius: "var(--radius)",
                  fontSize: 12,
                  cursor: "pointer",
                }}
              >
                <div
                  style={{
                    whiteSpace: "nowrap",
                    overflow: "hidden",
                    textOverflow: "ellipsis",
                  }}
                >
                  {m.goal}
                </div>
                <div
                  style={{
                    color: "var(--text-4)",
                    fontSize: 10,
                    marginTop: 2,
                  }}
                >
                  {m.status} · {m.id.slice(0, 12)}
                </div>
              </button>
            </ContextMenuTrigger>
            <ContextMenuContent>
              <ContextMenuItem onSelect={() => onSelectMission(m.id)}>
                Open
              </ContextMenuItem>
              <ContextMenuItem
                onSelect={() =>
                  navigator.clipboard.writeText(m.id).catch(() => {})
                }
              >
                Copy mission ID
              </ContextMenuItem>
              <ContextMenuSeparator />
              <ContextMenuItem
                variant="danger"
                onSelect={() => onDeleteMission(m.id)}
              >
                Delete mission
              </ContextMenuItem>
            </ContextMenuContent>
          </ContextMenu>
        ))}
      </div>
    </aside>
  );
}

function ConnIndicator({ state }: { state: string }) {
  let color = "var(--status-terminated)";
  if (state === "open") color = "var(--status-success)";
  else if (state === "connecting") color = "var(--status-suspended)";
  else if (state === "error" || state === "closed")
    color = "var(--status-fail)";

  return (
    <span
      title={`event stream: ${state}`}
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: 4,
        fontSize: 10,
      }}
    >
      <span
        style={{
          width: 6,
          height: 6,
          borderRadius: "50%",
          background: color,
        }}
      />
      <span style={{ color: "var(--text-4)" }}>{state}</span>
    </span>
  );
}
