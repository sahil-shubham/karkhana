---
name: karkhana
description: |
  Karkhana project knowledge — architecture, module map, testing, and
  deployment. Use when working on karkhana itself.
---

# Karkhana

An engineering workshop of agents on bhatti sandboxes. Manages work from
Linear, dispatches agents to isolated Firecracker VMs, tracks methodology
metrics.

## Architecture

Elixir/OTP application at `elixir/`. Phoenix for the dashboard.

```
Karkhana.Application (supervision tree)
├── Karkhana.Store           — SQLite persistence (runs, config_events, issue_events)
├── Karkhana.WorkflowStore   — Hot-reloads WORKFLOW.md / .karkhana/ config
├── Karkhana.Orchestrator    — Polls Linear, dispatches agents, tracks state
├── Karkhana.HttpServer      — Phoenix endpoint (dashboard + API + webhooks)
└── Karkhana.StatusDashboard — TUI status output
```

Key modules:
- `Karkhana.Protocol` — loads `.karkhana/` directory, resolves mode from labels + artifacts
- `Karkhana.AgentRunner` — runs pi in a bhatti sandbox, resolves mode, runs gates
- `Karkhana.PromptBuilder` — renders Liquid templates with issue data + mode
- `Karkhana.Linear.Webhook` — parses Linear webhook payloads into Tracker.Events
- `Karkhana.Bhatti.Client` — HTTP client for bhatti API
- `Karkhana.SessionReader` — parses pi session JSONL files

## Module naming

Everything is `Karkhana.*` (renamed from `SymphonyElixir.*`). Web modules
are `KarkhanaWeb.*`. The OTP app is `:karkhana`.

## Testing

```bash
cd elixir
mix test                           # all tests (some need bhatti)
mix test test/karkhana/store_test.exs  # store tests (no deps)
mix test test/karkhana/protocol_test.exs  # protocol tests (no deps)
```

Tests that need a bhatti instance: workspace, app_server, ssh, live_e2e.
Tests that work locally: store, protocol, webhook, stream_parser,
orchestrator_status, cli, log_file, specs_check, outcome_tracker.

## Building releases

```bash
cd elixir
MIX_ENV=prod mix release karkhana
# Output: _build/prod/rel/karkhana/
```

GitHub Actions builds on tag push (v*). Deploy with:
```bash
./deploy.sh upgrade v0.x.x
```

## Configuration

Karkhana reads project config from WORKFLOW.md or `.karkhana/workflow.yaml`
in the target project repo (NOT in the karkhana repo). The orchestrator
sandbox clones the target repo and points KARKHANA_WORKFLOW_PATH at it.

The `.karkhana/` directory structure:
```
.karkhana/
  workflow.yaml       — orchestrator config + mode rules
  modes/*.md          — per-mode prompt templates
  gates/*.sh          — quality check scripts
```

## Store

SQLite at `~/.karkhana/store.db`. Three tables: `runs`, `config_events`,
`issue_events`. Query via `Karkhana.Store` API or the dashboard.

## Webhooks

POST /webhooks/linear — receives Linear webhook pushes. Verifies HMAC
signature with LINEAR_WEBHOOK_SECRET env var. Parses into Tracker.Event,
pushes to orchestrator.
