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

// --- spawn_worker / spawn_workers ---

interface SpawnWorkerResult {
  worker_id: string;
  sandbox_id: string;
  status: string;
}

interface SpawnWorkersResult {
  workers: SpawnWorkerResult[];
}

const spawnWorkerTool = defineTool({
  name: "spawn_worker",
  label: "Spawn Worker",
  description:
    "Spawn ONE worker agent in its own bhatti microVM. The `recipe` " +
    "argument picks the worker's shape:\n\n" +
    "  - desktop-watch  (default) headful chromium + computer-use " +
    "tools. Use for visible UI work, research, QA, click-through.\n" +
    "  - headless-dev   fast shell only, no GUI. Use for cloning " +
    "repos, grep, builds, API calls from bash.\n" +
    "  - mixed          both. Use when the shape is genuinely " +
    "unclear; most tasks fit one of the two above.\n\n" +
    "Returns immediately with the worker's ID. For fan-outs of " +
    "2 or more workers, prefer `spawn_workers` (plural).",
  parameters: Type.Object({
    task: Type.String({
      description:
        "The focused task this worker should accomplish, written as " +
        "if you were prompting an agent fresh. Be concrete: include " +
        "URLs, success criteria, and the expected output shape. " +
        "Workers don't see the conversation history with the " +
        "operator, only what you put here.",
    }),
    recipe: Type.Optional(
      Type.String({
        description:
          "Recipe name: 'desktop-watch' (default), 'headless-dev', " +
          "or 'mixed'. Omit to use the operator-configured default.",
      }),
    ),
  }),
  async execute(_id, { task, recipe }) {
    const r = await karkhanaCall<SpawnWorkerResult>("/spawn_worker", {
      task,
      recipe,
    });
    return {
      content: [
        {
          type: "text" as const,
          text:
            `worker spawned: ${r.worker_id}\n` +
            `recipe: ${(r as { recipe?: string }).recipe ?? "(default)"}\n` +
            `sandbox: ${r.sandbox_id}\n` +
            `status: ${r.status}`,
        },
      ],
      details: r,
    };
  },
});

const spawnWorkersTool = defineTool({
  name: "spawn_workers",
  label: "Spawn Workers (bulk)",
  description:
    "Spawn N worker agents in parallel — ONE tool call, N " +
    "sandboxes booted concurrently on bhatti. Each task may pick " +
    "its own recipe; missions often mix recipes (e.g. one " +
    "headless-dev worker clones the repo while a desktop-watch " +
    "worker looks at the docs site). Returns immediately — does " +
    "NOT block on worker completion.\n\n" +
    "Each entry may be a plain task string (recipe defaults) or " +
    "an object `{task, recipe}` to pick a recipe per worker.",
  parameters: Type.Object({
    tasks: Type.Array(
      Type.Union([
        Type.Object({
          task: Type.String({
            description:
              "Self-contained task description. Include URLs, " +
              "success criteria, and 'call finish(summary) when done'.",
          }),
          recipe: Type.Optional(
            Type.String({
              description:
                "Recipe name for THIS worker: 'desktop-watch' | " +
                "'headless-dev' | 'mixed'. Omit for operator default.",
            }),
          ),
        }),
        Type.String({
          description:
            "Plain task string — uses the operator default recipe. " +
            "Prefer the object form when you want to pick a recipe.",
        }),
      ]),
      { minItems: 1, maxItems: 20 },
    ),
  }),
  async execute(_id, { tasks }) {
    const r = await karkhanaCall<SpawnWorkersResult>("/spawn_workers", {
      tasks,
    });
    const lines = r.workers.map((w, i) => {
      const recipe = (w as { recipe?: string }).recipe ?? "(default)";
      return `  ${i + 1}. ${w.worker_id}  [${recipe}]  (sandbox=${w.sandbox_id})`;
    });
    return {
      content: [
        {
          type: "text" as const,
          text: `${r.workers.length} workers spawned:\n${lines.join("\n")}`,
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

// --- steer_worker / terminate_worker (active supervision) ---

const steerWorkerTool = defineTool({
  name: "steer_worker",
  label: "Steer Worker",
  description:
    "Inject a guidance message into a running worker's stream. " +
    "The worker receives it as a supervisor steer and adjusts its " +
    "current work without restarting. Use this when:\n" +
    "  - a worker's progress reveals it's exploring the wrong angle\n" +
    "  - you want to narrow scope mid-flight (e.g. \"focus on " +
    "benchmarks, skip the architecture deep-dive\")\n" +
    "  - peer findings suggest a specific follow-up for this worker\n\n" +
    "Keep hints short and concrete. The worker keeps its existing " +
    "conversation history; you're nudging, not redirecting.",
  parameters: Type.Object({
    worker_id: Type.String({ description: "Target worker id." }),
    hint: Type.String({
      description:
        "Short guidance, typically 1-3 sentences. The worker reads " +
        "this as a [supervisor steer] message.",
    }),
  }),
  async execute(_id, { worker_id, hint }) {
    await karkhanaCall<{ ok: boolean }>("/steer_worker", { worker_id, hint });
    return {
      content: [
        { type: "text" as const, text: `steered ${worker_id}: ${hint}` },
      ],
      details: { worker_id, hint },
    };
  },
});

const terminateWorkerTool = defineTool({
  name: "terminate_worker",
  label: "Terminate Worker",
  description:
    "Force-stop a worker. Kills its bhatti sandbox and marks the " +
    "agent terminated. Use when a worker is curl-looping, off-task, " +
    "diminishing-returns, or no longer needed (you have enough " +
    "info from peers).\n\n" +
    "The worker's blackboard contributions are preserved. The " +
    "reason you pass becomes the worker's final_assistant_text.",
  parameters: Type.Object({
    worker_id: Type.String({ description: "Target worker id." }),
    reason: Type.String({
      description:
        "Why you're terminating. Shown in logs and the canvas event " +
        "trail; helps the operator understand your reasoning.",
    }),
  }),
  async execute(_id, { worker_id, reason }) {
    await karkhanaCall<{ ok: boolean }>("/terminate_worker", {
      worker_id,
      reason,
    });
    return {
      content: [
        {
          type: "text" as const,
          text: `terminated ${worker_id}: ${reason}`,
        },
      ],
      details: { worker_id, reason },
    };
  },
});

// wait_for_workers is DEPRECATED in active-driver mode. The
// backend handler returns a snapshot immediately (no blocking)
// plus a `notice` field telling you to use ticks. We keep the
// tool registered ONLY so old cached extension bundles don't
// hard-error; in normal use, do NOT call this — the supervisor
// preamble teaches the tick model.
const waitForWorkersTool = defineTool({
  name: "wait_for_workers",
  label: "Wait For Workers (deprecated)",
  description:
    "DEPRECATED. Do not call. Karkhana auto-ticks you on every " +
    "material worker event (note write, terminate, heartbeat) — " +
    "just end your turn after spawning, you'll be woken with " +
    "full context. This tool now returns an immediate snapshot " +
    "plus a deprecation notice.",
  parameters: Type.Object({
    worker_ids: Type.Array(Type.String()),
  }),
  async execute(_id, { worker_ids }) {
    const r = await karkhanaCall<WaitForWorkersResult & { notice?: string }>(
      "/wait_for_workers",
      { worker_ids },
    );
    return {
      content: [
        {
          type: "text" as const,
          text:
            (r.notice ? r.notice + "\n\n" : "") +
            `Snapshot: ${r.workers.length} worker(s)`,
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

// --- finish (now produces an artifact) ---

const finishTool = defineTool({
  name: "finish",
  label: "Finish (produce artifact)",
  description:
    "Mark the current task complete and produce the mission's " +
    "final deliverable as a typed artifact. The artifact appears " +
    "as its own tile on the canvas, addressable by ID, and the " +
    "operator can reference it in follow-up prompts (e.g. " +
    "\"extend section 3 of the report\"). The driver enters idle " +
    "state after finish — does NOT exit; follow-up messages pick " +
    "up with the full conversation + artifact still in context.",
  parameters: Type.Object({
    result: Type.String({
      description:
        "The final report content as markdown. Use proper markdown " +
        "structure: # headings, ## subheadings, bullets, tables, " +
        "links to sources. This is the operator's deliverable; " +
        "format it for reading, not just summarizing.",
    }),
    title: Type.Optional(
      Type.String({
        description:
          "Short title for the artifact tile (≤ 80 chars). " +
          "Defaults to a truncation of the mission goal.",
      }),
    ),
  }),
  async execute(_id, { result, title }) {
    const r = await karkhanaCall<{ artifact_id: string }>("/finish", {
      result,
      title,
    });
    return {
      content: [
        {
          type: "text" as const,
          text:
            `(finished — artifact ${r.artifact_id} produced. ` +
            `Operator can follow up.)`,
        },
      ],
      details: { artifact_id: r.artifact_id, title },
    };
  },
});

// --- blackboard (driver-side) ---
//
// Drivers can read AND write the mission's shared scratchpad.
// Workers can only write (their writes are intercepted from the
// pi-rpc tool_execution_start stream by Karkhana's host
// process; see extensions/computer-use/index.ts).
//
// Driver uses these to:
//   - read worker contributions before synthesis (read_notes)
//   - see what's been recorded at a glance (list_notes)
//   - record its own planning notes for future turns (write_note)

const writeNoteTool = defineTool({
  name: "write_note",
  label: "Write Note (blackboard)",
  description:
    "Append an entry to the mission blackboard. Useful for " +
    "recording your own planning notes, intermediate synthesis, " +
    "or operator answers. Append-only — multiple notes under the " +
    "same key accumulate, none overwrites others.",
  parameters: Type.Object({
    key: Type.String({
      description: "Topic label, snake_case (e.g. 'plan', 'critique_v1').",
    }),
    content: Type.String({ description: "The note content." }),
    summary: Type.Optional(Type.String()),
  }),
  async execute(_id, { key, content, summary }) {
    const r = await karkhanaCall<{ note_id: number }>("/notes/write", {
      key,
      content,
      summary,
    });
    return {
      content: [
        {
          type: "text" as const,
          text: `wrote note: ${key} (note_id=${r.note_id})`,
        },
      ],
      details: { key, note_id: r.note_id },
    };
  },
});

const readNotesTool = defineTool({
  name: "read_notes",
  label: "Read Notes (blackboard)",
  description:
    "Return all blackboard entries under a given key, in time " +
    "order. Use this during synthesis to gather worker " +
    "contributions on a topic. If no key is provided, returns " +
    "ALL notes in the mission (use list_notes first to know " +
    "what keys exist).",
  parameters: Type.Object({
    key: Type.Optional(
      Type.String({
        description:
          "Topic label. Omit to read every note in the mission.",
      }),
    ),
  }),
  async execute(_id, { key }) {
    const r = await karkhanaCall<{ notes: any[] }>("/notes/read", {
      key: key ?? "",
    });
    const summary =
      r.notes.length === 0
        ? "no notes under this key"
        : `${r.notes.length} note(s):\n` +
          r.notes
            .map(
              (n: any) =>
                `  [${n.id}] ${n.agent_id || "?"}: ${
                  (n.summary as string) ?? (n.content as string).slice(0, 80)
                }`,
            )
            .join("\n");
    return {
      content: [{ type: "text" as const, text: summary }],
      details: r,
    };
  },
});

const listNotesTool = defineTool({
  name: "list_notes",
  label: "List Notes (blackboard manifest)",
  description:
    "Return the manifest of blackboard keys for this mission — " +
    "each key with its entry count and the latest contributor's " +
    "summary. Cheap; use this to decide what to read in detail " +
    "via read_notes.",
  parameters: Type.Object({}),
  async execute() {
    const r = await karkhanaCall<{ manifest: any[] }>("/notes/list", {});
    const lines =
      r.manifest.length === 0
        ? ["(blackboard empty)"]
        : r.manifest.map(
            (e: any) =>
              `  ${e.key} (×${e.count}, latest by ${e.latest_agent || "?"}): ${
                e.latest_summary || ""
              }`,
          );
    return {
      content: [
        {
          type: "text" as const,
          text:
            `blackboard manifest:\n${lines.join("\n")}`,
        },
      ],
      details: r,
    };
  },
});

// --- registration ---

export default function (pi: ExtensionAPI) {
  pi.registerTool(spawnWorkerTool);
  pi.registerTool(spawnWorkersTool);
  pi.registerTool(steerWorkerTool);
  pi.registerTool(terminateWorkerTool);
  pi.registerTool(waitForWorkersTool);
  pi.registerTool(askOperatorTool);
  pi.registerTool(reportProgressTool);
  pi.registerTool(finishTool);
  pi.registerTool(writeNoteTool);
  pi.registerTool(readNotesTool);
  pi.registerTool(listNotesTool);
}
