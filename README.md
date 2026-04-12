# Karkhana

Coding agents in isolated VMs, managed through Linear.

Karkhana (Hindi: कारखाना — factory, workshop) turns Linear tickets into implementation plans and pull requests.

Built on [OpenAI's Symphony](https://github.com/openai/symphony) and [bhatti](https://github.com/sahil-shubham/bhatti). Each Linear issue gets its own Firecracker microVM. Agents run inside these sandboxes. Idle sandboxes snapshot to disk and resume in milliseconds when work arrives.

You manage work in Linear, not agents in terminals.

## How It Works

```
Linear (Todo)             You create an issue
     |
     v  30s poll
Karkhana orchestrator     Picks it up, creates a bhatti sandbox
     |
     v
Claude Code (in VM)       Reads the ticket, posts an implementation plan
     |
     v
Linear (In Review)        You review the plan
     |
     v  You move to In Progress
Claude Code (in VM)       Implements, pushes branch, opens PR
     |
     v
Linear (In Review)        You review the PR, merge or request changes
     |
     v  Done / back to In Progress
Sandbox destroyed          or agent iterates on feedback
```

Two modes driven by Linear issue state:

- **Todo** -- agent reads the ticket, explores the codebase, posts a plan as a Linear comment, moves to In Review. No code changes.
- **In Progress** -- agent reads the latest comments for feedback, implements the plan, verifies the build, pushes a branch, creates a PR, moves to In Review.

You steer by moving issues between states. The agent never polls for comments -- status transitions are the communication protocol.

## Requirements

- A running [bhatti](https://github.com/sahil-shubham/bhatti) instance with a pre-built image containing Claude Code (`karkhana-claude`)
- A Linear workspace with a project
- Erlang/OTP 27+ and Elixir 1.18+
- Claude Code authenticated (OAuth or API key) in the bhatti image
- GitHub token for git push and PR creation

## Quick Start

```bash
cd elixir

# Configure
cat > .env << 'EOF'
export LINEAR_API_KEY=lin_api_...
export BHATTI_API_KEY=bht_...
export GH_TOKEN=ghp_...
EOF

# Edit WORKFLOW.md -- set your project_slug, repo, and prompt
vim WORKFLOW.md

# Run
source .env && mix deps.get && mix run --no-halt
```

The orchestrator polls Linear every 30 seconds. Create an issue in your project, set it to Todo,
and watch the dashboard at `http://localhost:4000/`.

## Deploying to Bhatti

The orchestrator itself can run in a bhatti sandbox:

```bash
bhatti create --name karkhana-orchestrator --image karkhana-orchestrator \
  --cpus 2 --memory 4096 --keep-hot
```

`keep-hot` ensures the orchestrator never sleeps. Agent sandboxes go cold when idle and wake
in ~50ms when dispatched.

## Configuration

All configuration lives in `elixir/WORKFLOW.md` -- a Markdown file with YAML front matter.
The front matter configures the orchestrator. The Markdown body is the agent's prompt template.

The orchestrator hot-reloads when this file changes. No restart needed.

Key sections:

| Section | Purpose |
|---------|---------|
| `tracker` | Linear project and API key |
| `agent`   | Concurrency limits, max turns, retry backoff |
| `claude`  | Claude CLI flags, timeouts |
| `bhatti`  | Sandbox image, CPU/memory, bhatti API endpoint |
| `hooks`  | Shell scripts run inside sandboxes (after_create, before_run) |

See [SPEC.md](SPEC.md) for the full configuration reference (inherited from Symphony).

## License

This project is licensed under the [Apache License 2.0](LICENSE).
