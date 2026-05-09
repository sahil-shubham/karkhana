# Karkhana

Agentic orchestrator on top of [bhatti](https://github.com/sahil-shubham/bhatti).

> A driver agent decomposes the operator's goal into parallel
> computer-use sub-tasks, dispatches them as worker agents in
> bhatti sandboxes, and collates their results. Operator watches
> everything live on a Figma-like canvas.

See [`PLAN-bhatti-karkhana.md`](https://github.com/sahil-shubham/bhatti/blob/main/docs/PLAN-bhatti-karkhana.md) (in the bhatti repo) for the full architecture.

## Layout

```
cmd/karkhana/        single binary; HTTP + WebSocket + embedded UI
pkg/
  bhatti/            typed Go client for bhatti's API
  eventbus/          internal pub/sub used by the canvas WS
  mission/           Mission, Agent, Event types
  canvas/            server-side canvas plumbing
ui/                  React + Vite + react-flow; built and embedded
```

The Elixir prototype lives at `Projects/symphana/elixir/` (renamed
locally from `karkhana`); we port from it as a reference.

## Getting started (POC)

The POC runs Go server + React dev UI side by side. Mock event
source — no bhatti dependency yet.

```bash
# Terminal 1: Go server
make dev-server

# Terminal 2: React dev UI
make dev-ui

# Open http://localhost:5173
```

POST a mission:

```bash
curl -X POST localhost:4000/api/missions \
  -H 'content-type: application/json' \
  -d '{"goal":"research the top 8 PM tools"}'
```

Watch the canvas; mock workers spawn, events stream, eventually
they "complete" with a mock output.

## Next steps

1. Replace the mock event source with a real bhatti integration
   (see `pkg/bhatti/client.go` — already shaped, just unused).
2. Add the AgentDriver port from `Karkhana.AgentRPC` (Elixir).
3. Add the driver agent (pi-rpc subprocess on host, with five
   Karkhana tools registered).

## License

Apache 2.0
