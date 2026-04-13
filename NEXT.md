# Karkhana — Current State and Next Steps

Last updated: 2026-04-13

---

## What Works Today

- Orchestrator polls Linear, dispatches agents to bhatti sandboxes
- Pi (coding agent) runs inside sandboxes via setsid + file-based output polling
- Single-mode workflow: agent reads ticket, does the work, posts a Linear comment, moves to In Review
- Agent creates branches, pushes, opens PRs
- Sandbox reuse across retries (same issue = same sandbox)
- `keep_hot: true` keeps agent sandboxes alive during work
- `karkhana-pi` bhatti image with Pi + Anthropic OAuth auth
- Orchestrator runs on bhatti (`karkhana-orchestrator` sandbox, keep_hot)
- Dashboard at https://karkhana.bhatti.sh
- Orchestrator hot-reloads WORKFLOW.md on file change
- Continuation retries handle transient failures
- Idempotent actions: checks for existing branches, PRs, comments before creating
- Supports both Pi and Claude Code via agent detection in cli.ex

## What's Broken

### 1. Identity: agent acts as you

Agent uses your Linear API key and GitHub token. All comments and PRs
appear as "Sahil Shubham." The agent cannot distinguish its own comments
from yours, causing duplicate comments on retry.

**Fix: dedicated service accounts.**

| Service | What to create | Effort |
|---------|---------------|--------|
| Linear | Invite `karkhana@...` as workspace member, generate API key | 5 min |
| GitHub | Create `karkhana-bot` account, add as repo collaborator, generate PAT | 10 min |
| Git | Already done — `after_create` hook sets user.name to karkhana[bot] |  |

Code change: add `KARKHANA_LINEAR_API_KEY` and `KARKHANA_GH_TOKEN` to .env.
Pass these into sandboxes instead of your personal tokens. The orchestrator
continues using your Linear key for reading issues (or use the karkhana key
for everything).

Once the agent has its own Linear identity:
- Comments show as "Karkhana" — visually distinct from yours
- Idempotency check becomes: "is there a comment by Karkhana on this issue?"
- You can assign issues to Karkhana explicitly
- Audit trail is clean

### 2. No retry cap

The orchestrator retries failed issues forever. ME-24 hit 102 retries.
This hammers bhatti, the LLM API, and token refresh endpoints.

**Fix:** Cap retries at 5. After 5 consecutive failures on the same issue:
- Post a diagnostic comment on Linear with the error details
- Move the issue to Backlog (or a "Blocked" state)
- Release the claim

This is a change to `orchestrator.ex` — add a max_retries check in
`handle_retry_issue_lookup` or `schedule_issue_retry`.

### 3. No structured logs

The TUI dashboard swallows all Logger output. When things fail, we can't
see why without SSH-ing into the sandbox and reading files manually.

**Fix:** Add a file logger backend alongside the TUI. Write to
`/tmp/karkhana-structured.log` with JSON lines. The `config.exs` or
application startup can configure `Logger` to write to both console
and file.

### 4. OAuth token expiry (Claude Code specific)

Claude Code's baked OAuth tokens expire after ~24h. The `karkhana-claude`
image goes stale. We switched to Pi which handles token refresh internally,
but if we ever want Claude Code back, we need to either:
- Use an Anthropic API key (permanent fix)
- Build a token refresh script that runs before each agent launch
- Re-login and re-save the image periodically

Not blocking since we're using Pi now.

### 5. Bhatti exec limitations

Long-running commands through Cloudflare tunnel timeout at ~100s. We work
around this with setsid + file polling, which adds 3s latency per poll
and loses real-time streaming.

**Status:** bhatti shipped `detach: true` on exec (commit 878dfc9) and
idempotent sandbox create (commit 2d4fc9e). The server is deployed but
the lohar binary inside sandbox images is old and doesn't support the
new protocol yet. Once images are rebuilt with the new lohar, we can
replace the setsid + file polling hack with clean detached exec.

### 6. Agent can't publish its own ports

The WORKFLOW.md tells the agent to start a dev server on port 4321, but
the agent can't call `bhatti publish` from inside the sandbox. The bhatti
API is reachable (through Cloudflare), so the agent could call
`POST /sandboxes/:id/publish` with the right sandbox ID and API key.

**Fix:** Pass `BHATTI_SANDBOX_ID` as an env var into the sandbox during
creation. The agent then calls the bhatti publish API directly. The
WORKFLOW.md includes the curl command.

### 7. Agent doesn't resume conversations

Each turn is `pi -p <prompt> --no-session` — a fresh invocation with no
memory of prior turns. When the issue moves to In Progress with feedback,
the agent re-reads the codebase and comments from scratch instead of
continuing from where it left off.

Pi supports `--session <path>` and `--continue` for session persistence.
We should use these for continuation turns.

---

## Pi Integration: What We Use vs What's Available

### Currently using
- `pi -p <prompt> --mode json --no-session` — single-shot print mode with JSON events
- Each turn is a fresh invocation (no session continuity between turns)

### Not using but should
- `--continue` / `--session <path>` — session persistence across turns.
  Pi can resume from where it left off, keeping full conversation history.
  Currently we use `--no-session` and each turn starts fresh, losing all
  context from previous turns on the same issue. This means on retry or
  In Progress re-dispatch, the agent has no memory of what it did before
  except what's in the Linear comments and git history.

  **Fix:** Use `--session-dir /tmp/karkhana-sessions` and `--continue`
  on continuation turns. Store the session ID in the poll state and pass
  `--session <path>` on subsequent dispatches. This gives the agent full
  context of prior turns.

- `--append-system-prompt` — we could pass the WORKFLOW.md prompt via
  this flag instead of baking it into the -p prompt. Cleaner separation
  of system instructions vs task-specific prompt.

- `--tools` — we could restrict tools for research-only tasks (no bash,
  no write) to prevent unintended side effects.

- `--thinking <level>` — control reasoning depth. Use `high` for complex
  implementation, `low` for simple research tasks.

- Extensions (`-e <path>`) — Pi supports custom extensions. Could add a
  Linear extension that gives the agent native Linear API access without
  curl commands in the prompt.

- Skills — Pi loads SKILL.md files. Could create a `karkhana` skill that
  teaches the agent the git workflow, Linear API patterns, and review
  handoff protocol instead of putting all of that in WORKFLOW.md.

### Priority integration
1. Session continuity (`--session` + `--continue`) — highest impact,
   gives the agent memory across turns
2. System prompt separation (`--append-system-prompt`) — cleaner architecture
3. Thinking level control — easy win for quality

---

## Self-Improvement Architecture

### The goal

You file a Linear ticket about karkhana itself (e.g., "Add build verification
to the implementation prompt"). Karkhana picks it up, edits WORKFLOW.md or
Elixir code, opens a PR. You merge. The production orchestrator pulls the
change and hot-reloads.

### How it works

Two Linear projects, two orchestrator instances:

| | Bhatti project | Karkhana project |
|---|---|---|
| Tickets about | bhatti.sh website | Karkhana itself |
| Repo | sahil-shubham/bhatti.sh | sahil-shubham/karkhana |
| Sandbox image | karkhana-pi | karkhana-pi |
| WORKFLOW.md | Agent behavior for website work | Agent behavior for self-improvement |
| Orchestrator | Instance 1 (existing) | Instance 2 (new) |

Both instances run on bhatti. Instance 1 is already deployed. Instance 2
is identical but points at a different project_slug and clones the karkhana
repo instead of bhatti.sh.

### Deploy loop after self-improvement

When a karkhana WORKFLOW.md PR gets merged:

1. The karkhana orchestrator instance has a `before_run` hook that does
   `git pull` on the karkhana repo before each dispatch.
2. The pull updates WORKFLOW.md on disk.
3. The file watcher detects the change and hot-reloads the config + prompt.
4. The next dispatch on the bhatti project uses the improved prompt.

For Elixir code changes (not just WORKFLOW.md):
1. The `before_run` hook also runs `mix compile` after pulling.
2. The BEAM's hot code reloading picks up the new modules.
3. Or: the orchestrator restarts itself after detecting code changes
   (a simple `System.stop(0)` — the sandbox's process supervisor restarts it).

### What this requires

1. Create "Karkhana" project in Linear
2. Write a WORKFLOW.md for the karkhana project (self-referential — tells
   the agent how to edit karkhana's own code and config)
3. Deploy a second orchestrator instance
4. Add `git pull && mix compile` to the `before_run` hook of both instances

### The self-referential prompt

The karkhana project's WORKFLOW.md tells the agent:

```
You are improving the karkhana orchestrator. The codebase is Elixir at /workspace.
WORKFLOW.md in elixir/ defines how agents behave on other projects.
When editing WORKFLOW.md, you are changing how agents work on future tickets.
Test your changes by verifying mix compile passes.
```

This is where the "distinguished engineer" framing matters most. The agent
editing its own prompt needs good judgment about what instructions are
effective and what will cause problems.

---

## Bhatti Changes — Shipped

These are already in bhatti main and deployed to the server:

- **Detached exec** (878dfc9) — `POST /exec {"detach":true}` returns
  immediately with PID. Process runs in its own session with stdout/stderr
  to a file. Requires lohar rebuild in sandbox images to take effect.
- **Idempotent sandbox create** (2d4fc9e) — duplicate name returns the
  existing sandbox (200) instead of 500. Eliminates the TOCTOU race.
- **24h exec timeout cap** (2d4fc9e) — raised from 1h to 24h.

## Bhatti Changes Still Needed

### 1. Rebuild sandbox images with new lohar

The `karkhana-pi` and `karkhana-claude` images have the old lohar binary
that doesn't support detached exec. Need to rebuild the base image with
the new lohar, then re-save the karkhana images on top.

### 2. Publish API accessible from inside sandboxes

The agent needs to call `POST /sandboxes/:id/publish` from inside its
sandbox. The bhatti API is reachable through Cloudflare. Just need to
pass the sandbox ID and API key as env vars.

---

## Implementation Priority

| # | What | Why | Effort |
|---|------|-----|--------|
| 1 | Linear service account | Solves identity + idempotency | 15 min |
| 2 | Retry cap + error reporting to Linear | Stops infinite retry loops | 1 hour |
| 3 | Pi session continuity | Agent remembers across turns | 1 hour |
| 4 | Pass sandbox ID to agent + publish in prompt | Agent publishes its own preview URL | 30 min |
| 5 | Structured file logging | Debuggable without SSH | 30 min |
| 6 | Rebuild images with new lohar | Enables detached exec, removes file-polling | 30 min |
| 7 | Switch to bhatti detached exec | Clean agent launch, real-time output | 1 hour |
| 8 | Second orchestrator for self-improvement | Karkhana edits itself | 2 hours |
| 9 | before_run git pull for auto-deploy | Merged PRs go live automatically | 15 min |
