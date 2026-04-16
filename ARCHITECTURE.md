# Karkhana — Architecture

_What karkhana is, what it isn't, and what makes it different._

---

## The question

What separates karkhana from every other "agent runs on your tickets"
system? Why would anyone use this instead of Devin, Factory, OpenClaw,
Copilot Workspace, or just running `pi -p` in a cron job?

If the answer is "it runs on bhatti VMs instead of Docker containers"
— that's an infrastructure detail, not a reason to exist. If the
answer is "it has a WORKFLOW.md that hot-reloads" — that's a nice
feature, not an architecture.

## What the other systems actually are

Every autonomous coding agent system has the same shape:

```
Trigger (issue/PR/message)
  → Environment (container/sandbox/VM)
    → Agent (LLM + tools)
      → Output (PR/comment/deployment)
        → Human review
```

They differ in:

| | Devin/Factory | OpenClaw/Sweep | Claude Code + cron |
|---|---|---|---|
| **Trigger** | GitHub/Slack/API | GitHub issues | Manual |
| **Environment** | Proprietary cloud VM | Docker | Local machine |
| **Agent** | Proprietary | Open-source LLM calls | Claude |
| **Output** | PR + deployment | PR | Files on disk |
| **Review** | In-product UI | GitHub PR review | Manual |
| **Control** | SaaS dashboard | GitHub labels | None |
| **Customization** | Prompts in UI | Config files | Full code access |

Karkhana today sits somewhere between OpenClaw and "Claude Code + cron."
It has better isolation (VMs vs containers), better lifecycle management
(retry, reconciliation, state machine), and a nicer coordination surface
(Linear instead of GitHub issues). But architecturally it's the same
shape as everything else.

## What karkhana actually has that's different

Three things, all of which come from owning the full stack:

### 1. The environment is a proper computer, not a disposable container

Bhatti sandboxes are Firecracker VMs with:
- Their own kernel, filesystem, and network
- Snapshot/resume in milliseconds (thermal management)
- Persistent volumes that survive sandbox destruction
- Published ports with public URLs
- Warm/cold lifecycle (idle sandboxes cost zero CPU/memory)

This matters because:

**The agent's workspace persists and has state.** A Docker container is
born, does work, and dies. A bhatti sandbox lives. It has a git clone
from the last run. It has installed dependencies. It has a session
history. When the agent gets re-dispatched (after feedback, after
retry), it wakes up in the same place it left off.

**The agent can run real services.** `bhatti publish` gives the agent a
public URL. The agent can start a dev server, publish it, and put the
URL in the Linear comment. The reviewer clicks the link and sees the
actual running application. No other autonomous agent system does this
because their environments are ephemeral containers without networking.

**The environment can be inspected.** When something goes wrong, you
`bhatti shell karkhana-ME-42` and you're inside the agent's VM. You see
exactly what it sees — the file system, the git state, the running
processes. You can fix things manually and let the agent continue. With
Docker-based systems, the container is gone when the run ends.

### 2. The agent is yours, not a black box

Pi is open source, and karkhana runs it directly. This means:

**Every layer is visible.** The system prompt, the tools, the model, the
token usage, the session transcript — all of it is accessible. When
Devin produces a bad PR, you can't see why it made the decisions it
made. When karkhana produces a bad PR, you can read the session file
and see every tool call, every model response, every reasoning step.

**Every layer is configurable.** You control the model, the thinking
level, the available tools, the system prompt, the skills, the
extensions. You can restrict the reviewer to read-only tools. You can
give the implementer a custom Linear extension. You can change the model
between roles. With SaaS systems, you get a text box for "custom
instructions" and nothing else.

**The agent gets better when Pi gets better.** Session compaction,
auto-retry, new tool implementations, new model support — all of this
flows into karkhana without karkhana-specific work. When Pi adds a new
provider or a new tool, karkhana agents get it immediately.

### 3. The orchestration layer is separate from the agent

This is the architectural distinction that actually matters. In Devin,
the orchestration (what to work on, when to retry, how to coordinate)
and the agent (how to do the work) are fused into one product. You
can't change one without the other.

In karkhana, they're cleanly separated:

```
Karkhana (orchestrator)     Pi (agent)
─────────────────────       ──────────────────
Knows about tickets         Knows about code
Knows about sandboxes       Knows about tools
Knows about retries         Knows about sessions
Knows about pipelines       Knows about models
Decides WHAT to work on     Decides HOW to do it
Decides WHEN to stop        Decides WHAT to try
```

This separation means:

**You can change the orchestration without touching the agent.** Add a
reviewer stage, change the retry policy, add a new ticket source —
none of this requires changes to Pi. The orchestrator just launches Pi
with different flags and prompts.

**You can change the agent without touching the orchestration.** Swap Pi
for Claude Code, for a custom agent, for a human — the orchestrator
doesn't care. It dispatches work to a sandbox and reads the result.
`cli.ex` is the adapter; everything above it is agent-agnostic.

**You can compose multiple agents on one ticket.** The implementer and
the reviewer are the same Pi binary with different prompts and tools.
The orchestrator manages the pipeline. The agents don't know about
each other.

## The architecture, stated plainly

Karkhana is a **dispatch and lifecycle system** for coding agents
running in isolated VMs.

It is NOT:
- An agent (Pi is the agent)
- An environment (bhatti is the environment)
- A CI system (the agents decide what to do, not a script)
- A workflow engine (the pipeline is declarative config, not a DAG)

It IS:
- The thing that decides which agent works on which ticket
- The thing that creates and destroys environments
- The thing that retries when things fail
- The thing that tracks what happened and what it cost
- The thing that moves tickets through a pipeline of agent roles

Its value comes from:
1. Owning the lifecycle (create sandbox → dispatch → monitor → retry → cleanup)
2. Owning the data (what was dispatched, what happened, what it cost)
3. Providing the configuration surface (roles, skills, pipelines)
4. Keeping the human in the loop (Linear as the coordination layer)

## What this means for how to build it

### The orchestrator should be dumb

The orchestrator doesn't need to understand code, git, PRs, or
programming. It understands: tickets have states, agents produce
outcomes, outcomes determine next steps, failures get retried.

All domain knowledge belongs in the agent's configuration (prompts,
skills, tools). The orchestrator is a state machine that dispatches
work and reacts to results.

This is already roughly true in the current code. The orchestrator
(`orchestrator.ex`) is agent-agnostic — it dispatches tasks and
handles lifecycle. The domain knowledge lives in WORKFLOW.md. The
risk is that domain knowledge leaks into the orchestrator as the
system gets more complex. Resist this.

### Roles are configurations, not code modules

A "reviewer" is not a new Elixir module. It's:

```yaml
role: reviewer
prompt: roles/reviewer.md
tools: [read, bash, grep, find, ls]
thinking: high
sandbox:
  image: karkhana-pi
  cpus: 2
  memory_mb: 2048
```

The orchestrator reads this config and launches Pi with the
corresponding flags. Adding a new role is creating a YAML file and
a markdown prompt. No Elixir changes.

A `PipelineEngine` module would be premature. The
orchestrator already has the dispatch machinery. What it needs is:

1. A way to know which role to use for a given issue state
2. A way to read role configuration from a file
3. A way to pass that configuration to Pi as CLI flags

This is ~50 lines of config parsing, not a new subsystem.

### Pipelines are state machine configs, not engine internals

A pipeline is a mapping from issue states to roles:

```yaml
pipeline:
  - state: Todo
    role: implementer
    next_state: In Review

  - state: In Review
    role: reviewer
    transitions:
      approved: Human Review
      changes_requested: In Progress

  - state: In Progress
    after_role: reviewer    # only dispatch when coming from reviewer
    role: implementer
    next_state: In Review
```

The orchestrator already reacts to issue states. A pipeline config
just tells it which role to use for each state. The `choose_issues`
function already checks issue state — extending it to look up a role
from config is trivial.

There's no need for a pipeline state object, pipeline reconstruction,
or an iteration counter. The state lives in Linear (the issue's
current state + comment history). The orchestrator is stateless
across restarts by design (Symphony spec §7.4).

### The data model is runs, not pipelines

The orchestrator should record **runs** — atomic units of "we
dispatched role X to issue Y and here's what happened":

```
Run {
  issue_id, issue_identifier
  role (implementer, reviewer, ...)
  attempt number
  sandbox_id
  model, thinking_level
  tokens { input, output, cache_read, cache_write }
  cost_usd
  duration_seconds
  outcome (success, error, timeout, stalled, cancelled)
  error_class, error_message
  config_version (git SHA or file hash)
}
```

This is the primitive. Everything else — acceptance rate, cost per
ticket, failure mode analysis — is a query over runs. Per-issue
history is: all runs with this issue_id, ordered by time. Pipeline
progress is: what roles have run on this issue?

Runs don't need a database. An in-memory list in the orchestrator
state (lost on restart, which is fine — it's operational data, not
business data) plus an optional append-only JSONL file for
persistence.

### Configuration changes need attribution

Every run records which version of the configuration was used. When
you change `roles/implementer.md`, the next run records the new
file hash. This lets you ask: "did the prompt change improve
outcomes?"

This doesn't require a versioning system. It requires:
1. Hashing the role file + skill files at dispatch time
2. Storing the hash with the run record
3. Grouping outcomes by config hash in the dashboard

### The dashboard shows what matters

Current dashboard: tokens, runtime, active/retrying issues.

Better dashboard:
```
Active:
  ME-42  implementer  turn 3  $0.37  12min  cache:84%

Recent (last 24h):
  ME-41  implementer  ✓ merged    $0.45  14min
  ME-40  implementer  ✓ merged    $0.52  18min  (1 human touch)
  ME-39  reviewer     ✗ rejected  $0.12   3min
  ME-38  implementer  ✓ merged    $0.41  11min

Totals (7d): 12 issues, $6.20, 78% zero-touch
Config: roles/implementer.md @ abc123 (since Apr 10)
```

This tells you: the system is working, it costs ~$0.50 per issue,
and 78% of issues need zero human intervention. When you change a
prompt file, you watch this number move.

## The relationship to bhatti

Bhatti provides: VMs, snapshots, volumes, networking, images.
Karkhana provides: dispatch, lifecycle, roles, measurement.

Together: programmable engineering teams on programmable infrastructure.

Karkhana is a bhatti application — the same way a web framework is a
Linux application. It uses bhatti's primitives (create, exec, destroy,
publish, volumes) to build a higher-level abstraction (agents working
on tickets).

The things karkhana needs from bhatti that it doesn't have yet:
1. Detached exec (lohar rebuild — in TODO Phase ∞)
2. Sandbox identity inside the sandbox (BHATTI_SANDBOX_ID — TODO Phase 5)
3. Eventually: exec with persistent stdin (for Pi RPC mode)

The things bhatti should NOT know about:
- Linear, tickets, agents, prompts, roles
- Karkhana is a user of bhatti, not a component of it

## Summary

Karkhana is different from OpenClaw et al because:

1. **Persistent, inspectable, publishable environments** (bhatti VMs,
   not disposable containers)
2. **Open, configurable, composable agent** (Pi with skills/tools/
   extensions, not a black box)
3. **Separated orchestration and execution** (karkhana dispatches,
   Pi executes, both independently configurable)
4. **Self-hosted with full data ownership** (your infra, your prompts,
   your measurement, your iteration loop)
5. **Linear as coordination surface** (human steers by moving tickets,
   not by chatting with an AI)

The architecture is intentionally simple: a polling orchestrator that
maps ticket states to agent roles, launches them in VMs, and records
what happens. The intelligence is in the agent configuration (prompts,
skills, tools). The infrastructure is in bhatti. Karkhana is the thin,
dumb layer in between that makes them work together.
