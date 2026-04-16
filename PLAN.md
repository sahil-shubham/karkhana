# Karkhana — Plan

What to build next.

---

## Where we are

Karkhana dispatches agents to bhatti sandboxes from Linear tickets.
It has per-issue cost tracking, retry caps, session continuity,
detached exec, and a dashboard. It works.

What's wrong: the prompt is a monolith that lives in karkhana's
repo, the agent has no domain knowledge about the project it's
working on, and we over-built a role/pipeline system nobody needs.

## What to build

### 1. Per-project configuration (`.karkhana/`)

The project being worked on owns the agent's configuration.
Not karkhana. Not a shared WORKFLOW.md.

```
bhatti/.karkhana/
  config.yaml          # tracker, polling, agent settings
  prompt.md            # "you are a senior Go engineer working on bhatti..."
  skills/
    bhatti-arch/SKILL.md       # how bhatti works
    firecracker/SKILL.md       # FC concepts the agent needs
    go-patterns/SKILL.md       # Go idioms used in this project
    safety/SKILL.md            # what the agent must not do

bhatti.sh/.karkhana/
  config.yaml
  prompt.md            # "you are a web developer working on bhatti.sh..."
  skills/
    astro-site/SKILL.md
```

The `after_create` hook clones the target repo into `/workspace`.
The `.karkhana/` directory is now in the sandbox. The orchestrator
reads `config.yaml` from there. Pi reads skills from
`/workspace/.karkhana/skills/` directly.

**What changes in the orchestrator:**
- `config.yaml` replaces WORKFLOW.md front matter (tracker config,
  agent settings, hooks)
- `prompt.md` is passed via `--append-system-prompt` (the `-p`
  argument is just the ticket template)
- Skills are passed via `--skill /workspace/.karkhana/skills/<name>`
- WORKFLOW.md in karkhana's repo becomes a minimal default

**Effort:** One day. Most of the wiring already exists from the
role loading code — just redirect it to `.karkhana/` in the
workspace instead of `roles/` in the orchestrator.

### 2. Strip the role/pipeline machinery

Remove from the orchestrator:
- `pipeline_config()` in config.ex
- `role_for_issue()` in orchestrator.ex
- `compute_config_hash()` (replace with simpler prompt.md hash)
- `load_role_config()` in agent_runner.ex
- The `roles/` and `skills/` directories in karkhana's repo
- Pipeline config from WORKFLOW.md front matter

The orchestrator goes back to what it should be: dispatch the
agent when the issue is in an active state. One prompt. One agent.
The agent decides how to work based on the ticket.

**Effort:** Half day. It's removing code.

### 3. bhatti as the first project

Create `bhatti/.karkhana/` with:

**config.yaml:**
```yaml
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: <bhatti-project-slug>
  active_states: [Todo, In Progress]

polling:
  interval_ms: 30000

agent:
  max_concurrent_agents: 2
  max_turns: 20
```

**prompt.md:**
```
You are a senior engineer working on bhatti, a Firecracker
microVM orchestrator written in Go. The codebase is at /workspace.

Use your judgment to decide the right approach for each ticket.
Some tickets need investigation. Some need implementation.
Some need both. Read the ticket, explore the code, and work
accordingly.

When you're done:
- Post one comment on the issue explaining what you did and why
- If you made code changes: push a branch and open a PR
- If the work is research/analysis: post findings as a comment
- Move to In Review

If the ticket is too large or ambiguous, post your analysis
explaining what you found and what you recommend. Move to
In Review for discussion.

If the issue is In Progress, the reviewer left feedback in the
comments. Read it, address it, and move back to In Review.
```

**skills/bhatti-arch/SKILL.md:**
The agent's guide to bhatti's architecture — what each package
does, how the engine/server/store/lohar components fit together,
how to run tests, how to build.

**skills/safety/SKILL.md:**
What the agent must not do:
- Do not modify anything on agni-01 directly
- Do not delete production sandboxes
- Do not change firewall rules or network config
- Read-only access to production logs and metrics
- All changes go through PRs, never direct pushes to main

Start with documentation tickets. Measure success. Grow scope to
bug fixes, then features, then investigation tasks.

### 4. Safety model for production access

When the agent needs to debug production issues (later, not now):

**Read-only investigation sandbox:** A sandbox with access to:
- Production logs via a log aggregation endpoint or file mount
- Bhatti API with a read-only scoped key (can list/inspect but not
  create/destroy)
- SSH to agni-01 with a `readonly` user (can read logs, run
  diagnostic commands, but not modify config or restart services)

**What the agent CAN do:**
- Read logs from `/var/log/bhatti/`, journalctl output
- Run `bhatti ls`, `bhatti inspect`, `bhatti exec <sandbox> -- cat /some/log`
- Read Firecracker metrics files
- Read Cloudflare analytics via API

**What the agent CANNOT do:**
- Restart the bhatti daemon
- Destroy sandboxes it didn't create
- Modify config files on agni-01
- Push to main without a PR
- Change firewall or network rules

The safety boundary is enforced by:
1. The `readonly` SSH user on agni-01 (OS-level)
2. A read-only bhatti API key (server-level)
3. The `safety/SKILL.md` prompt (agent-level, defense in depth)
4. PR-only workflow (git-level)

### 5. Dashboard improvements

- Max height + scroll on "Recent runs" section
- Show the prompt.md hash per run (config attribution)
- Show which project each run belongs to (when multi-project)
- Fix the outcome tracker GraphQL query

### 6. Multi-project

When bhatti (Go project) and bhatti.sh (website) both run:

Two orchestrator instances, each with their own config:
- Instance 1: `bhatti/.karkhana/config.yaml` (Go project)
- Instance 2: `bhatti.sh/.karkhana/config.yaml` (website)

Or: one orchestrator that reads from multiple `.karkhana/` configs.
Decide when we get there. Two instances is simpler.

---

## What's explicitly not in this plan

**Roles and pipeline stages.** The agent decides how to work based
on the ticket. "Planner" and "reviewer" are prompt techniques
within one session, not separate dispatches.

**Linear state-driven pipelines.** Linear states are: Todo (agent
works), In Progress (human gave feedback, agent works again),
In Review (agent is done, human reviews). That's it.

**Structured phases in the prompt.** The agent uses judgment.
A typo fix doesn't need a planning phase. An investigation doesn't
need an implementation phase. Trust the model.

**Self-improvement.** Measure first. The acceptance rate tells you
where to improve the prompt and skills. Edit them yourself.
Agent-driven self-improvement is a distraction until the manual
iteration loop works.

---

## Order

```
Step 1: .karkhana/ in bhatti.sh repo (test with existing project)
Step 2: Strip role/pipeline code
Step 3: .karkhana/ in bhatti repo (Go project, docs first)
Step 4: Dashboard fixes
Step 5: Safety model for production access (when needed)
Step 6: Multi-project (when needed)
```
