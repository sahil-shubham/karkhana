/**
 * Karkhana computer-use-cli — the HEADLESS worker extension.
 *
 * Loaded by recipes whose workers don't have an X11 desktop
 * (currently: headless-dev). Provides only:
 *
 *   - write_note: contribute findings to the mission blackboard.
 *                 Same on-the-wire shape as computer-use's
 *                 write_note; the tool is a no-op locally and
 *                 Karkhana host-side picks it up from the pi-rpc
 *                 tool_execution_start stream.
 *   - finish:     terminate the worker cleanly. Mirrors the
 *                 termination idiom from the computer-use ext;
 *                 returns terminate:true so pi's agent loop
 *                 actually unwinds.
 *
 * Everything else a headless worker needs — bash, read, write,
 * edit, grep, find, glob, ls — is part of pi-coding-agent's
 * built-in tool set. No GUI, no chromium, no scrot, no
 * xdotool. The kk-dev bhatti image deliberately omits all of
 * those to boot fast.
 *
 * Why two extensions instead of one with a "mode" flag:
 *   - The image either has scrot+xdotool+chromium or it doesn't.
 *     Loading GUI tools onto a headless image just produces
 *     mysterious runtime errors. The extension surface should
 *     match the image surface.
 *   - Recipes pick an extension path explicitly; the picker
 *     reads cleanly as "this recipe gets these tools."
 *
 * Loaded by adding
 *   --extension /usr/local/share/karkhana/extensions/computer-use-cli/index.ts
 * to the pi-rpc spawn args. The kk-dev Dockerfile copies this
 * file to that path; the headless-dev recipe references it.
 */

import { Type } from "typebox";
import { defineTool, type ExtensionAPI } from "@mariozechner/pi-coding-agent";

// --- write_note (blackboard, signalling-only) ---
//
// IMPORTANT: this tool's execute() is intentionally a no-op.
// The actual blackboard write happens in Karkhana's host process
// when it sees the worker.tool_call event on the pi-rpc stream
// (see cmd/karkhana/main.go → persistBlackboardWrite). We can't
// HTTP back to the host from inside the sandbox cleanly because
// the host's address varies per deployment; piggy-backing on
// the open pi-rpc WebSocket keeps the design environment-
// agnostic.

const writeNoteTool = defineTool({
  name: "write_note",
  label: "Write Note (blackboard)",
  description:
    "Contribute a finding to the mission's shared blackboard. " +
    "The driver agent reads these during synthesis. Append-only " +
    "— multiple notes under the same key accumulate.\n\n" +
    "Keys are free-form snake_case topic labels (e.g. " +
    "'repo_arch', 'api_endpoints'). Write notes INCREMENTALLY as " +
    "you discover things; don't save up for one giant final dump.",
  parameters: Type.Object({
    key: Type.String({
      description: "Short topic label, snake_case. Stable across notes.",
    }),
    content: Type.String({
      description:
        "The finding itself. Plain text or markdown. Include " +
        "file paths, line refs, URLs as appropriate.",
    }),
    summary: Type.Optional(
      Type.String({
        description:
          "One-line summary (≤ 80 chars) shown in the blackboard " +
          "manifest. If omitted, the manifest truncates content.",
      }),
    ),
  }),
  async execute(_id, { key, content, summary }) {
    // No local persistence; Karkhana host catches the
    // tool_execution_start event and writes to the notes table.
    return {
      content: [
        {
          type: "text" as const,
          text: `wrote note: ${key} (${content.length} chars)`,
        },
      ],
      details: {
        key,
        content_len: content.length,
        summary: summary ?? content.slice(0, 80),
      },
    };
  },
});

// --- finish (terminate worker) ---
//
// Same rationale as in computer-use: pi's natural agent_end
// (text-only response → end of turn) has been flaky to detect
// through the bhatti exec/ws transport. `terminate: true` on a
// tool result deterministically ends the worker's pi loop. The
// driver-side preamble teaches calling this as the last action.

const finishTool = defineTool({
  name: "finish",
  label: "Finish (terminate worker)",
  description:
    "Mark this worker's task complete. Call this as your VERY " +
    "LAST tool call — immediately after your final write_note. " +
    "The `summary` you pass is what the driver sees as your " +
    "final answer; keep it short because your detailed findings " +
    "are already in write_note. After this call returns, the " +
    "worker terminates.\n\n" +
    "Do NOT call any other tools after finish. Do NOT respond " +
    "with a final assistant message after finish — the tool's " +
    "text result IS your final response to the driver.",
  parameters: Type.Object({
    summary: Type.String({
      description:
        "Short summary (≤ 500 chars) of what you accomplished. " +
        "Reference your blackboard keys (e.g. 'recorded 5 findings " +
        "under repo_arch; see blackboard for details').",
    }),
  }),
  async execute(_id, { summary }) {
    return {
      content: [{ type: "text" as const, text: summary }],
      details: { summary },
      // Critical: pi's agent loop reads `terminate` on tool
      // results; true → hasMoreToolCalls=false → agent_end.
      // See pi-mono packages/agent/src/agent-loop.ts.
      terminate: true,
    };
  },
});

// --- registration ---

export default function (pi: ExtensionAPI) {
  pi.registerTool(writeNoteTool);
  pi.registerTool(finishTool);

  // Note: no bash interceptor in headless-dev. The curl block
  // in computer-use is desktop-watch policy (force visible
  // browser); headless-dev workers are explicitly the recipe
  // for shell work and may curl freely. Recipe-level
  // allow_http enforcement lands in a follow-up.
}
