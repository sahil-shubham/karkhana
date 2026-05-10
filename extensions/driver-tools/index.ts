/**
 * Karkhana driver-tools extension for pi-coding-agent.
 *
 * Runs in a `pi --mode rpc` subprocess on the KARKHANA HOST
 * (NOT inside a bhatti sandbox). Registers the 5 tools the
 * driver agent uses to orchestrate worker sandboxes:
 *
 *   spawn_worker       create a worker sandbox + pi-rpc agent
 *   wait_for_workers   block until specified workers terminate
 *   ask_operator       pause and ask the human a question
 *   report_progress    fire-and-forget progress update
 *   finish             mark a checkpoint; driver enters idle
 *
 * Each tool calls back into Karkhana via localhost HTTP at
 *   POST $KARKHANA_INTERNAL_URL/internal/driver/$KARKHANA_DRIVER_ID/<tool>
 * authed with $KARKHANA_DRIVER_TOKEN as a Bearer header. Karkhana
 * sets these env vars when it spawns the driver process; the
 * extension reads them at module load time.
 *
 * Why pi extension and not MCP — same answer as computer-use:
 * pi extensions are in-process, native, and the tool surface is
 * Karkhana-specific. MCP would add an extra IPC layer for what
 * is, here, a localhost fetch().
 */

import { Type } from "typebox";
import { defineTool, type ExtensionAPI } from "@mariozechner/pi-coding-agent";

const URL_BASE = process.env.KARKHANA_INTERNAL_URL || "http://localhost:4000";
const DRIVER_TOKEN = process.env.KARKHANA_DRIVER_TOKEN || "";
const DRIVER_ID = process.env.KARKHANA_DRIVER_ID || "";

if (!DRIVER_TOKEN || !DRIVER_ID) {
  // Don't throw — pi loads extensions at startup, and a missing
  // token here would crash the whole process before the operator
  // can even see what went wrong. Log clearly and let tools fail
  // individually with a useful error if anyone calls them.
  console.error(
    "[karkhana driver-tools] KARKHANA_DRIVER_TOKEN or _ID missing; tool calls will fail.",
  );
}

interface KarkhanaError extends Error {
  status?: number;
  body?: string;
}

async function karkhanaCall<T>(path: string, body: unknown): Promise<T> {
  if (!DRIVER_TOKEN || !DRIVER_ID) {
    throw new Error(
      "driver tools not configured: KARKHANA_DRIVER_TOKEN / _ID env unset",
    );
  }
  const url = `${URL_BASE}/internal/driver/${encodeURIComponent(DRIVER_ID)}${path}`;
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${DRIVER_TOKEN}`,
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const txt = await res.text().catch(() => "");
    const e: KarkhanaError = new Error(
      `karkhana ${path} ${res.status}: ${txt.slice(0, 200)}`,
    );
    e.status = res.status;
    e.body = txt;
    throw e;
  }
  // Tolerate empty 204s.
  const txt = await res.text();
  if (!txt) return {} as T;
  return JSON.parse(txt) as T;
}

// --- spawn_worker ---

interface SpawnWorkerResult {
  worker_id: string;
  sandbox_id: string;
  status: string;
}

const spawnWorkerTool = defineTool({
  name: "spawn_worker",
  label: "Spawn Worker",
  description:
    "Spawn a new worker agent in its own bhatti microVM, with the " +
    "computer-use toolset (browser, screenshot, click, type, " +
    "scroll). The worker runs in parallel with other workers and " +
    "this driver. Returns the worker's ID, which can be passed " +
    "to wait_for_workers later. Returns immediately — does NOT " +
    "block waiting for the worker to finish.",
  parameters: Type.Object({
    task: Type.String({
      description:
        "The focused task this worker should accomplish, written as " +
        "if you were prompting an agent fresh. Be concrete: include " +
        "URLs, success criteria, and the expected output shape. " +
        "Workers don't see the conversation history with the " +
        "operator, only what you put here.",
    }),
  }),
  async execute(_id, { task }) {
    const r = await karkhanaCall<SpawnWorkerResult>("/spawn_worker", { task });
    return {
      content: [
        {
          type: "text" as const,
          text:
            `worker spawned: ${r.worker_id}\n` +
            `sandbox: ${r.sandbox_id}\n` +
            `status: ${r.status}`,
        },
      ],
      details: r,
    };
  },
});

// --- wait_for_workers ---

interface WaitForWorkersResult {
  workers: Array<{
    worker_id: string;
    status: string;
    outcome?: string;
    final_assistant_text?: string;
    cost_usd?: number;
  }>;
  timed_out: boolean;
}

const waitForWorkersTool = defineTool({
  name: "wait_for_workers",
  label: "Wait For Workers",
  description:
    "Block until all of the specified workers reach a terminal " +
    "state (completed, terminated, or failed). Returns each " +
    "worker's outcome and final assistant text. Use this after " +
    "spawn_worker(s) to synchronize before reading their results.",
  parameters: Type.Object({
    worker_ids: Type.Array(Type.String(), {
      description: "Worker IDs returned by spawn_worker.",
    }),
    timeout_seconds: Type.Optional(
      Type.Number({
        description:
          "Maximum total wait time in seconds (default 1800 = 30min). " +
          "Returns timed_out=true if exceeded; partial results are " +
          "returned for workers that did finish. Long research " +
          "workers can legitimately take 5-20 minutes; default high.",
      }),
    ),
  }),
  async execute(_id, { worker_ids, timeout_seconds }) {
    const r = await karkhanaCall<WaitForWorkersResult>("/wait_for_workers", {
      worker_ids,
      timeout_seconds: timeout_seconds ?? 1800,
    });
    const summary = r.workers
      .map(
        (w) =>
          `  ${w.worker_id}: ${w.status}${w.outcome ? `/${w.outcome}` : ""}` +
          (w.cost_usd != null ? ` ($${w.cost_usd.toFixed(2)})` : ""),
      )
      .join("\n");
    return {
      content: [
        {
          type: "text" as const,
          text:
            `${r.workers.length} worker(s) ${r.timed_out ? "(TIMED OUT)" : "done"}:\n` +
            summary +
            "\n\nFull outputs in details.",
        },
      ],
      details: r,
    };
  },
});

// --- ask_operator ---

interface AskOperatorResult {
  answer: string;
}

const askOperatorTool = defineTool({
  name: "ask_operator",
  label: "Ask Operator",
  description:
    "Pause and ask the human operator a question. Blocks until " +
    "they reply. Use this when the task genuinely requires " +
    "human input (ambiguous goal, credentials needed, decision " +
    "the agent shouldn't make autonomously). Don't use for " +
    "progress updates — use report_progress for that.",
  parameters: Type.Object({
    question: Type.String({
      description:
        "The question to ask the operator. Be specific; include " +
        "the context they need to answer.",
    }),
  }),
  async execute(_id, { question }) {
    const r = await karkhanaCall<AskOperatorResult>("/ask_operator", {
      question,
    });
    return {
      content: [{ type: "text" as const, text: `operator answered: ${r.answer}` }],
      details: r,
    };
  },
});

// --- report_progress ---

const reportProgressTool = defineTool({
  name: "report_progress",
  label: "Report Progress",
  description:
    "Send a short progress update to the operator without " +
    "blocking. Visible in the driver tile's chat as a styled " +
    "status message. Don't spam — one per significant milestone.",
  parameters: Type.Object({
    message: Type.String({
      description: "One-line status update.",
    }),
  }),
  async execute(_id, { message }) {
    await karkhanaCall<unknown>("/report_progress", { message });
    return {
      content: [{ type: "text" as const, text: "(progress reported)" }],
      details: { message },
    };
  },
});

// --- finish ---

const finishTool = defineTool({
  name: "finish",
  label: "Finish",
  description:
    "Mark the current task complete and return a final result " +
    "to the operator. The driver enters idle state — does NOT " +
    "exit; the operator can follow up with another instruction " +
    "and the driver picks it up with full conversation history. " +
    "Call this when you've answered the operator's request, NOT " +
    "as a process exit.",
  parameters: Type.Object({
    result: Type.String({
      description:
        "The final answer / summary, formatted for the operator. " +
        "Markdown is rendered in the driver tile.",
    }),
  }),
  async execute(_id, { result }) {
    await karkhanaCall<unknown>("/finish", { result });
    return {
      content: [
        {
          type: "text" as const,
          text: "(finished — awaiting operator follow-up)",
        },
      ],
      details: { result },
      // NOT terminate: true — the driver should keep running
      // so the operator can chat further. Pi naturally idles
      // after assistant_end with no more tool calls; the next
      // prompt picks it back up.
    };
  },
});

// --- registration ---

export default function (pi: ExtensionAPI) {
  pi.registerTool(spawnWorkerTool);
  pi.registerTool(waitForWorkersTool);
  pi.registerTool(askOperatorTool);
  pi.registerTool(reportProgressTool);
  pi.registerTool(finishTool);
}
