# Karkhana

कारखाना — a workshop. An engineering workshop of agents on [bhatti](https://github.com/sahil-shubham/bhatti) sandboxes.

Karkhana manages the full engineering lifecycle — plan, implement, verify, review — through agents in isolated Firecracker VMs. Work lives in Linear. The methodology is enforced by the system, not by discipline.

## How it works

Linear workflow states drive everything. Each state maps to a karkhana behavior:

```
Backlog ──→ Todo ──→ Planning ──→ Plan Review ──→ Implementing ──→ In Review ──→ Done
             │         │              │                │              │
          dispatch  dispatch     human gate        dispatch      human gate
         (planning) (planning)  (sandbox stops)  (implementation) (sandbox stops)
```

**Dispatch states** — karkhana creates a bhatti sandbox, runs an agent with the mode's prompt, checks gates on completion, and advances the issue.

**Human gate states** — karkhana pauses the sandbox (frees resources), waits for human review. Move the issue forward to approve, backward to request changes.

**Terminal states** — karkhana destroys the sandbox and cleans up.

Karkhana auto-creates these workflow states in Linear on startup. You configure them in `workflow.yaml`, karkhana syncs them via the Linear API. No manual Linear setup.

## The lifecycle

```
1. Human creates issue → Triage / Todo
2. Karkhana dispatches planning mode
   → Agent reads codebase, produces PLAN-ME-42.md
   → Gates check: plan exists? has test criteria?
   → Pass → karkhana moves to Plan Review, stops sandbox
3. Human reviews plan
   → Approve → move to Implementing
   → Feedback → move back to Planning (agent gets feedback)
4. Karkhana dispatches implementation mode
   → Agent follows plan part by part, runs tests
   → Gates check: builds? tests pass? branch pushed?
   → Pass → karkhana moves to In Review, stops sandbox
5. Human reviews PR
   → Merge → Done (sandbox destroyed)
   → Feedback → back to Implementing
```

## Gate system

Gates are quality checkpoints that run after an agent session completes. Four types:

- **artifact_exists** — does the plan file exist?
- **content_match** — does the plan mention test criteria?
- **command** — does `go build ./...` or `mix test` pass?
- **script** — custom check script in `.karkhana/gates/`

When a gate fails, the agent retries with the gate's output injected into its prompt: *"Gate 'plan-quality' failed: Plan missing test criteria for Part 3. Fix this specifically."*

## Bhatti integration

Karkhana uses bhatti's sandbox primitives beyond create/destroy:

- **Checkpoint** — snapshot sandbox state before running gates. Resume from checkpoint on gate failure instead of re-running the whole session.
- **Stop/Start** — pause sandboxes at human gates (free host RAM). Resume in ~3ms when human approves.
- **Shell token** — generate browser terminal URLs so reviewers can inspect sandbox state.
- **Publish** — QA agents expose preview URLs for human review.

## Configuration

The methodology lives in your project repo:

```
your-project/.karkhana/
  workflow.yaml          # lifecycle states, modes, gates, bhatti config
  modes/
    planning.md          # prompt: produce a plan, don't code
    implementation.md    # prompt: follow the plan, checkpoint
    debugging.md         # prompt: investigate first
    qa.md                # prompt: exercise as a user
  gates/
    plan-quality.sh      # check: plan has test criteria?
```

### workflow.yaml

```yaml
project:
  name: my-project
  language: go
  build: "go build ./..."
  test: "go test ./..."

lifecycle:
  auto_sync: true  # create these states in Linear automatically
  states:
    Todo:          { type: dispatch, linear_type: unstarted, mode: planning, on_complete: Plan Review }
    Planning:      { type: dispatch, linear_type: started, mode: planning, on_complete: Plan Review }
    Plan Review:   { type: human_gate, linear_type: started, sandbox: stop }
    Implementing:  { type: dispatch, linear_type: started, mode: implementation, on_complete: In Review }
    In Review:     { type: human_gate, linear_type: completed, sandbox: stop }
    Done:          { type: terminal, linear_type: completed, sandbox: destroy }
    Cancelled:     { type: terminal, linear_type: canceled, sandbox: destroy }

modes:
  planning:
    prompt: modes/planning.md
    gates:
      - { name: plan-exists, check: artifact_exists, artifact: plan, on_failure: retry_with_feedback }
      - { name: plan-quality, check: script, script: gates/plan-quality.sh, on_failure: retry_with_feedback }

  implementation:
    prompt: modes/implementation.md
    gates:
      - { name: builds, check: command, command: "go build ./...", on_failure: retry_with_feedback }
      - { name: tests-pass, check: command, command: "go test ./...", on_failure: retry_with_feedback }
      - { name: branch-pushed, check: command, command: "git log -1 origin/$(git branch --show-current)", on_failure: retry_with_feedback }

artifacts:
  plan:
    paths: ["docs/PLAN-{{ issue.identifier }}.md"]
```

Changing the methodology means editing markdown and YAML. No Elixir, no deploys. The orchestrator hot-reloads.

## Architecture

```
Karkhana.Application (supervision tree)
├── Karkhana.Store              — SQLite persistence
├── Karkhana.WorkflowStore      — Hot-reloads workflow.yaml
├── Karkhana.Linear.WorkflowSync — Syncs lifecycle states to Linear
├── Karkhana.Orchestrator       — Polls Linear, dispatches agents
├── Karkhana.HttpServer         — Phoenix dashboard + API
└── Karkhana.StatusDashboard    — TUI status output
```

Key modules:
- `Karkhana.Gate` — runs quality gates (artifact, content, command, script)
- `Karkhana.AgentRunner` — runs pi in a bhatti sandbox with mode-specific prompts
- `Karkhana.Config.Schema.Lifecycle` — maps Linear states to karkhana behaviors
- `Karkhana.Config.Schema.Modes` — mode configs (prompt, gates, agent tuning)
- `Karkhana.PromptBuilder` — renders Liquid templates, injects gate feedback on retries

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

Dashboard at `http://localhost:4000/`.

## Deploy

Karkhana runs as an Elixir release inside a bhatti sandbox:

```bash
./deploy.sh                    # first time: create sandbox + deploy
./deploy.sh upgrade v0.5.2     # download release, restart
./deploy.sh workflow           # update WORKFLOW.md only (hot reload)
./deploy.sh logs               # tail orchestrator logs
```

## License

[Apache License 2.0](LICENSE)
