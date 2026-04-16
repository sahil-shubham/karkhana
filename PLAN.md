# Karkhana — Plan

What to build after the TODO.md operational fixes are done.

See ARCHITECTURE.md for why karkhana exists and how it's different.
See TODO.md for the immediate work (phases 0-7).

---

## Where we are

Karkhana runs one role (implementer) with one monolithic prompt
(WORKFLOW.md) against one project. It dispatches, retries, and
shows a dashboard. It works, roughly.

What's missing:

1. **No role system.** Every ticket gets the same agent with the
   same prompt and the same tools. A research task and an
   implementation task get identical treatment.

2. **No outcome tracking.** The orchestrator knows "the process
   exited cleanly" but not "the PR was merged" or "the human
   had to redo 60% of it."

3. **No cost attribution.** Global token totals but no per-issue
   cost, no per-role cost, no config-version attribution.

4. **Monolithic prompt.** WORKFLOW.md mixes system identity, git
   workflow, Linear API patterns, code standards, and review
   protocol in one file. Changing one thing means understanding
   all of them.

---

## What to build, in order

### 1. Run records

The foundational data model. Every dispatch attempt records:

```elixir
%Run{
  issue_id: "abc-123",
  issue_identifier: "ME-42",
  role: "implementer",
  attempt: 2,
  sandbox_id: "sb_xxx",

  model: "claude-sonnet-4-20250514",
  thinking_level: "medium",
  config_hash: "a1b2c3",          # hash of role + skill files used

  tokens: %{input: 45_000, output: 12_000, cache_read: 38_000, cache_write: 7_000},
  cost_usd: 0.37,
  duration_seconds: 900,

  outcome: :success,               # :success | :error | :timeout | :stalled | :cancelled
  error_class: nil,
  error_message: nil,

  started_at: ~U[2026-04-14 10:00:00Z],
  ended_at: ~U[2026-04-14 10:15:00Z]
}
```

Stored as a list in orchestrator state. Optionally appended to a
JSONL file for persistence across restarts. Surfaced on the dashboard
and in the `/api/v1/state` response.

**Requires:** Expand `stream_parser.ex` to extract cache tokens and
cost from Pi events (they're already in the stream, just not parsed).
Add a `runs` list to the orchestrator state. Record a run on every
worker completion.

**Effort:** Half day.

### 2. Outcome tracking

Close the loop: did the work land?

A periodic scan (every poll cycle, or a separate timer) checks closed
issues:

```elixir
defp classify_outcome(issue, runs) do
  # Count state bounces: In Review → In Progress = one human touch
  touches = count_state_bounces(issue)

  cond do
    touches == 0 -> :zero_touch     # merged without feedback
    touches == 1 -> :one_touch      # one round of feedback
    touches <= 3 -> :multi_touch    # multiple rounds
    true -> :heavy_touch            # significant human intervention
  end
end
```

Data source: Linear's issue history (state transitions are in the
activity feed). No GitHub API needed for the basic version — just
count how many times the issue bounced between In Review and In
Progress.

Surface as a weekly summary on the dashboard:

```
Last 7 days: 12 issues closed
  Zero-touch:  5 (42%)    ← the number to improve
  One-touch:   4 (33%)
  Multi-touch: 2 (17%)
  Heavy:       1 (8%)
  Avg cost: $0.82/issue
```

**Requires:** A Linear GraphQL query for issue history. A classifier
function. A dashboard section. No orchestrator logic changes.

**Effort:** One day.

### 3. Prompt decomposition

Split WORKFLOW.md into independently editable pieces that map to
Pi's native concepts:

```
elixir/
  WORKFLOW.md              # front matter only (orchestrator config)
  roles/
    implementer/
      ROLE.md              # prompt: "you are an implementer..."
      config.yaml          # tools, thinking level, model
    reviewer/
      ROLE.md              # prompt: "you are a reviewer..."
      config.yaml
  skills/
    git-workflow/
      SKILL.md             # branching, PRs, idempotent ops
    linear-api/
      SKILL.md             # comments, state transitions
    code-standards/
      SKILL.md             # project-specific quality rules
    review-handoff/
      SKILL.md             # when to stop, what to post
```

The orchestrator loads the role config for the current dispatch and
passes it to Pi:

```elixir
defp build_pi_command(role_config, prompt, skills_dir) do
  [
    role_config.command || "pi",
    "-p", prompt,
    "--mode", "json",
    "--append-system-prompt", File.read!(role_config.prompt_file),
    "--tools", Enum.join(role_config.tools, ","),
    "--thinking", role_config.thinking,
    "--session-dir", "/home/lohar/karkhana-sessions"
  ]
  |> maybe_add("--skill", skills_dir)
  |> maybe_add("--model", role_config.model)
end
```

**Backwards compatibility:** If `roles/` doesn't exist, fall back
to WORKFLOW.md body as the prompt (current behavior). The decomposition
is opt-in.

**Effort:** One day for the config loading. The actual prompt
splitting is iterative — extract one skill at a time, verify it
still works.

### 4. Role dispatch

The orchestrator uses a pipeline config to decide which role handles
each issue state:

```yaml
# In WORKFLOW.md front matter or a separate pipeline.yaml
pipeline:
  - state: Todo
    role: implementer

  - state: In Review
    role: reviewer
    only_after: implementer   # don't dispatch if human moved it here

  - state: In Progress
    role: implementer
```

The change in the orchestrator is small. In `choose_issues`, after
selecting an eligible issue:

```elixir
defp role_for_issue(issue) do
  pipeline = Config.settings!().pipeline

  case Enum.find(pipeline, &match_state?(&1, issue)) do
    %{role: role_name} -> load_role_config(role_name)
    nil -> load_role_config("implementer")  # default
  end
end
```

The `dispatch_issue` function passes the role config through to
`AgentRunner.run`, which passes it to `Claude.CLI`, which builds
the Pi command with the right flags.

**The `only_after` check:** To know if the issue arrived at "In
Review" from the implementer (should trigger reviewer) vs from a
human (should not), check the last run record for this issue. If
the last run was role=implementer and outcome=success, dispatch the
reviewer. Otherwise, skip.

**Effort:** Half day for the dispatch logic. The reviewer prompt
itself is iterative work.

### 5. Config attribution

Each run records a config hash — a hash of the role file + skill
files used for that dispatch. The dashboard groups outcomes by
config hash:

```
Config abc123 (since Apr 10, roles/implementer.md change):
  18 runs, 72% zero-touch, avg $0.48

Config 9f8e7d (Apr 3-10, previous implementer prompt):
  14 runs, 57% zero-touch, avg $0.52
```

This tells you whether your last prompt change helped.

**Requires:** Hash the relevant files at dispatch time. Store with
the run record. Group-by in the dashboard query.

**Effort:** Two hours.

---

## What this looks like when it's working

You're running karkhana on your project. The weekly dashboard shows:

```
Week of Apr 14-20:
  15 issues dispatched
  12 closed
    Zero-touch: 8 (67%)
    One-touch:  3 (25%)
    Multi-touch: 1 (8%)
  Total cost: $7.20 ($0.60/issue avg)
  
  Top failure mode: incomplete implementation (3 issues)
  
  Config: implementer@abc123, reviewer@def456
  Previous week: 58% zero-touch (implementer@9f8e7d, no reviewer)
```

You see: adding the reviewer role improved zero-touch from 58% to
67%. The remaining failures are "incomplete implementation" — the
agent does part of the work but misses edge cases.

You edit `skills/code-standards/SKILL.md` to add: "Always check
edge cases. If the ticket mentions error handling, implement it
explicitly." Next week, you check if the incomplete rate dropped.

This is the iteration loop. No self-improvement system, no AI
editing its own prompts. Just: measure, identify the top failure
mode, edit a file, measure again.

Self-improvement becomes possible later — it's just an agent that
does the "edit a file" step — but the loop works without it. And
you won't know if self-improvement is working unless you have the
measurement layer first.

---

## What's not in this plan

**Pipeline state reconstruction from Linear comments.** Not needed.
The orchestrator checks the last run record to decide which role to
dispatch. No comment parsing, no structured footers, no pipeline
state objects.

**Pipeline engine module.** The dispatch logic is a lookup table
from issue state to role config. It's 20 lines in `choose_issues`,
not a subsystem.

**Iteration counters / max review rounds.** Use the retry cap from
TODO.md Phase 2. If the reviewer and implementer bounce 3 times,
the retry cap fires and posts a diagnostic comment. No separate
iteration tracking needed.

**Session forking for reviewer context.** Nice to have but not
required. The reviewer can read the PR diff and the implementer's
Linear comment — the same information a human reviewer would have.
Forking the session is an optimization for later.

**Canary deploys for config changes.** Prompt changes are low-risk
(they affect agent output, not orchestrator stability). The
measurement layer tells you if a change was bad. Just revert the
file.

**Multi-project in one orchestrator.** Two instances is fine. Merge
them when managing >3 instances becomes painful.

**Automatic acceptance rate from GitHub.** Start with Linear state
transitions only (zero API integration needed beyond what exists).
Add GitHub PR merge status later if the Linear-only signal isn't
precise enough.

---

## Dependency on TODO.md

The plan above assumes TODO.md phases 0-3 are done:

- Phase 0 (ops hygiene) → orchestrator doesn't crash silently
- Phase 1 (logging) → can debug failures
- Phase 2 (retry cap) → failures don't loop forever
- Phase 3 (exec_stream) → agent output is reliable

Steps 1-2 of this plan (run records, outcome tracking) can start
during or after TODO Phase 2. They don't depend on exec_stream or
session continuity.

Steps 3-4 (decomposition, role dispatch) should come after TODO
Phase 4 (session continuity) since roles need to pass different
Pi flags.

Step 5 (config attribution) is trivial once steps 1 and 3 exist.

```
TODO Phase 0-2  →  PLAN Step 1 (run records)
                →  PLAN Step 2 (outcome tracking)
TODO Phase 3-5  →  PLAN Step 3 (decomposition)
                →  PLAN Step 4 (role dispatch)
                →  PLAN Step 5 (config attribution)
```
