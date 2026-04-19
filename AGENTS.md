# Karkhana

Elixir/OTP orchestrator that dispatches coding agents to bhatti sandboxes.

## Quick reference

- Source: `elixir/lib/karkhana/`
- Tests: `elixir/test/karkhana/`
- Config: `elixir/config/`
- App: `:karkhana`, module: `Karkhana.Application`
- Release: `MIX_ENV=prod mix release karkhana`
- Deploy: `./deploy.sh upgrade v0.x.x`

## Working on this codebase

- Run `cd elixir && mix deps.get` before anything
- `mix compile --warnings-as-errors` must pass — no warnings allowed
- Test files individually: `mix test test/karkhana/<file>_test.exs`
- The app boots without a WORKFLOW.md (idles until configured)
- Skills are in `.pi/skills/karkhana/` — read the SKILL.md for architecture

## Conventions

- All modules are `Karkhana.*` or `KarkhanaWeb.*`
- Config access through `Karkhana.Config` (never raw env reads)
- Persistence through `Karkhana.Store` (SQLite)
- `Config.settings!()` returns safe defaults when no workflow exists
- Webhook endpoint at `/webhooks/linear` (HMAC verified)
- Dashboard at `/` (Phoenix LiveView)

## Design docs (not in git)

Local docs at `docs/` (gitignored):
- `SYSTEM.md` — architecture, primitives
- `WORKSHOP.md` — methodology model
- `SESSION-INSIGHTS.md` — evidence from session analysis
- `PLAN.md` — implementation plan
