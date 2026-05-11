// ArtifactTile — the mission's typed deliverable rendered as a
// canvas node. v0.7: one per mission, type "markdown:report",
// produced when the driver calls finish().
//
// Visual: title bar + scrollable rendered body. We deliberately
// don't pull in a heavy markdown renderer for v0; the content
// is shown verbatim with whitespace + simple heading hinting.
// Operator can right-click → "Open fullscreen" for a richer view
// later; for now the tile content reads like a textarea.

import { Handle, NodeResizer, Position, type NodeProps } from "@xyflow/react";
import { useEffect, useState } from "react";
import type { Artifact } from "../lib/types";
import { api } from "../lib/api";
import { formatTime } from "./AgentTile";

export interface ArtifactTileData extends Record<string, unknown> {
  artifactID: string;
  // Metadata received via artifact.created event (no full
  // content). The tile fetches full content on mount via
  // api.getArtifact and caches it locally.
  type: string;
  title: string;
  summary?: string;
  createdAt?: string;
}

export function ArtifactTile({ data, selected }: NodeProps) {
  const { artifactID, type, title, summary, createdAt } =
    data as ArtifactTileData;
  const [artifact, setArtifact] = useState<Artifact | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    api
      .getArtifact(artifactID)
      .then((a) => {
        if (!cancelled) setArtifact(a);
      })
      .catch((e) => {
        if (!cancelled) setError(String(e));
      });
    return () => {
      cancelled = true;
    };
  }, [artifactID]);

  const accent = "var(--accent-artifact, #e6b800)";

  return (
    <div
      className="tile"
      style={{
        background: "var(--bg-1)",
        border: `1px solid ${accent}`,
        borderRadius: "var(--radius)",
        width: "100%",
        height: "100%",
        display: "flex",
        flexDirection: "column",
        overflow: "hidden",
        boxShadow: `0 0 0 1px ${accent}22`,
      }}
    >
      <NodeResizer
        isVisible={selected}
        minWidth={400}
        minHeight={260}
        maxWidth={2000}
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
        <span style={{ color: accent }}>📄</span>
        <span style={{ color: accent, fontWeight: 700 }}>ARTIFACT</span>
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
          {title}
        </span>
        <span style={{ color: "var(--text-4)", fontSize: 10 }}>
          {type.replace("markdown:", "")}
        </span>
      </header>

      <div
        style={{
          flex: 1,
          overflow: "auto",
          padding: "14px 18px",
          fontSize: 13,
          lineHeight: 1.55,
          color: "var(--text)",
          fontFamily: "system-ui, sans-serif",
        }}
      >
        {error ? (
          <div style={{ color: "var(--status-fail)" }}>
            failed to load: {error}
          </div>
        ) : artifact == null ? (
          <div style={{ color: "var(--text-4)", fontStyle: "italic" }}>
            loading…
            {summary && (
              <div style={{ marginTop: 8, color: "var(--text-3)" }}>
                {summary}
              </div>
            )}
          </div>
        ) : (
          <MarkdownPreview content={artifact.content} />
        )}
      </div>

      <footer
        style={{
          padding: "5px 10px",
          background: "var(--bg-2)",
          borderTop: "1px solid var(--border)",
          fontSize: 10,
          color: "var(--text-4)",
          display: "flex",
          gap: 8,
          flexShrink: 0,
        }}
      >
        <span>id: {artifactID.slice(-12)}</span>
        {createdAt && <span>· {formatTime(createdAt)}</span>}
        {artifact && (
          <span style={{ marginLeft: "auto" }}>
            {artifact.content.length.toLocaleString()} chars
          </span>
        )}
      </footer>

      <Handle
        type="target"
        position={Position.Top}
        style={{ background: accent, width: 6, height: 6 }}
      />
    </div>
  );
}

// MarkdownPreview — quick-and-dirty renderer. For v0.7 we keep
// it dependency-free: preserve whitespace, bold-ish headings,
// monospace code spans. If we end up wanting real markdown,
// swap in react-markdown later.
function MarkdownPreview({ content }: { content: string }) {
  const lines = content.split("\n");
  return (
    <>
      {lines.map((line, i) => {
        // Heading levels by `#` count.
        if (line.startsWith("# ")) {
          return (
            <div
              key={i}
              style={{
                fontSize: 18,
                fontWeight: 700,
                marginTop: i === 0 ? 0 : 16,
                marginBottom: 6,
              }}
            >
              {line.slice(2)}
            </div>
          );
        }
        if (line.startsWith("## ")) {
          return (
            <div
              key={i}
              style={{
                fontSize: 15,
                fontWeight: 600,
                marginTop: 14,
                marginBottom: 4,
              }}
            >
              {line.slice(3)}
            </div>
          );
        }
        if (line.startsWith("### ")) {
          return (
            <div
              key={i}
              style={{
                fontSize: 13,
                fontWeight: 600,
                marginTop: 12,
                marginBottom: 4,
              }}
            >
              {line.slice(4)}
            </div>
          );
        }
        if (line.match(/^\s*[-*]\s/)) {
          return (
            <div key={i} style={{ paddingLeft: 16, position: "relative" }}>
              <span
                style={{
                  position: "absolute",
                  left: 4,
                  color: "var(--text-3)",
                }}
              >
                •
              </span>
              {line.replace(/^\s*[-*]\s/, "")}
            </div>
          );
        }
        if (line.trim() === "") {
          return <div key={i} style={{ height: 6 }} />;
        }
        return (
          <div key={i} style={{ whiteSpace: "pre-wrap" }}>
            {line}
          </div>
        );
      })}
    </>
  );
}
