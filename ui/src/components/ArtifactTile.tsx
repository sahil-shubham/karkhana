// ArtifactTile — the mission's typed deliverable rendered as a
// canvas node. v0.7: one per mission, type "markdown:report",
// produced when the driver calls finish().
//
// Visual: title bar + scrollable rendered body. Renders proper
// markdown (headings / lists / tables / code / links) via
// react-markdown + remark-gfm. The header has a copy-raw
// button so the operator can paste the original markdown
// elsewhere; useful for archiving or pasting into docs.

import { Handle, NodeResizer, Position, type NodeProps } from "@xyflow/react";
import { useEffect, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
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
        {artifact && (
          <CopyRawButton text={artifact.content} />
        )}
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

// MarkdownPreview renders the artifact via react-markdown +
// remark-gfm (GitHub-flavoured markdown: tables, strikethrough,
// task lists, autolinks). Inline component overrides give us
// the canvas-native typography — we don't pull in a stylesheet.
//
// Code blocks are mono-styled but NOT syntax-highlighted (~100KB
// of highlight.js would dominate the bundle; for the current
// artifact shape — research reports, comparison tables — plain
// mono is fine). If a future artifact type needs highlighting,
// swap in rehype-highlight under a feature flag.
function MarkdownPreview({ content }: { content: string }) {
  return (
    <div className="karkhana-artifact-md">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={{
          h1: ({ children }) => (
            <h1
              style={{
                fontSize: 20,
                fontWeight: 700,
                marginTop: 16,
                marginBottom: 8,
                paddingBottom: 6,
                borderBottom: "1px solid var(--border)",
              }}
            >
              {children}
            </h1>
          ),
          h2: ({ children }) => (
            <h2
              style={{
                fontSize: 16,
                fontWeight: 600,
                marginTop: 14,
                marginBottom: 6,
              }}
            >
              {children}
            </h2>
          ),
          h3: ({ children }) => (
            <h3
              style={{
                fontSize: 14,
                fontWeight: 600,
                marginTop: 12,
                marginBottom: 4,
              }}
            >
              {children}
            </h3>
          ),
          p: ({ children }) => (
            <p style={{ margin: "6px 0" }}>{children}</p>
          ),
          ul: ({ children }) => (
            <ul style={{ margin: "6px 0", paddingLeft: 22 }}>{children}</ul>
          ),
          ol: ({ children }) => (
            <ol style={{ margin: "6px 0", paddingLeft: 22 }}>{children}</ol>
          ),
          li: ({ children }) => (
            <li style={{ margin: "2px 0" }}>{children}</li>
          ),
          a: ({ children, href }) => (
            <a
              href={href}
              target="_blank"
              rel="noopener noreferrer"
              style={{ color: "var(--accent, #4a9eff)" }}
            >
              {children}
            </a>
          ),
          code: ({ children, className }) => {
            // react-markdown calls this for BOTH inline and
            // fenced code; fenced ones come with a language
            // className (e.g. language-rust). Distinguish by
            // looking for a className.
            const isBlock = !!className;
            if (isBlock) {
              return (
                <code
                  style={{
                    display: "block",
                    padding: "8px 10px",
                    background: "var(--bg-2)",
                    border: "1px solid var(--border)",
                    borderRadius: 4,
                    fontFamily:
                      "ui-monospace, SFMono-Regular, Menlo, monospace",
                    fontSize: 11.5,
                    overflowX: "auto",
                    whiteSpace: "pre",
                  }}
                >
                  {children}
                </code>
              );
            }
            return (
              <code
                style={{
                  padding: "1px 5px",
                  background: "var(--bg-2)",
                  borderRadius: 3,
                  fontFamily:
                    "ui-monospace, SFMono-Regular, Menlo, monospace",
                  fontSize: 11.5,
                }}
              >
                {children}
              </code>
            );
          },
          pre: ({ children }) => (
            // Our `code` block already paints the box; pre is a
            // pass-through wrapper so we don't double-pad.
            <pre style={{ margin: "8px 0" }}>{children}</pre>
          ),
          blockquote: ({ children }) => (
            <blockquote
              style={{
                margin: "8px 0",
                padding: "4px 12px",
                borderLeft: "3px solid var(--border)",
                color: "var(--text-3)",
              }}
            >
              {children}
            </blockquote>
          ),
          table: ({ children }) => (
            <div style={{ overflowX: "auto", margin: "8px 0" }}>
              <table
                style={{
                  borderCollapse: "collapse",
                  fontSize: 12,
                  width: "100%",
                }}
              >
                {children}
              </table>
            </div>
          ),
          th: ({ children }) => (
            <th
              style={{
                textAlign: "left",
                padding: "6px 8px",
                borderBottom: "1px solid var(--border)",
                background: "var(--bg-2)",
                fontWeight: 600,
              }}
            >
              {children}
            </th>
          ),
          td: ({ children }) => (
            <td
              style={{
                padding: "6px 8px",
                borderBottom: "1px solid var(--border)",
                verticalAlign: "top",
              }}
            >
              {children}
            </td>
          ),
          hr: () => (
            <hr
              style={{
                border: "none",
                borderTop: "1px solid var(--border)",
                margin: "14px 0",
              }}
            />
          ),
        }}
      >
        {content}
      </ReactMarkdown>
    </div>
  );
}

// CopyRawButton puts the unrendered markdown source on the
// clipboard. The button gives a visual ack for ~1.2s so the
// operator knows the click registered (clipboard writes are
// otherwise silent in the browser).
function CopyRawButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      onClick={async (e) => {
        e.stopPropagation();
        try {
          await navigator.clipboard.writeText(text);
          setCopied(true);
          window.setTimeout(() => setCopied(false), 1200);
        } catch (err) {
          // Clipboard API can fail on insecure origins (http://
          // without localhost). Fall back to a hidden textarea
          // + execCommand for those rare cases.
          const ta = document.createElement("textarea");
          ta.value = text;
          ta.style.position = "fixed";
          ta.style.opacity = "0";
          document.body.appendChild(ta);
          ta.select();
          try {
            document.execCommand("copy");
            setCopied(true);
            window.setTimeout(() => setCopied(false), 1200);
          } catch {
            // last-resort: log; operator can still right-click
            // the artifact body and copy manually.
            console.error("copy failed:", err);
          }
          document.body.removeChild(ta);
        }
      }}
      title="Copy raw markdown to clipboard"
      style={{
        background: "transparent",
        color: copied ? "var(--status-ok, #4ade80)" : "var(--text-3)",
        border: "1px solid var(--border)",
        borderRadius: 3,
        padding: "1px 8px",
        fontSize: 10,
        fontWeight: 500,
        textTransform: "none",
        letterSpacing: 0,
        cursor: "pointer",
        transition: "color 120ms",
      }}
    >
      {copied ? "✓ copied" : "copy raw"}
    </button>
  );
}
