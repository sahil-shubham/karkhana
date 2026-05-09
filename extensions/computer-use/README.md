# karkhana-computer-use

Pi extension that adds GUI automation tools — `screenshot`,
`left_click`, `right_click`, `middle_click`, `double_click`,
`mouse_move`, `left_click_drag`, `type`, `key`, `scroll`,
`cursor_position`, `wait` — backed by `xdotool` and `scrot` on the
worker's KasmVNC X server.

This is what makes a Karkhana worker a *computer-use* agent rather
than a coding-agent-that-happens-to-have-a-display: the LLM can
see the screen and move the mouse / type / scroll, with a fresh
screenshot returned in every action's tool result so it has a
vision-driven feedback loop.

## How it works

Loaded into pi-coding-agent via:

```
pi --mode rpc \
   --provider openrouter --model anthropic/claude-sonnet-4 \
   --extension /usr/local/share/karkhana/extensions/computer-use/index.ts
```

Karkhana's driver appends the `--extension` flag automatically when
the worker image is one that has the extension baked in (kk-base).
See `pkg/agent/driver/driver.go` and `pkg/config/config.go`.

## Why pi extension and not MCP

Pi's extension API gives us in-process tool registration with native
multi-modal `ImageContent` returns. MCP would mean a separate process
with JSON-RPC framing for what is, here, a `child_process.spawn` of
`xdotool`. We control the image, so the cross-process portability MCP
provides is wasted overhead.

If we ever want to expose these tools to non-pi clients, we add an MCP
adapter then. For now: pi extension, single file, single process.

## Runtime requirements

Installed by `scripts/bake-image.sh` when baking `kk-base`:

| Package | Purpose |
|---------|---------|
| `xdotool` | Mouse + keyboard automation (X11) |
| `scrot` | Screenshot capture (X11, PNG) |
| `wmctrl` | Window listing / management (used by future tools) |
| `typebox` (npm) | Schema for tool parameter validation |

`DISPLAY=:99` is set by the bhatti computer image's
`/etc/profile.d/bhatti-display.sh`.

## Coordinate system

Pixels, `(0, 0)` at top-left. KasmVNC's default geometry is `1280x720`,
which is what every screenshot returns. The `screenshot` tool result
includes the resolution in its `details`, and the `desktop NxM` text
prefix.

## Editing this extension

Pi loads `.ts` directly via [jiti](https://github.com/unjs/jiti) — no
build step. To iterate locally without a full bake cycle, copy
`index.ts` into a running sandbox and restart its pi session.
