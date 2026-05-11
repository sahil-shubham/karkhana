// NewMissionPopover — the inline "type a goal" input that
// appears when the operator right-clicks the empty canvas.
//
// Floats absolutely-positioned at the click point in screen
// coordinates (NOT canvas-coordinates — we don't pan/zoom this).
// Auto-focuses on mount; Enter dispatches the mission, Esc
// cancels, click-outside cancels.
//
// Per v0.6: this is the ONLY way to start a new mission.
// There's no left-side dispatch panel, no command palette.

import { useEffect, useLayoutEffect, useRef, useState } from "react";

interface Props {
  screenX: number;
  screenY: number;
  onSubmit: (goal: string) => void;
  onCancel: () => void;
}

export function NewMissionPopover({
  screenX,
  screenY,
  onSubmit,
  onCancel,
}: Props) {
  const [draft, setDraft] = useState("");
  const inputRef = useRef<HTMLTextAreaElement>(null);
  const popoverRef = useRef<HTMLDivElement>(null);

  // Auto-focus on mount.
  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  // Auto-grow the textarea on every keystroke. We measure
  // scrollHeight after resetting height to 'auto'; without the
  // reset, scrollHeight would only ever increase. Capped so a
  // pasted essay doesn't push the popover off-screen.
  useLayoutEffect(() => {
    const el = inputRef.current;
    if (!el) return;
    el.style.height = "auto";
    const max = Math.min(
      window.innerHeight - 200, // leave room for header + footer + chrome
      560,
    );
    el.style.height = Math.min(el.scrollHeight, max) + "px";
  }, [draft]);

  // Esc to cancel; click-outside to cancel.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        onCancel();
      }
    };
    const onClick = (e: MouseEvent) => {
      if (
        popoverRef.current &&
        !popoverRef.current.contains(e.target as Node)
      ) {
        onCancel();
      }
    };
    window.addEventListener("keydown", onKey);
    // Defer the click listener so the right-click that opened us
    // doesn't immediately close us.
    const t = setTimeout(() => {
      window.addEventListener("mousedown", onClick);
    }, 0);
    return () => {
      window.removeEventListener("keydown", onKey);
      clearTimeout(t);
      window.removeEventListener("mousedown", onClick);
    };
  }, [onCancel]);

  const submit = () => {
    const goal = draft.trim();
    if (!goal) return;
    onSubmit(goal);
  };

  // Position the popover. Anchored at the click point, kept on-
  // screen if the click was near the edges. Height is no longer
  // fixed (textarea auto-grows); we use the popover's actual
  // measured height for clamping. Width is generous enough that
  // most goals don't need to wrap.
  const POPOVER_W = 640;
  const margin = 12;
  const popoverH = popoverRef.current?.offsetHeight ?? 180;
  const left = Math.min(
    Math.max(margin, screenX),
    window.innerWidth - POPOVER_W - margin,
  );
  const top = Math.min(
    Math.max(margin, screenY),
    window.innerHeight - popoverH - margin,
  );

  return (
    <div
      ref={popoverRef}
      role="dialog"
      aria-label="New mission"
      style={{
        position: "fixed",
        left,
        top,
        width: POPOVER_W,
        background: "var(--bg-1)",
        border: "1px solid var(--border)",
        borderRadius: "var(--radius)",
        boxShadow: "0 8px 24px rgba(0, 0, 0, 0.4)",
        padding: 12,
        zIndex: 1000,
        display: "flex",
        flexDirection: "column",
        gap: 8,
      }}
      onMouseDown={(e) => e.stopPropagation()}
    >
      <header
        style={{
          fontSize: 11,
          textTransform: "uppercase",
          letterSpacing: 0.5,
          color: "var(--accent)",
          fontWeight: 600,
        }}
      >
        new mission
      </header>
      <textarea
        ref={inputRef}
        value={draft}
        onChange={(e) => setDraft(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && !e.shiftKey) {
            e.preventDefault();
            submit();
          }
        }}
        placeholder="describe what the agent should do…"
        rows={3}
        style={{
          width: "100%",
          background: "var(--bg)",
          color: "var(--text)",
          border: "1px solid var(--border)",
          borderRadius: 4,
          padding: "8px 10px",
          fontSize: 13,
          lineHeight: 1.5,
          fontFamily: "inherit",
          // No vertical scrollbar — we grow the textarea via JS
          // (see useLayoutEffect above). Height transitions are
          // size-driven, not scroll-driven.
          resize: "none",
          overflow: "hidden",
          outline: "none",
          boxSizing: "border-box",
          minHeight: 72,
        }}
      />
      <footer
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          fontSize: 10,
          color: "var(--text-4)",
        }}
      >
        <span>↵ to dispatch · esc to cancel</span>
        <button
          onClick={submit}
          disabled={!draft.trim()}
          style={{
            background: draft.trim() ? "var(--accent)" : "var(--bg-2)",
            color: draft.trim() ? "var(--bg)" : "var(--text-4)",
            border: "none",
            borderRadius: 3,
            padding: "4px 12px",
            fontSize: 11,
            fontWeight: 600,
            cursor: draft.trim() ? "pointer" : "not-allowed",
            textTransform: "uppercase",
            letterSpacing: 0.5,
          }}
        >
          dispatch
        </button>
      </footer>
    </div>
  );
}
