# Karkhana

कारखाना — a workshop. An engineering workshop of agents on [bhatti](https://github.com/sahil-shubham/bhatti) sandboxes.

Karkhana encodes an engineering methodology — plan before you build, test what the plan says, record decisions that outlive conversations — and runs it through agents in isolated Firecracker VMs. You manage work in Linear. The methodology is enforced by the system, not by discipline.

## The problem

Every agent product has the same shape: ticket → agent → PR → hope it's good. The agent has no methodology. It doesn't plan before implementing. It doesn't check if tests cover the plan. It doesn't record decisions. It doesn't change its approach when debugging vs. building. It gets a ticket and starts writing code.

This works for typo fixes. It breaks for real engineering.

## How karkhana works

Work lives in Linear. Each issue gets a bhatti sandbox — a Firecracker microVM with persistent storage that snapshots when idle and resumes in milliseconds. An agent (pi) runs inside the sandbox, but *how* it works depends on the **mode**.

**Mode is derived from what exists.** Karkhana checks: is there a plan document? Test specs? An implementation branch? The answer determines the mode — planning, implementation, debugging, or QA. No manual tagging required (though labels can override).

```
Issue arrives (Linear Todo)
    │
    ├─ No plan artifact?  →  PLANNING MODE
    │   Agent reads codebase, produces plan document.
    │   Plan must have: dependency graph, file-level changes,
    │   design decisions, test criteria per part.
    │   → Gate: does plan have test criteria? (automated)
    │   → Human reviews plan, approves or sends feedback.
    │
    ├─ Plan exists?  →  IMPLEMENTATION MODE
    │   Agent follows the plan part by part.
    │   Checkpoints between parts: run tests, verify, commit.
    │   Decisions not in the plan → written to decisions.md.
    │   → Gate: tests pass? branch pushed? (automated)
    │   → Human reviews PR, merges or sends feedback.
    │
    ├─ Label: debug?  →  DEBUG MODE
    │   Agent investigates before changing anything.
    │   Read-only until root cause confirmed.
    │   Findings documented, then minimal fix + test.
    │
    └─ Label: qa?  →  QA MODE
        Agent exercises the system as a user would.
        Tries intuitive approaches, reports friction.
        Structured findings: bugs, friction, missing features.
        → Filed as follow-up issues.
```

## Configuration

The methodology lives in your project repo as files — not in karkhana's code:

```
your-project/.karkhana/
  workflow.yaml          # orchestrator config + mode rules
  modes/
    planning.md          # prompt: produce a plan, don't code
    implementation.md    # prompt: follow the plan, checkpoint
    debugging.md         # prompt: investigate first
    qa.md                # prompt: exercise as a user
  gates/
    plan-ready.sh        # check: plan has test criteria?
    tests-pass.sh        # check: build + tests + branch pushed?
```

**workflow.yaml** is YAML — orchestrator settings (Linear project, bhatti config, polling, hooks) plus mode resolution rules and artifact path conventions.

**Mode prompts** are Liquid-templated markdown — same format as before, just one per mode instead of one monolith. They receive `{{ issue.identifier }}`, `{{ issue.title }}`, `{{ issue.description }}`, `{{ attempt }}`.

**Gate scripts** are shell scripts that run in the sandbox. Exit 0 = pass. Non-zero = agent loops. Start simple (does the file exist?), get stricter as confidence grows.

Projects without `.karkhana/` fall back to a single `WORKFLOW.md` — fully backward compatible.

Changing the methodology means editing markdown and shell scripts. No Elixir, no deploys. The orchestrator hot-reloads.

## What karkhana does and doesn't do

| Karkhana does | Karkhana doesn't |
|---------------|------------------|
| Derive mode from artifact state | Manage what happens inside a session |
| Load mode-specific prompts | Replace human engineering judgment |
| Run gate scripts at completion | Enforce one workflow for all work |
| Track outcomes per mode | Automate everything from day one |
| Create sandboxes, launch agents | Provide compute (bhatti does that) |
| Hot-reload config changes | Require restarts for methodology changes |

## Requirements

- A [bhatti](https://github.com/sahil-shubham/bhatti) instance
- A Linear workspace
- Erlang/OTP 27+ and Elixir 1.18+
- pi or Claude Code in the bhatti image
- GitHub token for git operations

## Quick start

```bash
cd elixir
cp .env.example .env  # add LINEAR_API_KEY, BHATTI_API_KEY, GH_TOKEN
mix deps.get && source .env && mix run --no-halt
```

Dashboard at `http://localhost:4000/`. Create an issue in Linear, watch it get picked up.

## Design docs

See [docs/](docs/) for the thinking behind this:
- **[SYSTEM.md](docs/SYSTEM.md)** — architecture, primitives, code change surface
- **[WORKSHOP.md](docs/WORKSHOP.md)** — the methodology and station model
- **[SESSION-INSIGHTS.md](docs/SESSION-INSIGHTS.md)** — evidence from 76 sessions building bhatti

## License

[Apache License 2.0](LICENSE)
