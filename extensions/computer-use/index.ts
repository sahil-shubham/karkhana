/**
 * Karkhana computer-use extension for pi-coding-agent.
 *
 * Adds GUI tools so a worker running inside a Karkhana microVM
 * can drive its X11 desktop directly: screenshot, click, type,
 * scroll, drag. Every action tool returns a fresh screenshot
 * in its result, so the agent has a vision-driven feedback loop
 * without needing a separate `screenshot` call after each action.
 *
 * Why pi extension and not MCP:
 * - This code runs in the SAME process as pi inside the sandbox.
 *   No IPC, no JSON-RPC framing, no separate server lifecycle.
 * - Pi's tool surface natively supports ImageContent return —
 *   the screenshot lands directly in the next LLM turn's context
 *   alongside the text result.
 * - We control the image, so dependencies (xdotool, scrot) are
 *   pre-installed at bake time; nothing to discover at runtime.
 *
 * Runtime requirements (installed by scripts/bake-image.sh):
 *   - xdotool   — mouse/keyboard automation
 *   - scrot     — screen capture
 *   - DISPLAY   — set to :99 by /etc/profile.d/bhatti-display.sh
 *
 * Loaded by adding `--extension /usr/local/share/karkhana/extensions/computer-use/index.ts`
 * to the pi-rpc spawn args (see pkg/agent/driver/driver.go).
 */

import { spawn } from "node:child_process";
import { readFileSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Type } from "typebox";
import { defineTool, type ExtensionAPI } from "@mariozechner/pi-coding-agent";

// --- shell helpers ---

interface ShResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

function sh(argv: string[], timeoutMs = 5000): Promise<ShResult> {
  return new Promise((resolve) => {
    const p = spawn(argv[0], argv.slice(1), { stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    let err = "";
    let timer: NodeJS.Timeout | null = null;
    if (timeoutMs > 0) {
      timer = setTimeout(() => p.kill("SIGKILL"), timeoutMs);
    }
    p.stdout.on("data", (b) => (out += b.toString()));
    p.stderr.on("data", (b) => (err += b.toString()));
    p.on("close", (code) => {
      if (timer) clearTimeout(timer);
      resolve({ stdout: out, stderr: err, exitCode: code ?? -1 });
    });
    p.on("error", (e) => {
      if (timer) clearTimeout(timer);
      resolve({ stdout: out, stderr: String(e), exitCode: -1 });
    });
  });
}

// --- screenshot helper ---
//
// Uses scrot because it's tiny, X11-native, no Chrome/Electron
// runtime overhead, and respects the active DISPLAY. Saves to
// /tmp, base64-encodes, deletes the temp file. Each screenshot
// adds a few hundred KB to the LLM context — fine for a worker
// turn budget but worth keeping in mind if turns get long.

async function captureScreenshot(): Promise<{
  data: string;
  mimeType: "image/png";
  bytes: number;
}> {
  const path = join(tmpdir(), `kk-shot-${process.pid}-${Date.now()}.png`);
  // -o overwrite, -z silent, -F path. Wait 30ms for X to settle
  // after a previous action so we don't catch mid-redraw frames.
  await new Promise((r) => setTimeout(r, 30));
  const r = await sh(["scrot", "-o", "-z", "-F", path], 4000);
  if (r.exitCode !== 0) {
    throw new Error(
      `scrot failed (exit=${r.exitCode}): ${r.stderr.trim() || r.stdout.trim()}`,
    );
  }
  let buf: Buffer;
  try {
    buf = readFileSync(path);
  } catch (e) {
    throw new Error(`scrot did not produce ${path}: ${String(e)}`);
  }
  try {
    unlinkSync(path);
  } catch {
    // best-effort cleanup
  }
  return {
    data: buf.toString("base64"),
    mimeType: "image/png",
    bytes: buf.length,
  };
}

// All action tools return text + screenshot so the agent gets a
// "what does the screen look like now" feedback loop for free.
async function actionResult(textSummary: string, details: Record<string, unknown>) {
  const shot = await captureScreenshot();
  return {
    content: [
      { type: "text" as const, text: textSummary },
      { type: "image" as const, data: shot.data, mimeType: shot.mimeType },
    ],
    details: { ...details, screenshot_bytes: shot.bytes },
  };
}

// --- xdotool helpers ---

async function xdo(args: string[]): Promise<void> {
  const r = await sh(["xdotool", ...args], 4000);
  if (r.exitCode !== 0) {
    throw new Error(
      `xdotool ${args.join(" ")} failed (exit=${r.exitCode}): ${
        r.stderr.trim() || r.stdout.trim()
      }`,
    );
  }
}

// xdoScript runs many xdotool subcommands in a single subprocess
// invocation by piping them on stdin. xdotool reads from stdin
// when the first arg is `-`. One process, many commands — way
// cheaper than spawning xdotool 20 times for a smooth move.
function xdoScript(commands: string[], timeoutMs = 5000): Promise<ShResult> {
  return new Promise((resolve) => {
    const p = spawn("xdotool", ["-"], { stdio: ["pipe", "pipe", "pipe"] });
    let out = "";
    let err = "";
    let timer: NodeJS.Timeout | null = null;
    if (timeoutMs > 0) {
      timer = setTimeout(() => p.kill("SIGKILL"), timeoutMs);
    }
    p.stdout.on("data", (b) => (out += b.toString()));
    p.stderr.on("data", (b) => (err += b.toString()));
    p.on("close", (code) => {
      if (timer) clearTimeout(timer);
      resolve({ stdout: out, stderr: err, exitCode: code ?? -1 });
    });
    p.on("error", (e) => {
      if (timer) clearTimeout(timer);
      resolve({ stdout: out, stderr: String(e), exitCode: -1 });
    });
    p.stdin.write(commands.join("\n") + "\n");
    p.stdin.end();
  });
}

async function getDisplaySize(): Promise<{ width: number; height: number }> {
  const r = await sh(["xdotool", "getdisplaygeometry"], 2000);
  if (r.exitCode !== 0) {
    return { width: 1280, height: 720 }; // KasmVNC default
  }
  const [w, h] = r.stdout.trim().split(/\s+/).map(Number);
  return { width: w || 1280, height: h || 720 };
}

async function getCursorPos(): Promise<{ x: number; y: number }> {
  const r = await sh(["xdotool", "getmouselocation"], 2000);
  if (r.exitCode !== 0) return { x: 0, y: 0 };
  // Output: "x:123 y:456 screen:0 window:12345"
  const m = r.stdout.match(/x:(\d+)\s+y:(\d+)/);
  if (!m) return { x: 0, y: 0 };
  return { x: Number(m[1]), y: Number(m[2]) };
}

// --- human-like motion ---
//
// xdotool's `mousemove X Y` is instantaneous — the cursor
// teleports to the target. For headful workflows this is
// jarring (operator can't follow the agent's intent) AND it
// trips bot-detection on sites that check for natural mouse
// movement. smoothMove fixes both: read the current position,
// interpolate ~16-20 waypoints with ease-out cubic, batch the
// moves through one xdotool stdin invocation.
//
// Default duration ~200ms feels human without making the agent
// feel sluggish. Configurable per-call.
async function smoothMove(
  toX: number,
  toY: number,
  durationMs = 200,
): Promise<void> {
  const cur = await getCursorPos();
  const dx = toX - cur.x;
  const dy = toY - cur.y;
  const dist = Math.hypot(dx, dy);

  // Already there (within 1px) — just snap and return.
  if (dist < 1) {
    await xdo(["mousemove", String(toX), String(toY)]);
    return;
  }

  // Step count: ~60fps cadence, but at least 8 steps and at
  // most 30 (very short moves get fewer; very long moves cap
  // out so we don't overshoot the duration budget).
  const steps = Math.min(
    30,
    Math.max(8, Math.round(durationMs / 16)),
  );
  const stepMs = Math.max(8, Math.floor(durationMs / steps));

  // Build the script: alternating mousemove + sleep, ending
  // with one final mousemove to the exact target (rounding
  // drift safety).
  const lines: string[] = [];
  for (let i = 1; i <= steps; i++) {
    const t = i / steps;
    // Ease-out cubic: starts fast, decelerates near target.
    // Feels like a human reaching for a button.
    const e = 1 - Math.pow(1 - t, 3);
    // Add small jitter (sub-pixel noise) so the path isn't a
    // perfectly straight line — helps with bot detection.
    const jx = (Math.random() - 0.5) * 1.4;
    const jy = (Math.random() - 0.5) * 1.4;
    const x = Math.round(cur.x + dx * e + jx);
    const y = Math.round(cur.y + dy * e + jy);
    lines.push(`mousemove ${x} ${y}`);
    if (i < steps) {
      lines.push(`sleep ${(stepMs / 1000).toFixed(3)}`);
    }
  }
  // Final exact position (no jitter on the landing pixel).
  lines.push(`mousemove ${toX} ${toY}`);

  const r = await xdoScript(lines, durationMs + 2000);
  if (r.exitCode !== 0) {
    throw new Error(
      `smoothMove failed (exit=${r.exitCode}): ${r.stderr.trim()}`,
    );
  }
}

// Brief hover before clicking — humans rarely click the instant
// the cursor lands. 30-90ms looks natural.
async function hoverBeat() {
  const ms = 30 + Math.floor(Math.random() * 60);
  await new Promise((r) => setTimeout(r, ms));
}

// --- tools ---

const screenshotTool = defineTool({
  name: "screenshot",
  label: "Screenshot",
  description:
    "Capture the current desktop and return it as a PNG image. " +
    "Useful as a checkpoint or whenever you need to see what's on " +
    "screen without performing an action. Action tools (click, type, " +
    "key, scroll, etc.) automatically return a screenshot too — only " +
    "call this when you specifically want to look without acting.",
  parameters: Type.Object({}),
  async execute() {
    const shot = await captureScreenshot();
    const size = await getDisplaySize();
    return {
      content: [
        {
          type: "text" as const,
          text: `desktop ${size.width}x${size.height}, png ${shot.bytes}B`,
        },
        { type: "image" as const, data: shot.data, mimeType: shot.mimeType },
      ],
      details: {
        width: size.width,
        height: size.height,
        screenshot_bytes: shot.bytes,
      },
    };
  },
});

const leftClickTool = defineTool({
  name: "left_click",
  label: "Left Click",
  description:
    "Move the mouse smoothly to (x, y) and left-click. Coordinates " +
    "are in screen pixels with (0, 0) at the top-left. The cursor " +
    "travels along an eased path (~200ms by default) so the " +
    "operator can see where you're heading; bot-detection-resistant " +
    "sites also accept the input. Returns a screenshot.",
  parameters: Type.Object({
    x: Type.Number({ description: "X pixel coordinate (0 = left edge)" }),
    y: Type.Number({ description: "Y pixel coordinate (0 = top edge)" }),
    duration_ms: Type.Optional(
      Type.Number({
        description:
          "Cursor travel time in ms. Default 200. Set to 0 for " +
          "instant teleport when you genuinely don't care about " +
          "visible motion (e.g. clicking your own internal buttons " +
          "with no bot detection).",
      }),
    ),
  }),
  async execute(_id, { x, y, duration_ms }) {
    await smoothMove(x, y, duration_ms ?? 200);
    await hoverBeat();
    await xdo(["click", "1"]);
    return actionResult(`left-clicked at (${x}, ${y})`, { x, y, button: 1 });
  },
});

const rightClickTool = defineTool({
  name: "right_click",
  label: "Right Click",
  description:
    "Move the mouse smoothly to (x, y) and right-click (button 3). " +
    "Typically opens a context menu. Returns a screenshot.",
  parameters: Type.Object({
    x: Type.Number({ description: "X pixel coordinate" }),
    y: Type.Number({ description: "Y pixel coordinate" }),
    duration_ms: Type.Optional(Type.Number()),
  }),
  async execute(_id, { x, y, duration_ms }) {
    await smoothMove(x, y, duration_ms ?? 200);
    await hoverBeat();
    await xdo(["click", "3"]);
    return actionResult(`right-clicked at (${x}, ${y})`, { x, y, button: 3 });
  },
});

const middleClickTool = defineTool({
  name: "middle_click",
  label: "Middle Click",
  description:
    "Move the mouse smoothly to (x, y) and middle-click (button 2). " +
    "Returns a screenshot.",
  parameters: Type.Object({
    x: Type.Number({ description: "X pixel coordinate" }),
    y: Type.Number({ description: "Y pixel coordinate" }),
    duration_ms: Type.Optional(Type.Number()),
  }),
  async execute(_id, { x, y, duration_ms }) {
    await smoothMove(x, y, duration_ms ?? 200);
    await hoverBeat();
    await xdo(["click", "2"]);
    return actionResult(`middle-clicked at (${x}, ${y})`, { x, y, button: 2 });
  },
});

const doubleClickTool = defineTool({
  name: "double_click",
  label: "Double Click",
  description:
    "Move the mouse smoothly to (x, y) and double-click (left). " +
    "Returns a screenshot.",
  parameters: Type.Object({
    x: Type.Number({ description: "X pixel coordinate" }),
    y: Type.Number({ description: "Y pixel coordinate" }),
    duration_ms: Type.Optional(Type.Number()),
  }),
  async execute(_id, { x, y, duration_ms }) {
    await smoothMove(x, y, duration_ms ?? 200);
    await hoverBeat();
    await xdo(["click", "--repeat", "2", "--delay", "80", "1"]);
    return actionResult(`double-clicked at (${x}, ${y})`, { x, y });
  },
});

const mouseMoveTool = defineTool({
  name: "mouse_move",
  label: "Mouse Move",
  description:
    "Move the mouse smoothly to (x, y) WITHOUT clicking. Useful " +
    "for hovering to reveal tooltips or hover-states. Returns a " +
    "screenshot of the resulting hover state.",
  parameters: Type.Object({
    x: Type.Number({ description: "X pixel coordinate" }),
    y: Type.Number({ description: "Y pixel coordinate" }),
    duration_ms: Type.Optional(Type.Number()),
  }),
  async execute(_id, { x, y, duration_ms }) {
    await smoothMove(x, y, duration_ms ?? 200);
    return actionResult(`moved cursor to (${x}, ${y})`, { x, y });
  },
});

const leftClickDragTool = defineTool({
  name: "left_click_drag",
  label: "Drag",
  description:
    "Smoothly move to (start_x, start_y), press the left mouse, " +
    "smoothly drag to (end_x, end_y), then release. Useful for " +
    "selecting text, moving windows, or drawing. Returns a " +
    "screenshot.",
  parameters: Type.Object({
    start_x: Type.Number(),
    start_y: Type.Number(),
    end_x: Type.Number(),
    end_y: Type.Number(),
    duration_ms: Type.Optional(
      Type.Number({
        description:
          "Drag duration in ms (the held-down move portion). " +
          "Default 350 — drags read more naturally a bit slower " +
          "than clicks because they convey 'I'm pulling this'.",
      }),
    ),
  }),
  async execute(_id, { start_x, start_y, end_x, end_y, duration_ms }) {
    // 1. Move smoothly to the start, no click yet.
    await smoothMove(start_x, start_y, 200);
    await hoverBeat();
    // 2. Press and hold the left button.
    await xdo(["mousedown", "1"]);
    await new Promise((r) => setTimeout(r, 60));
    // 3. Smoothly drag to the end while holding.
    await smoothMove(end_x, end_y, duration_ms ?? 350);
    await new Promise((r) => setTimeout(r, 60));
    // 4. Release.
    await xdo(["mouseup", "1"]);
    return actionResult(
      `dragged from (${start_x}, ${start_y}) to (${end_x}, ${end_y})`,
      { start_x, start_y, end_x, end_y },
    );
  },
});

const typeTool = defineTool({
  name: "type",
  label: "Type",
  description:
    "Type text at the current cursor focus. Inserts characters " +
    "literally — does NOT interpret special key names like " +
    "'Return' or 'Escape' (use the `key` tool for those). " +
    "Returns a screenshot.",
  parameters: Type.Object({
    text: Type.String({ description: "Text to type, as-is" }),
    delay_ms: Type.Optional(
      Type.Number({
        description:
          "Per-character delay in milliseconds (default 25). " +
          "Increase if the target app drops keystrokes.",
      }),
    ),
  }),
  async execute(_id, { text, delay_ms }) {
    const delay = delay_ms ?? 40;
    // Type with light per-character jitter so the input doesn't
    // arrive at perfectly uniform intervals — helps with bot
    // detection on sites that monitor key cadence. We do this
    // by typing each char in its own xdotool call with a
    // randomized --delay between them. Slight overhead vs one
    // bulk type, negligible for typical input sizes.
    if (text.length === 0) {
      return actionResult("typed 0 chars", { length: 0, delay_ms: delay });
    }
    if (text.length > 200) {
      // For long pastes, just bulk-type — jitter doesn't matter
      // when you're entering an essay.
      await xdo(["type", "--delay", String(delay), "--", text]);
    } else {
      // xdoScript handles the per-char loop in one xdotool
      // process via stdin, so the subprocess overhead is paid
      // once not per character.
      const lines: string[] = [];
      for (let i = 0; i < text.length; i++) {
        const ch = text[i];
        // Jitter: roughly delay ± 50%, pinned positive.
        const jitter = Math.max(
          5,
          Math.round(delay + (Math.random() - 0.3) * delay),
        );
        // Escape backslash + double-quote for the type "..." form.
        const escaped = ch.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
        lines.push(`type --delay 0 -- "${escaped}"`);
        if (i < text.length - 1) {
          lines.push(`sleep ${(jitter / 1000).toFixed(3)}`);
        }
      }
      const r = await xdoScript(lines, text.length * 200 + 2000);
      if (r.exitCode !== 0) {
        // Fall back to bulk type if the script invocation failed.
        await xdo(["type", "--delay", String(delay), "--", text]);
      }
    }
    return actionResult(`typed ${text.length} chars`, {
      length: text.length,
      delay_ms: delay,
    });
  },
});

const keyTool = defineTool({
  name: "key",
  label: "Key",
  description:
    "Press a key or key combination using xdotool's key syntax. " +
    "Examples: 'Return', 'Escape', 'Tab', 'BackSpace', 'space', " +
    "'Up', 'Down', 'ctrl+l' (focus URL bar), 'ctrl+t' (new tab), " +
    "'ctrl+shift+t', 'alt+F4', 'super' (open app launcher). " +
    "Use this for any non-character input. Returns a screenshot.",
  parameters: Type.Object({
    combo: Type.String({
      description:
        "xdotool key syntax: single key like 'Return' or " +
        "modifier combo like 'ctrl+shift+t'.",
    }),
  }),
  async execute(_id, { combo }) {
    await xdo(["key", "--", combo]);
    return actionResult(`pressed ${combo}`, { combo });
  },
});

const scrollTool = defineTool({
  name: "scroll",
  label: "Scroll",
  description:
    "Scroll the area under the mouse cursor. Direction is 'up', " +
    "'down', 'left', or 'right'; amount is the number of scroll " +
    "ticks (default 3, ~one viewport-third per ~3 ticks). " +
    "Returns a screenshot.",
  parameters: Type.Object({
    direction: Type.Union([
      Type.Literal("up"),
      Type.Literal("down"),
      Type.Literal("left"),
      Type.Literal("right"),
    ]),
    amount: Type.Optional(Type.Number({ description: "Scroll ticks (default 3)" })),
  }),
  async execute(_id, { direction, amount }) {
    const ticks = amount ?? 3;
    // xdotool button mapping: 4=up, 5=down, 6=left, 7=right
    const button = { up: "4", down: "5", left: "6", right: "7" }[direction];
    await xdo(["click", "--repeat", String(ticks), "--delay", "30", button]);
    return actionResult(`scrolled ${direction} ${ticks} ticks`, {
      direction,
      amount: ticks,
    });
  },
});

const cursorPositionTool = defineTool({
  name: "cursor_position",
  label: "Cursor Position",
  description:
    "Get the current mouse cursor position in screen pixels. " +
    "Read-only, no action taken, no screenshot returned.",
  parameters: Type.Object({}),
  async execute() {
    const r = await sh(["xdotool", "getmouselocation"], 2000);
    if (r.exitCode !== 0) {
      throw new Error(`xdotool getmouselocation failed: ${r.stderr.trim()}`);
    }
    // Output is like "x:123 y:456 screen:0 window:12345"
    const m = r.stdout.match(/x:(\d+)\s+y:(\d+)/);
    const x = m ? Number(m[1]) : 0;
    const y = m ? Number(m[2]) : 0;
    return {
      content: [{ type: "text" as const, text: `cursor at (${x}, ${y})` }],
      details: { x, y },
    };
  },
});

const waitTool = defineTool({
  name: "wait",
  label: "Wait",
  description:
    "Sleep for a number of seconds, then return a screenshot. " +
    "Use this to let pages load, animations finish, or apps " +
    "start. Capped at 10 seconds per call to keep turns " +
    "responsive — call multiple times if you need longer.",
  parameters: Type.Object({
    seconds: Type.Number({ description: "Seconds to wait (max 10)" }),
  }),
  async execute(_id, { seconds }) {
    const s = Math.max(0, Math.min(10, seconds));
    await new Promise((r) => setTimeout(r, s * 1000));
    return actionResult(`waited ${s}s`, { seconds: s });
  },
});

// --- registration ---

export default function (pi: ExtensionAPI) {
  pi.registerTool(screenshotTool);
  pi.registerTool(leftClickTool);
  pi.registerTool(rightClickTool);
  pi.registerTool(middleClickTool);
  pi.registerTool(doubleClickTool);
  pi.registerTool(mouseMoveTool);
  pi.registerTool(leftClickDragTool);
  pi.registerTool(typeTool);
  pi.registerTool(keyTool);
  pi.registerTool(scrollTool);
  pi.registerTool(cursorPositionTool);
  pi.registerTool(waitTool);
}
