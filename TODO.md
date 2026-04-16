# Karkhana — Actionable TODO

Each item has exact changes, risk assessment, and tests. Implementation
order is dependency-driven with the most fragile layer (exec pipeline)
fixed before building on top of it.

Impact tags (following bhatti convention):
- ✅ **TRANSPARENT** — no user-visible change, internal improvement
- 🔄 **ROLLING** — deploys without downtime, affects new runs only
- ⚠️ **BREAKING** — requires restart or redeployment

---

## Phase 0 — Operational Hygiene

**Impact: ⚠️ BREAKING (one-time redeploy)**

Two things that should have been caught before anything else ships.

### 0a. Fix deploy.sh stale image

`deploy.sh` creates the orchestrator from `karkhana-claude` but
WORKFLOW.md uses `karkhana-pi`. A fresh deploy would break.

**Change:**

`deploy.sh` line with `--image karkhana-claude`:
```bash
bhatti create --name "$ORCH_NAME" --image karkhana-pi --cpus 1 --memory 2048 --keep-hot
```

### 0b. Add orchestrator restart loop

The orchestrator runs via `nohup mix run --no-halt &`. If the BEAM
crashes (OOM, GenServer restart intensity exhausted), it stays dead.
Nobody notices until the dashboard goes blank.

**Change:**

`deploy.sh` — replace the `nohup` launch in both `start` and `restart`
cases with a loop wrapper:

```bash
bhatti exec "$ORCH_NAME" -- bash -c '
  pkill -f "mix run" 2>/dev/null || true
  sleep 1
  cat > /home/lohar/karkhana-run.sh << '\''SCRIPT'\''
#!/bin/bash
cd /home/lohar/karkhana/elixir && source .env
while true; do
  echo "$(date -Iseconds) Starting orchestrator..." >> /tmp/karkhana.log
  mix run --no-halt >> /tmp/karkhana.log 2>&1
  EXIT=$?
  echo "$(date -Iseconds) Orchestrator exited ($EXIT), restarting in 5s..." >> /tmp/karkhana.log
  sleep 5
done
SCRIPT
  chmod +x /home/lohar/karkhana-run.sh
  setsid /home/lohar/karkhana-run.sh < /dev/null > /dev/null 2>&1 &
'
```

This gives us crash recovery without adding systemd complexity.

**Files:** `deploy.sh`

---

## Phase 1 — Structured File Logging

**Impact: ✅ TRANSPARENT**

**Problem:** TUI swallows all Logger output. Can't debug without SSH.

**Changes:**

The orchestrator already redirects stdout to `/tmp/karkhana.log` via the
deploy script. The real problem is the TUI dashboard repainting over
the console logger.

Two options, in order of preference:

**Option A (clean):** Disable the TUI when running headless. Check if
`StatusDashboard` has a config flag. If adding
`observability.dashboard_enabled: false` to WORKFLOW.md disables it,
that's the fix — Logger output flows to the file unmangled.

**Option B (if A isn't possible):** Add a file backend alongside console.

`elixir/config/config.exs`:
```elixir
config :logger,
  backends: [:console, {LoggerFileBackend, :karkhana_log}]

config :logger, :karkhana_log,
  path: "/tmp/karkhana-structured.log",
  level: :info,
  format: "$dateT$time [$level] $message\n",
  metadata: [:issue_id, :issue_identifier]
```

This requires adding `logger_file_backend` to `mix.exs` deps. If we
want zero new deps, write a minimal GenEvent-based file backend (~30
lines) or just pipe through `tee`.

**Simplest zero-dep fallback:** The restart loop in Phase 0 already
redirects to `/tmp/karkhana.log`. If we suppress the dashboard
(Option A), that file has clean logs. Investigate Option A first.

**Tests:**
- Verify Logger.info output appears in `/tmp/karkhana-structured.log`
  (or `/tmp/karkhana.log` if Option A)
- Verify log rotation doesn't grow unbounded (add `logrotate` config
  or truncate in the restart loop)

**Files:** `config/config.exs` or `WORKFLOW.md` (dashboard disable flag)

---

## Phase 2 — Retry Cap with Error Classification

**Impact: 🔄 ROLLING — affects future retries only**

**Problem:** Orchestrator retries forever. ME-24 hit 102 retries.

A flat retry cap of 5 treats all errors the same. Need error
classification so permanent errors fail fast and transient errors
get retries.

**Changes:**

`elixir/lib/symphony_elixir/orchestrator.ex`:

Add error classification:

```elixir
@max_retries_permanent 0
@max_retries_logical 3
@max_retries_transient 5
@max_retries_unknown 5

defp classify_error(error) when is_binary(error) do
  cond do
    String.contains?(error, "after_create_hook_failed") -> :permanent
    String.contains?(error, "hook_failed") -> :permanent
    String.contains?(error, "workflow_parse_error") -> :permanent
    String.contains?(error, "template_render_error") -> :permanent
    String.contains?(error, "sandbox creation failed") -> :transient
    String.contains?(error, "retry poll failed") -> :transient
    String.contains?(error, "failed to spawn agent") -> :transient
    String.contains?(error, "no available orchestrator slots") -> :transient
    String.contains?(error, "subprocess_exit") -> :logical
    String.contains?(error, "turn_timeout") -> :logical
    String.contains?(error, "stalled") -> :logical
    String.contains?(error, "agent exited") -> :logical
    true -> :unknown
  end
end

defp classify_error(_), do: :unknown

defp max_retries_for_class(:permanent), do: @max_retries_permanent
defp max_retries_for_class(:logical), do: @max_retries_logical
defp max_retries_for_class(:transient), do: @max_retries_transient
defp max_retries_for_class(_), do: @max_retries_unknown
```

In `schedule_issue_retry`, before scheduling:

```elixir
error_class = classify_error(to_string(metadata[:error] || ""))
max_retries = max_retries_for_class(error_class)

if next_attempt > max_retries and metadata[:delay_type] != :continuation do
  Logger.error(
    "Retry cap reached for issue_id=#{issue_id} " <>
    "issue_identifier=#{identifier} " <>
    "attempts=#{next_attempt} error_class=#{error_class} " <>
    "error=#{metadata[:error]}"
  )
  post_failure_comment(issue_id, identifier, metadata[:error], next_attempt)
  release_issue_claim(state, issue_id)
else
  # ... existing retry scheduling logic ...
end
```

Add the diagnostic comment poster:

```elixir
defp post_failure_comment(issue_id, identifier, error, attempts) do
  api_key = System.get_env("LINEAR_BOT_API_KEY") || System.get_env("LINEAR_API_KEY")
  if api_key do
    body = """
    ⚠️ **Karkhana failed after #{attempts} attempts**

    ```
    #{error || "unknown error"}
    ```

    **Error class:** #{classify_error(to_string(error || ""))}

    ---
    **Handoff:**
    - To retry → move to **Todo**
    - To investigate → SSH into sandbox `karkhana-#{identifier}`
    - To abandon → move to **Backlog**
    """

    SymphonyElixir.Linear.Client.post_comment(issue_id, body, api_key)
  end
end
```

This requires adding a `post_comment/3` function to `Linear.Client`.
It's a single GraphQL mutation — ~15 lines.

**Tests:**
- `test "permanent error retries 0 times"` — hook failure → no retry
- `test "transient error retries up to 5 times"` — poll failure → retries
- `test "logical error retries up to 3 times"` — subprocess exit → 3 retries
- `test "continuation retries bypass cap"` — `:continuation` type ignores cap
- `test "classify_error/1 categories"` — unit test each error string
- `test "post_failure_comment called on cap"` — mock Linear API, verify

**Files:** `orchestrator.ex`, `linear/client.ex`

---

## Phase 3 — Replace setsid Hack with exec_stream

**Impact: 🔄 ROLLING — affects new agent runs only**

**Problem:** The setsid + file polling approach in `cli.ex` is:
- Shell-in-shell string interpolation (fragile escaping)
- 3s polling latency (stall detection has 3s granularity)
- Two separate exec calls per poll cycle (read output + check done)
- Dead code: `exec_stream` in `bhatti/client.ex` is built but unused

`exec_stream` already handles Cloudflare timeouts with chunked NDJSON
transfer. It's the right intermediate step before bhatti detached exec
(which needs lohar rebuild).

**Changes:**

`elixir/lib/symphony_elixir/claude/cli.ex` — rewrite `execute/3`:

Replace the setsid launch + poll pattern with:

```elixir
defp execute(args, sandbox_id, opts) do
  on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)
  turn_timeout_ms = Keyword.get(opts, :turn_timeout_ms, Config.settings!().claude.turn_timeout_ms)

  {prompt, other_args} = extract_prompt(args)

  with :ok <- Bhatti.write_file(sandbox_id, @prompt_file, prompt) do
    command = Config.settings!().claude.command
    plain_args = Enum.join(other_args, " ")

    # Build command that reads prompt from file (avoids shell escaping)
    cmd = ["bash", "-lc",
      "#{command} -p \"$(cat #{@prompt_file})\" #{plain_args}"
    ]

    state = %{session_id: nil, usage: nil}

    on_line = fn line ->
      case StreamParser.parse_line(line) do
        {:ok, event} ->
          on_event.(event)
        {:error, _} ->
          :ok  # skip non-JSON lines (stderr mixed in, etc)
      end
    end

    case Bhatti.exec_stream(sandbox_id, cmd, on_line,
           timeout_sec: div(turn_timeout_ms, 1000)) do
      {:ok, 0} ->
        {:ok, %{session_id: state.session_id, exit_code: 0, usage: state.usage}}
      {:ok, exit_code} ->
        {:error, {:subprocess_exit, exit_code, ""}}
      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

Wait — the `on_line` callback can't mutate `state` (Elixir is immutable).
We need to accumulate state. Two approaches:

**Approach A (process dictionary — pragmatic):**
```elixir
on_line = fn line ->
  case StreamParser.parse_line(line) do
    {:ok, event} ->
      sid = StreamParser.extract_session_id(event)
      if sid, do: Process.put(:karkhana_session_id, sid)
      usage = StreamParser.extract_usage(event)
      if usage, do: Process.put(:karkhana_usage, usage)
      on_event.(event)
    {:error, _} -> :ok
  end
end

# After exec_stream returns:
session_id = Process.get(:karkhana_session_id)
usage = Process.get(:karkhana_usage)
```

**Approach B (Agent process — cleaner):**
Use an `Agent` to hold state, update from the callback.

Go with Approach A — it runs in a Task already (each agent run is a
supervised Task), so the process dictionary is scoped correctly and
cleaned up on exit.

Remove:
- `@output_file` constant
- `@done_marker` constant
- `@poll_interval_ms` constant
- `poll_output/3`
- `poll_loop/5`
- `process_lines/3`
- `read_stderr/1`
- The entire setsid launch_cmd construction

**What stays:**
- `@prompt_file` — still write prompt to file to avoid shell escaping
- `extract_prompt/1` — still needed
- `build_first_turn_args/1`, `build_resume_args/2` — still needed
- `build_pi_args/2`, `build_claude_args/2` — still needed

**Risk:** The exec_stream path hasn't been tested in production.
Cloudflare tunnel behavior on long-lived chunked responses needs
verification. If it fails, we can revert to setsid — the git
history has it.

**Mitigation:** Test with a 5-minute agent run before switching all
dispatches. Add a config flag `bhatti.use_streaming_exec: true`
(default true) with fallback to the old path if needed.

**Tests:**
- `test "exec_stream receives events in order"` — mock bhatti HTTP
  server, send NDJSON chunks, verify callback order
- `test "exec_stream handles exit code"` — verify non-zero exit
  propagates
- `test "exec_stream timeout"` — verify timeout fires and kills
- `test "session_id extracted from stream"` — verify process dict
  accumulation

**Files:** `claude/cli.ex`

---

## Phase 4 — Session Continuity

**Impact: 🔄 ROLLING — affects continuation runs only**

**Problem:** Each turn is `pi -p <prompt> --no-session`. The agent has
no memory of prior turns. On re-dispatch (In Progress with feedback),
it starts from scratch.

**Changes:**

`elixir/lib/symphony_elixir/claude/cli.ex`:

In `build_pi_args`:
- Remove `--no-session`
- Add `--session-dir /tmp/karkhana-sessions`

```elixir
defp build_pi_args(prompt, settings, opts) do
  attempt = Keyword.get(opts, :attempt)
  continuation = is_integer(attempt) and attempt > 0

  base = [
    "-p", prompt,
    "--mode", "json",
    "--session-dir", "/tmp/karkhana-sessions"
  ]

  base =
    if continuation do
      base ++ ["--continue"]
    else
      base
    end

  base
  |> maybe_add_option(settings.model, "--model")
end
```

**Critical safety check:** On continuation, verify the session dir
exists before using `--continue`. If the sandbox was destroyed and
recreated between turns, the session is gone.

```elixir
defp execute(args, sandbox_id, opts) do
  # ... existing setup ...

  # If --continue is in args, verify session exists
  args = if "--continue" in args do
    case Bhatti.exec(sandbox_id,
           ["test", "-d", "/tmp/karkhana-sessions"],
           timeout_sec: 5) do
      {:ok, %{"exit_code" => 0}} ->
        args  # session dir exists, continue
      _ ->
        Logger.warning("Session dir missing in sandbox #{sandbox_id}, " <>
                       "falling back to fresh invocation")
        args
        |> List.delete("--continue")
    end
  else
    args
  end

  # ... rest of execute ...
end
```

`elixir/lib/symphony_elixir/agent_runner.ex`:
- Pass `attempt` through to CLI opts:

```elixir
cli_opts = [
  on_event: claude_event_handler(claude_update_recipient, issue),
  attempt: Keyword.get(opts, :attempt)
]
```

- Thread `opts` through to `build_pi_args` in cli.ex.

**Data lifecycle note:** Sessions persist in the sandbox filesystem.
Since sandboxes are reused across retries for the same issue, sessions
survive. When the issue goes terminal and the sandbox is destroyed, the
session is correctly gone. The safety check above handles the edge case
where the sandbox was recreated between turns.

**Tests:**
- `test "first turn omits --continue"` — attempt nil → no continue flag
- `test "continuation turn adds --continue"` — attempt > 0 → continue
- `test "missing session dir falls back to fresh"` — mock exec returns
  exit code 1 for test -d → --continue removed
- `test "session dir exists preserves --continue"` — mock exec returns
  exit code 0 → --continue kept

**Files:** `claude/cli.ex`, `agent_runner.ex`

---

## Phase 5 — Self-Publish (Sandbox ID for Preview URLs)

**Impact: 🔄 ROLLING — affects new sandboxes only**

**Problem:** Agent can't call `bhatti publish` because it doesn't know
its own sandbox ID.

**Changes:**

`elixir/lib/symphony_elixir/workspace.ex` — in `create_new_sandbox`:

After successful creation, inject the sandbox ID:

```elixir
case Client.create_sandbox(spec) do
  {:ok, %{"id" => sandbox_id}} ->
    Logger.info("Created sandbox #{sandbox_name} id=#{sandbox_id}")

    # Inject sandbox identity so the agent can self-publish
    Client.exec(sandbox_id, ["bash", "-c",
      "echo 'export BHATTI_SANDBOX_ID=#{sandbox_id}' >> /home/lohar/.bashrc && " <>
      "echo 'export BHATTI_API_KEY=#{System.get_env("BHATTI_API_KEY")}' >> /home/lohar/.bashrc"
    ], timeout_sec: 10)

    # ... after_create hook ...
```

For reused sandboxes (the `find_sandbox_by_name` path), the env vars
are already set from creation. No change needed.

`elixir/WORKFLOW.md` — add publish instructions to the prompt:

```markdown
## Publishing a preview

After starting a dev server, publish the port:
\```bash
curl -s -X POST "https://api.bhatti.sh/sandboxes/$BHATTI_SANDBOX_ID/publish" \
  -H "Authorization: Bearer $BHATTI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"port": 4321}' | jq -r '.url'
\```
Include the returned URL in your Linear comment.
```

**Security note:** `BHATTI_API_KEY` inside the agent sandbox means a
compromised agent can create/destroy sandboxes. This is acceptable in
the current trust model (single-user, agent already has GH_TOKEN and
LINEAR_API_KEY). For multi-tenant, this would need a scoped token.

**Tests:**
- `test "new sandbox has BHATTI_SANDBOX_ID set"` — create, exec
  `echo $BHATTI_SANDBOX_ID`, verify non-empty
- `test "reused sandbox preserves BHATTI_SANDBOX_ID"` — create, reuse,
  verify same ID

**Files:** `workspace.ex`, `WORKFLOW.md`

---

## Phase 6 — Naming Cleanup (codex → agent)

**Impact: ✅ TRANSPARENT — pure refactor, no behavior change**

**Problem:** The entire codebase uses `codex_*` naming from the Symphony
fork. The agent is Pi, not Codex. An AI agent reading
`codex_app_server_pid` in code that runs Pi will be confused — this
directly harms the self-improvement use case.

**Changes:**

Rename across these files (search-replace, verify compilation):

| Old name | New name |
|----------|----------|
| `codex_totals` | `agent_totals` |
| `codex_rate_limits` | `agent_rate_limits` |
| `codex_worker_update` | `agent_worker_update` |
| `codex_app_server_pid` | `agent_pid` |
| `codex_input_tokens` | `agent_input_tokens` |
| `codex_output_tokens` | `agent_output_tokens` |
| `codex_total_tokens` | `agent_total_tokens` |
| `codex_last_reported_*` | `agent_last_reported_*` |
| `last_codex_timestamp` | `last_agent_timestamp` |
| `last_codex_message` | `last_agent_message` |
| `last_codex_event` | `last_agent_event` |
| `integrate_codex_update` | `integrate_agent_update` |
| `apply_codex_token_delta` | `apply_agent_token_delta` |
| `apply_codex_rate_limits` | `apply_agent_rate_limits` |
| `@empty_codex_totals` | `@empty_agent_totals` |

**Config note:** `codex.stall_timeout_ms` in config/schema.ex stays
as-is for backwards compat with existing WORKFLOW.md files that have
the `codex:` section. The internal field names change; the config
parsing layer maps from the old config key to the new internal names.

**Files:**
- `orchestrator.ex` (~60 renames)
- `agent_runner.ex` (~10 renames, message name change)
- `status_dashboard.ex` (~20 renames)
- `config.ex` (function name)
- HTTP API controller (if it exposes codex fields)

**Verification:** `mix compile --warnings-as-errors` must pass. Run
full test suite. Grep for remaining `codex` references — only
`config/schema.ex` (Codex embed) and the config YAML key should remain.

**Tests:** Existing tests pass after rename. No new tests needed — this
is a mechanical refactor.

---

## Phase 7 — Auto-Deploy (git pull for Orchestrator)

**Impact: 🔄 ROLLING — affects orchestrator startup/runtime**

**Problem:** After merging a karkhana PR, need to manually pull on the
orchestrator.

**Approach:** Add git pull to the orchestrator restart loop. The restart
loop (Phase 0) already wraps the `mix run` command. Add a pull before
each start.

**Changes:**

The restart loop script from Phase 0 becomes:

```bash
#!/bin/bash
cd /home/lohar/karkhana/elixir && source .env
while true; do
  echo "$(date -Iseconds) Pulling latest..." >> /tmp/karkhana.log
  cd /home/lohar/karkhana && git pull origin main --ff-only 2>> /tmp/karkhana.log || true
  cd /home/lohar/karkhana/elixir
  echo "$(date -Iseconds) Starting orchestrator..." >> /tmp/karkhana.log
  mix run --no-halt >> /tmp/karkhana.log 2>&1
  EXIT=$?
  echo "$(date -Iseconds) Orchestrator exited ($EXIT), restarting in 5s..." >> /tmp/karkhana.log
  sleep 5
done
```

For hot-reload of WORKFLOW.md without restart (already works — the
workflow_store file watcher detects changes), git pull is enough.

For Elixir code changes, the restart loop handles it: the BEAM exits
(either naturally via a code change that triggers restart, or via crash),
the loop pulls fresh code, and `mix run` picks up the new modules.

**Optional cron for pull-without-restart:** Add a cron inside the
orchestrator sandbox that pulls every 60s. This gives WORKFLOW.md
hot-reload without waiting for a crash:

```bash
echo '* * * * * cd /home/lohar/karkhana && git pull origin main --ff-only 2>/dev/null' | crontab -
```

Add this to `deploy.sh` after starting the orchestrator.

**Tests:**
- Manual: push a WORKFLOW.md change, verify dashboard reflects it
  within 60s
- Manual: push an Elixir code change, kill the orchestrator process,
  verify restart picks up the change

**Files:** `deploy.sh`

---

## Phase ∞ — Bhatti Detached Exec (When Lohar is Rebuilt)

**Impact: 🔄 ROLLING — replaces exec_stream with cleaner approach**

**Problem:** exec_stream (Phase 3) works but is still a synchronous
HTTP request held open for the duration of the agent run. Bhatti's
detached exec (`detach: true`) is the proper solution — returns
immediately with a PID, output goes to a file, poll the file.

**Blocked on:** Sandbox images need new lohar binary that supports
detached exec. The server-side is deployed (commit 878dfc9) but
lohar inside images is old.

**Steps when unblocked:**

1. On agni-01: rebuild lohar binary from latest bhatti source
2. Create fresh minimal sandbox, inject new lohar, save as base image
3. Rebuild karkhana-pi image on new base

**Code changes after images are rebuilt:**

`elixir/lib/symphony_elixir/bhatti/client.ex`:
- Add `exec_detached(sandbox_id, cmd, opts)` that sends `detach: true`
- Returns `{:ok, %{pid: pid, output_file: path}}`

`elixir/lib/symphony_elixir/claude/cli.ex`:
- Replace `exec_stream` call with:
  1. `Bhatti.Client.exec_detached(sandbox_id, cmd)` → returns immediately
  2. Poll the output_file path from the response (same as current setsid
     approach but the file path comes from bhatti, not hardcoded)
  3. Use shorter poll interval (500ms instead of 3s — bhatti manages the
     process lifecycle, less overhead per poll)
- Remove dependency on exec_stream

This is a clean evolution: setsid → exec_stream → detached exec. Each
step removes a hack.

**Files:** `bhatti/client.ex`, `claude/cli.ex`

---

## Implementation Order

```
Phase 0  (ops hygiene)          — 15 min, do first, unblocks everything
Phase 1  (logging)              — 30 min, can debug everything after
Phase 2  (retry cap + classify) — 1 hr, stops hammering
Phase 3  (exec_stream)          — 1 hr, removes fragile setsid layer
Phase 4  (session continuity)   — 1 hr, builds on clean exec
Phase 5  (self-publish)         — 30 min, quick win
Phase 6  (naming cleanup)       — 1 hr, mechanical refactor
Phase 7  (auto-deploy)          — 15 min, closes the deploy loop
Phase ∞  (detached exec)        — blocked on lohar rebuild
```

Phases 0-2 are sequential (each unblocks the next).
Phases 3-5 are sequential (exec → sessions → publish).
Phases 6-7 are independent of 3-5 but should come after 2.

## Dependency Graph

```
Phase 0 ──→ Phase 1 ──→ Phase 2
                              │
                              ├──→ Phase 3 ──→ Phase 4 ──→ Phase 5
                              │
                              ├──→ Phase 6
                              │
                              └──→ Phase 7
                                        │
                              Phase ∞ ──┘ (whenever lohar is rebuilt)
```

---

## What's Explicitly Not in This Plan

**Self-improvement / meta-orchestrator.** Needs run records and outcome
tracking first (see PLAN.md steps 1-2). Self-improvement is an
emergent property of measurable outcomes + editable config + agents
that can edit config. Build the measurement layer first.

**Agent abstraction layer (Pi/Claude behaviour).** Three agents with
different protocols don't share enough surface for a useful abstraction
yet. Add a second agent when there's a concrete reason, not through a
shared behaviour.

**`:httpc` → `Req` HTTP client migration.** Real improvement but not
blocking anything. `:httpc` works, it's just ugly.

**Dashboard improvements.** The dashboard works. Don't polish it until
the underlying data (agent naming, metrics) is clean (Phase 6).

**Linear service account.** A 15-minute ops task, not a code change.
Do it whenever — just create the account and swap the env var.
Doesn't belong in this TODO.

**Multi-project orchestration in a single process.** Two separate
instances is simpler, more resilient, and already proven. Don't
merge them.

**Sandbox cost tracking / metrics.** Useful but not urgent. The
dashboard shows running/retrying counts. Detailed cost tracking
belongs in the role dispatch system (PLAN.md step 4) where
per-role cost visibility matters.
