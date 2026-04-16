# Karkhana — Architecture

_What karkhana is, what it isn't, and why it exists._

---

## The problem with every SWE agent product

They all have the same shape:

```
Trigger → Disposable container → Agent → PR → Hope it's good
```

The container dies after the run. The agent has no persistent
environment. It can't run a dev server and give you a URL.
It can't SSH into your production box to read logs. It can't
install a tool it needs and have it still be there next time.
The agent is a tourist — it arrives, does something, and leaves.

And the agent itself is a black box. You can't see what it's
thinking, you can't read its session transcript, you can't
change its system prompt or restrict its tools. You get a text
box for "custom instructions" and a prayer.

## What karkhana is

Karkhana gives agents the same working environment a human
engineer has: a persistent computer with real tools, real
network access, and full source code. Then it gets out of the
way and lets the agent work.

**Three layers, cleanly separated:**

1. **Bhatti** provides the environment — Firecracker VMs that
   boot in seconds, snapshot to disk when idle, resume in
   milliseconds. Persistent volumes. Published ports with
   public URLs. Real Linux with real networking.

2. **Pi** provides the agent — multi-model coding agent with
   session trees, context compaction, tools, skills, extensions.
   Open source, fully configurable.

3. **Karkhana** provides the dispatch — reads tickets from
   Linear, creates sandboxes, launches Pi, tracks outcomes,
   retries failures. A dumb scheduler that connects 1 and 2.

## What makes it different

### The environment persists and has real capabilities

A bhatti sandbox is a real computer. The agent can:
- Clone a repo and have it still be there on the next dispatch
- Install tools and have them persist across retries
- Start a dev server and publish it as a public URL
- SSH into another machine to read logs
- Run a full test suite
- Build and deploy

When something goes wrong, you `bhatti shell` into the agent's
VM and see exactly what it sees. The filesystem, the git state,
the running processes — all inspectable.

### The agent is yours

Pi is open source. You control:
- The model (Anthropic, OpenAI, Google, local)
- The system prompt
- The available tools (read-only for investigation, full for implementation)
- The thinking level
- Skills (domain knowledge loaded lazily)
- Extensions (custom tools, lifecycle hooks)

When the agent makes a bad decision, you can read the full
session transcript — every tool call, every model response,
every reasoning step. Then you improve the prompt or add a
skill to prevent the mistake next time.

### The project owns the configuration

The agent's behavior is defined by files in the project's repo:

```
your-project/.karkhana/
  config.yaml    # tracker, polling, agent settings
  prompt.md      # who the agent is, how it works
  skills/        # domain knowledge about your project
```

Different projects get different agents. A Go systems project
gets "you are a senior Go engineer." A website gets "you are a
web developer." The skills teach the agent your architecture,
your patterns, your safety constraints.

Karkhana's own repo has no project-specific configuration. It's
a generic scheduler. The intelligence lives in the project's
`.karkhana/` directory, version-controlled with the code.

### Linear is the interface, not the workflow engine

You manage work in Linear, not in karkhana. Three states:

- **Todo** — agent picks it up, does the work
- **In Progress** — you gave feedback, agent addresses it
- **In Review** — agent is done, you review

The agent decides how to work based on the ticket. A typo fix
gets a quick branch and PR. A complex investigation gets
research, analysis, and a comment explaining findings. The
agent uses judgment, not a prescribed pipeline.

## What karkhana is NOT

- **Not an agent.** Pi is the agent. Karkhana dispatches it.
- **Not an environment.** Bhatti is the environment. Karkhana
  creates and destroys sandboxes.
- **Not a workflow engine.** There are no pipeline stages, no
  role handoffs, no state machines beyond Linear's own states.
- **Not a SaaS product.** It runs on your infrastructure, with
  your API keys, on your bhatti instance.

## The data model

**Runs** are the primary data:

```
Run {
  issue_id, issue_identifier
  attempt, sandbox_name
  tokens { input, output, cache_read, cache_write }
  cost_usd, duration_seconds
  outcome (success | error | timeout | stalled)
  config_hash (hash of prompt.md + skills)
  started_at, ended_at
}
```

Everything else is a query over runs: per-issue cost, acceptance
rate, config attribution, failure mode analysis.

**Session files** are the audit trail: Pi's full conversation
transcript, archived before sandbox destruction.

**Outcome tracking** from Linear: count state bounces to measure
zero-touch rate (merged without human feedback).

## Safety model

The agent runs in an isolated VM. It can't touch production
unless explicitly given access. Safety boundaries:

1. **OS-level:** Read-only SSH user on production machines
2. **API-level:** Scoped API keys (read-only for investigation)
3. **Prompt-level:** `safety/SKILL.md` tells the agent what it
   must not do (defense in depth, not the primary boundary)
4. **Git-level:** All changes go through PRs, never direct push

The agent's blast radius is its sandbox. It can break its own
VM all it wants — that's what sandboxes are for.

## Growing scope

Start with easy tickets (docs, typo fixes, simple bugs).
Measure the acceptance rate. As the rate stabilizes, give
harder tickets. The prompt and skills improve based on failure
modes — when the agent consistently makes a class of mistake,
add a skill that teaches it the right approach.

The scope grows as the agent demonstrates competence, not as
a feature roadmap.
