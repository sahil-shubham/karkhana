// BlackboardTile — the mission's shared scratchpad rendered as
// a canvas node. One per mission, sibling to the driver tile.
//
// Sources of truth:
//   - `notes` prop: an array of all blackboard notes for the
//     mission, hydrated by App via api.listNotes on mount and
//     appended-to as worker.note_write events arrive on the WS.
//   - `recentWriteAgent` (optional): the most recent writer,
//     used to briefly highlight the tile when activity happens.
//
// Visual model: a tight scrollable list of rows. Each row is
// one note: agent badge · key · summary · relative time. Click
// a row to expand inline and reveal the full content.

import { Handle, NodeResizer, Position, type NodeProps } from "@xyflow/react";
import { useEffect, useMemo, useRef, useState } from "react";
import type { Note } from "../lib/types";
import { formatTime } from "./AgentTile";

export interface BlackboardTileData extends Record<string, unknown> {
  missionID: string;
  notes: Note[];
  // ID + ts of the most recent worker.note_write event, so the
  // tile briefly flashes when a new note arrives.
  lastWriteAt?: string;
}

export function BlackboardTile({ data, selected }: NodeProps) {
  const { notes, lastWriteAt } = data as BlackboardTileData;

  // Brief flash on new write — react-flow re-renders all nodes
  // when any node's data changes, so this effect triggers on
  // every event but only "lights up" when lastWriteAt advances.
  const [flashing, setFlashing] = useState(false);
  const lastSeen = useRef<string | undefined>(lastWriteAt);
  useEffect(() => {
    if (lastWriteAt && lastWriteAt !== lastSeen.current) {
      lastSeen.current = lastWriteAt;
      setFlashing(true);
      const t = setTimeout(() => setFlashing(false), 700);
      return () => clearTimeout(t);
    }
  }, [lastWriteAt]);

  // Reverse-sort so the newest note is on top; this matches the
  // operator's "what's happening right now" intent.
  const ordered = useMemo(
    () => [...notes].sort((a, b) => b.id - a.id),
    [notes],
  );

  const accent = "var(--accent-blackboard, var(--accent))";

  return (
    <div
      className="tile"
      style={{
        background: "var(--bg-1)",
        border: `1px solid ${flashing ? accent : "var(--border)"}`,
        borderRadius: "var(--radius)",
        width: "100%",
        height: "100%",
        display: "flex",
        flexDirection: "column",
        overflow: "hidden",
        boxShadow: flashing ? `0 0 0 2px ${accent}33` : "none",
        transition: "border-color 200ms, box-shadow 200ms",
      }}
    >
      <NodeResizer
        isVisible={selected}
        minWidth={300}
        minHeight={200}
        maxWidth={1200}
        maxHeight={1400}
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
        <span style={{ color: accent, fontWeight: 600 }}>BLACKBOARD</span>
        <span style={{ color: "var(--text-3)" }}>·</span>
        <span
          style={{
            color: "var(--text-2)",
            fontWeight: 500,
            flex: 1,
          }}
        >
          {notes.length} {notes.length === 1 ? "note" : "notes"}
        </span>
      </header>

      <div style={{ flex: 1, overflow: "auto", padding: "4px 0" }}>
        {ordered.length === 0 ? (
          <div
            style={{
              color: "var(--text-4)",
              fontSize: 11,
              fontStyle: "italic",
              padding: "12px 14px",
              textAlign: "center",
            }}
          >
            no contributions yet — workers will write findings here
          </div>
        ) : (
          ordered.map((n) => <NoteRow key={n.id} note={n} accent={accent} />)
        )}
      </div>

      {/*
        Two target handles, geometrically distinct:
          "driver"   — Top edge. The driver tile sits above
                       the blackboard (lane top), so its
                       edge enters from above.
          "contrib"  — Left edge. Workers sit in a grid to the
                       blackboard's left and contribute via
                       their right-side source handle, so
                       writes enter from the left as short
                       horizontal stubs (smoothstep routed).
        Keeping the two handles physically separated stops
        contribution lines from piling on top of the driver
        edge.
      */}
      <Handle
        type="target"
        id="driver"
        position={Position.Top}
        style={{
          background: "var(--border)",
          width: 6,
          height: 6,
        }}
      />
      <Handle
        type="target"
        id="contrib"
        position={Position.Left}
        style={{
          background: accent,
          width: 8,
          height: 8,
        }}
      />
    </div>
  );
}

function NoteRow({ note, accent }: { note: Note; accent: string }) {
  const [expanded, setExpanded] = useState(false);
  // Visual model:
  //   - Header line: key · agent · timestamp (compact)
  //   - Summary line (if provided, the worker's own 1-line title)
  //     in higher contrast — makes the scan feel like a feed
  //   - Preview body: first ~240 chars of content, two-line clamped.
  //     Operator clicks to expand to full content. We default to
  //     showing real content (not just summary), because that's
  //     what makes the blackboard feel like a research surface,
  //     not a list of one-liners.
  const hasSummary = !!(note.summary && note.summary.length > 0);
  const agentShort = note.agent_id ? note.agent_id.slice(-8) : "?";
  // Strip a leading markdown heading on the body preview so the
  // first visible line isn't "## Section title" — it'd duplicate
  // the summary in spirit.
  const body = note.content.replace(/^\s*#{1,6}\s+[^\n]+\n+/, "");
  const preview = body.slice(0, 280);

  return (
    <div
      onClick={() => setExpanded((v) => !v)}
      style={{
        padding: "7px 10px",
        borderBottom: "1px solid var(--border)",
        cursor: "pointer",
        fontSize: 11,
        lineHeight: 1.5,
        color: "var(--text-2)",
      }}
    >
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
            color: accent,
            fontWeight: 600,
            fontFamily: "var(--font-mono, monospace)",
            fontSize: 10,
          }}
        >
          {note.key}
        </span>
        <span style={{ color: "var(--text-4)", fontSize: 9 }}>·</span>
        <span style={{ color: "var(--text-4)", fontSize: 9 }}>
          {agentShort}
        </span>
        <span style={{ color: "var(--text-4)", fontSize: 9 }}>·</span>
        <span style={{ color: "var(--text-4)", fontSize: 9 }}>
          {formatTime(note.ts)}
        </span>
        <span
          style={{
            marginLeft: "auto",
            color: "var(--text-4)",
            fontSize: 9,
          }}
        >
          {expanded ? "▼" : "▶"} {note.content.length} ch
        </span>
      </div>
      {hasSummary && (
        <div
          style={{
            color: "var(--text)",
            fontWeight: 500,
            marginBottom: 3,
          }}
        >
          {note.summary}
        </div>
      )}
      <div
        style={{
          color: "var(--text-3)",
          whiteSpace: "pre-wrap",
          wordBreak: "break-word",
          maxHeight: expanded ? "none" : 48,
          overflow: "hidden",
          position: "relative",
        }}
      >
        {expanded ? body : preview}
        {!expanded && body.length > preview.length && (
          <div
            style={{
              position: "absolute",
              bottom: 0,
              left: 0,
              right: 0,
              height: 18,
              background:
                "linear-gradient(to bottom, transparent, var(--bg-1))",
              pointerEvents: "none",
            }}
          />
        )}
      </div>
    </div>
  );
}
