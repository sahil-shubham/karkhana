# Karkhana — The compositional supervisor

*Authors: Sahil Shubham*

Karkhana today is a research-agent wrapper that spawns workers, waits for
them, and synthesizes their output. The supervisor's vocabulary is
`spawn`, `wait`, `finish`. It treats bhatti like a generic VM service:
boot, run, destroy. Every primitive bhatti shipped over the last year —
snapshot-fork, publish, volumes, port-introspection, pause/resume —
sits unused.

This plan reshapes karkhana around bhatti's full primitive set. The
supervisor stops being a coordinator-of-LLMs and becomes a
composer-of-substrate. Workers are one primitive among many. Snapshots,
published URLs, shared volumes, and discovered ports become first-class
operands the supervisor reasons about and the operator sees on the
canvas. Mission output stops being a markdown blob and becomes *forkable
state* — live sandboxes, live URLs, live volumes — that the operator
can take ownership of after the mission ends.

Five pillars:

1. **Prompts move out of Go source into hot-reloadable templates.**
   Single biggest velocity multiplier; every other pillar depends on it.
2. **Recipes become declarative bhatti compositions.** Three at launch:
   `desktop-watch` (today's behaviour), `headless-dev` (new — fast
   shell, no GUI), `mixed`. Recipes specify image, tools, preamble,
   lifecycle hooks, network policy. Users add their own as YAML files.
3. **Bhatti primitives become first-class driver tools.**
   `snapshot_worker`, `fork_workers`, `publish_port`, `create_volume`,
   `attach_volume`, `list_worker_ports`, `pause_worker`, `resume_worker`.
   The driver preamble teaches when to use them.
4. **The canvas grows tile types for what the supervisor produces.** Live
   preview tiles (iframes of published URLs), volume tiles (file tree
   of shared FS). Both persist post-mission; the canvas becomes an
   archive of forkable artifacts.
5. **Two launch workflows that prove the wedge.** Workflow C: build +
   publish + view (one dev worker writes code, driver publishes,
   viewer-worker QAs, operator clicks the live URL). Workflow B: scout
   + snapshot + fork-N (one worker primes a state, supervisor
   snapshots, forks 8 ways for parallel comparison).

Each pillar is small in isolation. Together they make karkhana something
that *can only be built on bhatti.*

---

## Current state

Honest accounting of what's in main and what hurts.

### What works

- Single-canvas UX, driver-as-conversational-anchor, tick-driven
  supervisor loop, SQLite persistence with reattach.
- The 12 computer-use tools (screenshot, click, type, scroll, drag,
  `browser_eval`, `kk-browser` launcher) work well. CDP integration for
  fast structured extraction is a real wedge over screenshot-only
  competitors.
- Driver tools: `spawn_worker(s)`, `steer_worker`, `terminate_worker`,
  `ask_operator`, `report_progress`, `finish`, `write_note`,
  `read_notes`, `list_notes`. The blackboard pattern (write-only for
  workers, read-write for driver) reads cleanly.
- Bhatti integration on the spawn path: `Create`, `Publish` (port 6080
  only), `Exec`, file API for bake. Cold-boot to running pi agent in
  ~30s on `computer` image, ~2s on `kk-base`.

### What hurts

- **Both worker preambles (~250 lines combined) live in Go source.**
  Every prompt experiment is `go build` + restart. The single
  highest-leverage iteration tax on the project.
- **One worker recipe.** `agents.recipe` column exists; code hard-codes
  `"computer-use"`. Schema promises (`computer-use | host-driver |
  etc.`) unimplemented.
- **`spawn_worker(task: string)`.** One-dimensional contract. Driver
  can't say "this one needs a dev shell, not a desktop."
- **Curl is blocked globally for workers.** Catches the scraper
  anti-pattern; also catches `curl https://api.github.com/...`, tarball
  downloads, every API-shaped task. The cure is type-aware policy
  (per-recipe), not a softer regex.
- **Driver preamble defaults to fan-out.** For "research repo X" this
  produces 5 desktops scrolling the same README in parallel. The
  preamble doesn't model "different worker types for different
  sub-tasks of one root task."
- **Bhatti primitives unused beyond Create/Exec/Publish-for-VNC.**
  Snapshot, fork, volumes, port-discovery, pause/resume — all present
  in `pkg/bhatti/client.go`, none called from anywhere.
- **Mission output is markdown.** `finish(result)` produces an artifact
  row in SQLite. The sandboxes die. The operator gets a wall of text.
  Nothing forkable.
- **`cmd/karkhana/main.go` is 2971 lines.** Past the maintainability
  line; reviews and changes carry collateral risk.

The recurring failure case from real testing: **"research a github
project"** → driver spawns 5 desktop workers, each scrolls github.com
chromium-style, no one clones, no one runs the code, the operator
watches 5 identical README pages scroll past. **This plan's correctness
criterion is: that prompt produces one cloning worker and one viewing
worker, driver synthesizing both.**

---

## Design principles

**P1. The supervisor composes substrate.** A worker is a primitive. So
is a snapshot. So is a published URL. So is a volume. The driver's job
is to compose them. Today the driver only knows about workers; we fix
that by giving it tools for the rest.

**P2. Recipes are compositions, not just preambles.** A recipe declares:
image, resources, available tools, preamble template, network policy,
lifecycle hooks. Choosing a recipe is choosing a *composition shape*,
not just selecting a docker image. This makes recipes the natural
extension point for users who want to add their own.

**P3. Prompts are data.** Templates in `prompts/*.tmpl`. Watched in dev
mode. Parameterized by recipe and task. No more rebuild-to-tweak.

**P4. Policy follows recipe.** The curl block, allowed_http hosts,
available tools — set by recipe. Driver can refine per-task
(`spawn_worker(task, allow_http: ["api.github.com"])`) but cannot
exceed what the recipe permits. Security boundary is at the recipe
definition, not at the worker preamble.

**P5. The mission output is forkable state.** What survives a mission's
`finish()`: the artifact markdown (still), AND the sandboxes (paused,
not destroyed), AND the published URLs (alive for an operator-configurable
TTL), AND the shared volume (snapshotted). The operator can resume any
sandbox, fork it, mount the volume into a new one.

**P6. One creator across both layers means the API can be exactly what
we need.** If a primitive composition is awkward, fix bhatti, not
karkhana. (Out of scope for this plan; in scope as a posture for the
plans that follow.)

---

## 1. Prompts to templates

The blocker for everything else. Every preamble experiment today is a
`go build` + restart + re-spawn-worker cycle. Recipes need parameterised
preambles; you cannot parameterise a 250-line string literal living in
`wrapGoalWithDesktopContext`.

### 1.1 File layout

```
prompts/
  driver.tmpl                  the supervisor preamble (one file)
  worker.desktop-watch.tmpl    per-recipe worker preamble
  worker.headless-dev.tmpl
  worker.mixed.tmpl
  partials/
    blackboard.tmpl            shared: how to write_note + when
    completion.tmpl            shared: finish() / done() semantics
    bhatti_tools.tmpl          driver-only: snapshot/publish/volume idioms
```

`text/template` syntax. One context struct passed in:

```go
type PromptContext struct {
    Goal          string
    Recipe        Recipe          // resolved recipe object (see §2)
    Task          string          // for workers
    ParentMission string          // for workers
    AllowHTTP     []string        // per-task allow-list overrides
    Extras        map[string]any  // future-proof
}
```

Partials are included via `{{ template "blackboard" . }}`. This kills
the copy-paste between `desktop-watch` and `mixed` that would otherwise
emerge.

### 1.2 Hot reload

```
KARKHANA_DEV=1
```

When set:

- `pkg/prompts` watches `prompts/**` via `fsnotify`.
- On change, re-parses all templates atomically (parse into a new
  `*template.Template` tree, swap pointer under a mutex).
- The change applies to *the next spawn or re-prompt*. Already-running
  workers do not get re-preambled — that would change context mid-turn
  and corrupt sessions.
- A "prompts reloaded" event publishes to the WS bus so the operator
  sees the canvas confirm.

Without `KARKHANA_DEV=1`, templates are parsed once at startup.

### 1.3 Tests

Snapshot tests per template:

```go
// pkg/prompts/prompts_test.go
func TestDriverPromptStable(t *testing.T) {
    got := MustRender("driver", PromptContext{Goal: "research X"})
    cupaloy.SnapshotT(t, got)
}
```

Snapshots committed; a renamed variable or accidental whitespace shift
shows up in the diff. We will iterate on prompts daily; snapshot tests
keep accidental regressions out of main.

### 1.4 What lives in templates vs. code

In templates:
- The role framing ("you are a supervisor", "you are a worker on a
  desktop")
- Tool-use idioms (when to fan-out, when to scout)
- The completion contract (`finish()`, `done()`)
- Recipe-specific guidance (dev workers don't get the "use chromium"
  paragraph)

Stays in code:
- The list of *available* tools (registered in the pi extension)
- The recipe lookup (templates receive the resolved `Recipe` struct,
  they don't read YAML)
- Anything that needs typed validation

The split is "instructions to the LLM are data; instructions to the
runtime are code."

### 1.5 Migration

`wrapGoalWithDriverContext` and `wrapGoalWithDesktopContext` move to
`pkg/prompts`. The existing strings become the seed `driver.tmpl` and
`worker.desktop-watch.tmpl`. Behaviour-identical at first commit; *then*
we start changing them.

---

## 2. Recipes as YAML compositions

The schema is the API. Get it right, recipes proliferate cheaply.

### 2.1 Schema

```yaml
# recipes/headless-dev.yaml
name: headless-dev
description: |
  Fast headless shell for code work. Clone repos, run builds, grep,
  read files. No GUI. Auto-publishes any server the worker starts on
  ports 3000-9000.

# Bhatti substrate
image: kk-dev                           # bhatti image name (see §2.6 — pulled via
                                        # `bhatti image pull ghcr.io/...:kk-dev`).
resources:
  cpu: 2
  memory_mb: 2048
  timeout_secs: 1800

# Named bhatti secrets to inject at sandbox boot. The operator runs
# `bhatti secret set ANTHROPIC_API_KEY sk-...` once; karkhana never
# sees the value. Different recipes can request different secret
# sets (a dev recipe wants GH_TOKEN; a research recipe doesn't).
secrets:
  - ANTHROPIC_API_KEY
  - GH_TOKEN

# Pi-extension surface inside the sandbox
extensions:
  - /usr/local/share/karkhana/extensions/computer-use-cli/index.ts
                                        # bash, read, write, edit,
                                        # grep, find, write_note,
                                        # done. NO screenshot/click.

# Preamble
prompt: worker.headless-dev             # resolves to prompts/worker.headless-dev.tmpl

# Network policy (overrides per-task possible via spawn_worker args)
allow_http:
  - api.github.com
  - raw.githubusercontent.com
  - registry.npmjs.org
  - pypi.org
  - github.com                          # for git clone
  - "*.docker.io"                       # if we ever do containers in containers
deny_curl_to_others: true               # the regex block from today,
                                        # but scoped per-recipe

# Lifecycle hooks
auto_publish:
  port_range: [3000, 9000]              # bhatti.ListeningPorts → Publish
  alias_template: "{worker_short}-{port}"
  ttl_secs: 900                         # unpublished after mission idle

idle:
  pause_after_secs: 300                 # bhatti.Pause
  stop_after_secs: 1800                 # bhatti.Stop (snapshot to disk)

# Watchability — which canvas tile shapes apply
canvas:
  primary_tile: log                     # not desktop (no GUI)
  show_published_urls: true             # render preview tiles for any
                                        # auto-published port
```

### 2.2 The three recipes at launch

| Recipe          | Image    | CPU/RAM | Tools                              | Primary tile | Use case                           |
|-----------------|----------|---------|------------------------------------|--------------|------------------------------------|
| `desktop-watch` | kk-base  | 2/4096  | computer-use + bash                | desktop      | research, QA, click-through        |
| `headless-dev`  | kk-dev   | 2/2048  | bash, read, write, edit, grep, find, git, gh | log + auto-published URLs | code, build, run     |
| `mixed`         | kk-base  | 2/4096  | both                               | desktop + log| exploratory, when shape is unclear |

`kk-dev` is a new image. Authored as a normal Dockerfile in
`images/kk-dev/Dockerfile`, built and pushed to
`ghcr.io/sahil-shubham/karkhana-kk-dev:latest` from CI on tag. The
image carries Debian + node + python + go + rust + git + gh +
ripgrep + jq + pi pre-installed (~600MB). Cold boots in ~1s; ~10×
faster than `kk-base` because no chromium/xfce. See §2.6 for the
image authoring + distribution story.

### 2.3 Resolution and validation

```go
// pkg/recipe
type Recipe struct {
    Name         string
    Image        string
    Resources    Resources
    Extensions   []string
    Prompt       string                  // template name
    AllowHTTP    []string
    DenyCurl     bool
    AutoPublish  *AutoPublishPolicy
    Idle         *IdlePolicy
    Canvas       CanvasHints
}

func Load(dir string) (*Registry, error) {
    // reads recipes/*.yaml, validates against schema,
    // returns a Registry with .Get(name) and .List()
}
```

Validation at startup; karkhana refuses to boot if any recipe is
malformed. Same `KARKHANA_DEV=1` watcher picks up recipe changes for
hot reload — though, as with prompts, only new spawns see the new
recipe.

### 2.4 The driver picks a recipe per worker

`spawn_worker` and `spawn_workers` gain a `recipe` field:

```typescript
spawn_worker({
  task: "clone X/Y, summarize architecture, write_note('arch', …)",
  recipe: "headless-dev",
  allow_http: ["api.anthropic.com"],     // optional per-task addition
})

spawn_workers({
  tasks: [
    { task: "clone X/Y, run tokei, summarize", recipe: "headless-dev" },
    { task: "open https://X.github.io, screenshot landing", recipe: "desktop-watch" },
  ]
})
```

The driver preamble (now a template, see §1) teaches the choice:

```text
## Picking a recipe

You have three recipes available. The recipe choice fixes the worker's
shape — its image, its tools, its preamble, and its network policy.

  desktop-watch:  Use for visible UI work. Research a marketing site.
                  QA a published preview. Anything where SEEING is the
                  point.

  headless-dev:   Use for code work. Cloning repos, reading source,
                  running builds, hitting APIs from the shell. No GUI.
                  Much faster boot. The operator watches the LOG tile,
                  not a desktop.

  mixed:          Use only when you genuinely don't know which shape
                  fits. Most tasks resolve to one of the two above.

Bad pattern: spawning 5 desktop-watch workers to "research the github
repo X/Y." That gives you 5 desktops scrolling the same readme. The
right shape is one headless-dev worker (clones, greps, summarizes
architecture) plus one desktop-watch worker (looks at the website, the
docs site, the marketing claims).
```

This single section is what fixes the github-research failure case.

### 2.5 User-defined recipes (preview)

`recipes/` is a flat directory and karkhana loads every `*.yaml` in it.
Operators can drop their own:

```yaml
# recipes/datasci.yaml
name: datasci
image: my-datasci                       # name resolved on this user's bhatti
                                        # (likely pulled from their own ghcr.io
                                        # via `bhatti image pull`)
secrets:
  - JUPYTER_TOKEN
extensions:
  - /opt/karkhana/extensions/computer-use-cli/index.ts
  - /opt/karkhana/extensions/jupyter/index.ts        # user-provided
prompt: worker.datasci
...
```

We do not need a recipe-marketplace at launch. The point is the
extension surface exists, is documented, and is the natural shape for
contributions when karkhana goes OSS.

---

### 2.6 Images via bhatti, not bake scripts

Bhatti already has `POST /images/pull` (async OCI pull, dedup by
digest, idempotent) and `bhatti image pull <ref> --name <local>`.
Karkhana piggy-backs on it; we do **not** maintain a parallel
bake-images-via-bhatti-file-API workflow.

**Image authoring loop:**

```
images/kk-dev/
  Dockerfile                 standard multi-stage Dockerfile
  README.md                  what's in it and why
  .github/workflows/         CI: build, push to ghcr.io on tag
```

**First-run operator step (one time per bhatti host):**

```bash
bhatti image pull ghcr.io/sahil-shubham/karkhana-kk-dev:latest --name kk-dev
bhatti image pull ghcr.io/sahil-shubham/karkhana-kk-base:latest --name kk-base
```

Karkhana checks at startup that every recipe's `image:` resolves to a
local bhatti image. If not, it prints the exact `bhatti image pull`
command the operator needs to run — not an attempt at auto-pull,
because OCI pull is an operator-visible action and we don't want
karkhana minting public-registry traffic on the operator's behalf
without consent.

**Why this over the existing bake-image.sh:**

- Standard Dockerfile authoring; nothing karkhana-specific to learn.
- Versionable (tags), digest-pinnable, signable (cosign) if needed.
- CI/CD friendly: push to ghcr.io on tag, done.
- OSS contributors author and distribute their own variants via any
  OCI registry.
- Deduplicates with bhatti's own image story; no parallel mechanism
  to maintain.

`scripts/bake-image.sh` for kk-base is kept around for now as a
fallback for operators who don't want to depend on ghcr.io, but it's
documented as the secondary path. The Dockerfile is canonical.

---

### 2.7 Secrets via bhatti, not env-var smuggling

Today `piEnvFromHost()` in `cmd/karkhana/main.go` reads
`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`,
`OPENROUTER_API_KEY`, `GH_TOKEN` from karkhana's own environment and
injects them as clear-text `env:` entries into every sandbox spec.
This means:

- The API key value is recorded in every `sandbox.created` event
  (we log spec on creation).
- The karkhana process must itself hold the keys, which complicates
  running it under a service manager.
- Adding a new key is a karkhana code change.
- The keys are pushed into every worker, regardless of whether that
  worker actually needs them.

Bhatti has had `/secrets` (age-encrypted, per-user) all along, and
`SandboxSpec.SecretNames` is already in `pkg/bhatti/types.go` — just
never populated.

**New flow:**

```
# One-time operator setup (per bhatti host):
bhatti secret set ANTHROPIC_API_KEY sk-ant-...
bhatti secret set GH_TOKEN ghp_...

# Recipes declare which named secrets they need:
secrets:
  - ANTHROPIC_API_KEY
  - GH_TOKEN

# Karkhana, when spawning a worker, passes:
SandboxSpec{
  Image:       recipe.Image,
  SecretNames: recipe.Secrets,         // <-- the only thing referencing keys
  ...
}
# Bhatti decrypts and injects at boot. Karkhana never sees values.
```

Karkhana's own startup gets simpler: it doesn't need API keys in its
env at all. It orchestrates; bhatti holds the keys.

**`piEnvFromHost()` is deleted.** The driver (which runs on the
karkhana host, not in a bhatti sandbox) is the one exception — it
needs `ANTHROPIC_API_KEY` in its subprocess env. For the driver we
add a single bootstrap path: karkhana reads `ANTHROPIC_API_KEY` from
its own environment for the driver subprocess only, with a clear
doc-comment that this is the one secret karkhana itself holds. (A
future plan can eliminate even this by running the driver inside
a bhatti sandbox; not v0.7.)

**Recipe-scoped secrets is a real feature.** A `desktop-watch`
research recipe doesn't need `GH_TOKEN`; a `headless-dev` recipe
does. Recipes declare what they need; bhatti injects exactly that
set. No more all-keys-everywhere.

---

## 3. Bhatti primitives as driver tools

The driver's mental model expands from "I have workers" to "I have
workers, snapshots, published URLs, volumes, and ports — all of which I
can compose."

### 3.1 Tool surface additions

| Tool                    | Args                                                      | Bhatti call(s)            | Returns                  | Notes                                      |
|-------------------------|-----------------------------------------------------------|---------------------------|--------------------------|--------------------------------------------|
| `spawn_worker`          | task, recipe?, shared_volume?, fork_from?, allow_http?    | Create or RestoreSnapshot | worker_id                | unifies with fork_workers                  |
| `spawn_workers`         | tasks[], (per-task fields same as above)                  | parallel Creates/Restores | worker_ids[]             | parallel; cheap fan-out                    |
| `snapshot_worker`       | worker_id, note?                                          | Checkpoint                | snapshot_id              | does NOT terminate the worker              |
| `fork_workers`          | snapshot_id, tasks[]                                      | RestoreSnapshot × N       | worker_ids[]             | ~3s per restore vs ~30s cold boot          |
| `publish_port`          | worker_id, port, alias?, ttl_secs?                        | Publish                   | url                      | tile appears on canvas                     |
| `unpublish_port`        | rule_id                                                   | DELETE /publish/:rule     | ok                       | cleanup                                    |
| `list_worker_ports`     | worker_id                                                 | ListeningPorts            | [{port, process}]        | introspection                              |
| `create_volume`         | name?                                                     | Volume.Create             | volume_name              | name defaults to `vol_<mission_id>`        |
| `attach_volume`         | worker_id, volume, mount_path                             | (set at next spawn)       | ok                       | re-attach by destroying+respawning worker  |
| `snapshot_volume`       | volume, note?                                             | Volume.Snapshot           | snapshot_id              | for handoff to the operator post-mission   |
| `pause_worker`          | worker_id                                                 | Pause                     | ok                       | RAM held, no CPU                           |
| `resume_worker`         | worker_id                                                 | Resume                    | ok                       | ~50ms                                      |

All routed via the existing `/internal/driver/:id/<tool>` HTTP path
with bearer-token auth. Each is a thin shim over a method we already
have on `pkg/bhatti/client.go`.

### 3.2 Tool semantics — selected detail

**`snapshot_worker(worker_id)`** — calls `bhatti.Checkpoint`. The worker
keeps running; the snapshot is a side-effect. The supervisor uses this
to bookmark a primed state ("chromium launched, allow-cookies clicked,
logged in to the dashboard") so subsequent forks start from there.
Persisted in karkhana's `fork_snapshots` table (already in schema,
unused).

**`fork_workers(snapshot_id, tasks)`** — bhatti's
`RestoreSnapshot` with N specs. Each restore mints a new agent row,
inherits the parent's recipe (so prompts and policy carry over), runs
the new task as the first prompt. Returns the list of worker_ids
synchronously after all N have *booted* (not after they finish their
work — that's still tick-driven).

**`publish_port(worker_id, port, alias?)`** — calls `bhatti.Publish`,
gets back a public URL. Karkhana stores a `published_ports` row
(new table — see §6), emits a `port.published` event, and the canvas
materialises a **preview tile** anchored to the worker. The driver
gets the URL string back; it may include it in `finish()` artifacts.

**`create_volume(name?)`** — `bhatti.CreateVolume`. Volumes are
mission-scoped by default (`name` defaults to `vol_<mission_id>`). To
attach a volume to a worker, the driver must either:

  (a) call `attach_volume` *before* `spawn_worker` (we hold the
      mount-path in mission state and the next spawn-with-shared_volume
      picks it up), or

  (b) call `spawn_worker(..., shared_volume="vol_msn_abc")` directly.

Attaching to an *already-running* worker requires sandbox restart in
bhatti's current model. For v1, we just say so in the tool description.

**`pause_worker(worker_id)`** — `bhatti.Pause`. Worker process freezes
in place; the pi-rpc WebSocket disconnects gracefully (we send a
"paused" event so the canvas dims the tile). On the next operator
follow-up that targets this worker, the driver calls `resume_worker`
first.

### 3.3 Driver preamble additions

A new section in `prompts/driver.tmpl`:

```text
## Composing primitives

Workers are not the only thing you can spawn. You can also:

- snapshot_worker: take a checkpoint of a running worker (chromium
  primed, login complete, server running). Use BEFORE branching.
- fork_workers: from a snapshot, spawn N copies in parallel. Each one
  starts from the EXACT state at snapshot time. ~3s per fork vs ~30s
  per cold boot. Use this for fan-outs that share setup work.
- publish_port: take a worker that has a server running on port P and
  make it reachable at https://<alias>.bhatti.sh. The operator can
  click that URL in their own browser; you can spawn a viewer worker
  to QA it.
- create_volume / attach_volume: give workers a shared filesystem.
  One worker drops screenshots and PDFs in /workspace/shared; another
  reads them. Survives the mission.
- pause_worker / resume_worker: freeze idle workers without losing
  state. The operator may come back hours later; their workers are
  still where they left off.

These composes — they are the difference between karkhana and every
hosted research-agent. Use them.
```

### 3.4 The unified spawn model

`spawn_worker` becomes the single entry point — whether the worker is
cold-booted or restored from a snapshot is determined by whether
`fork_from` is set. This collapses what would otherwise be two parallel
code paths:

```typescript
// Cold boot:
spawn_worker({ task: "...", recipe: "headless-dev" })

// Fork from snapshot:
spawn_worker({ task: "...", recipe: "headless-dev", fork_from: "snap_abc" })

// Bulk fork (the Workflow B shape):
spawn_workers({
  fork_from: "snap_abc",
  tasks: [{ task: "explore url 1" }, { task: "explore url 2" }, ...]
})
```

`fork_from` overrides recipe.image (you can't fork into a different
image), but recipe.prompt and recipe.allow_http and per-task `task`
all apply normally.

### 3.5 What's still routed via /internal/driver/

All new tools land via the existing HTTP callback path. The
`driver-tools` pi extension grows by ~10 thin wrappers; the karkhana
server grows by ~10 handlers in
`pkg/server/internal_driver.go`. No new transport, no new auth model.

---

## 4. Auto-publish on listening-port discovery

The single feature that makes Workflow C feel automatic instead of
manual. Without it, the driver has to know what port the dev worker
opened and call `publish_port` explicitly. With it, ports are
discovered and surfaced.

### 4.1 Mechanism

A periodic poller (`pkg/ports/discoverer.go`) walks every running
worker that belongs to a recipe with `auto_publish.port_range` set.
For each worker:

1. Call `bhatti.ListeningPorts(worker.sandbox_id)`. Cached for 5s to
   avoid stampedes; cheap on bhatti's side.
2. Diff against the last poll for this worker.
3. For each *newly listening* port in the recipe's `port_range`:
   - Call `bhatti.Publish(sandbox_id, port, alias)` where alias =
     `auto_publish.alias_template` rendered.
   - Insert a `published_ports` row.
   - Publish two events:
     - `port.detected` (just informational, for the log tile)
     - `port.published` (carries the URL, triggers the preview tile on
       the canvas, also injected into the next driver tick as a signal)
4. For each port that *stopped* listening:
   - Call `bhatti.Unpublish(rule_id)`.
   - Publish `port.unpublished` event.

### 4.2 Tick injection

When a new port is published mid-mission, the tick prompt gains a
section:

```text
[karkhana tick · reason=port_published]

Since your last check-in:
- worker w_abc12345 started listening on :5173 (vite dev server)
  → published at https://abc1-5173.bhatti.sh
```

The supervisor now has actionable knowledge: it can spawn a viewer
worker pointed at the URL, or include the URL in its narration for the
operator to click, or roll it into `finish()`.

### 4.3 Knobs

Per recipe:
- `port_range: [low, high]` — bound; defaults to nothing (no
  auto-publish).
- `process_filter: ["node", "python", "go", ...]` — optional, skip
  ports opened by ignored process names.
- `ttl_secs` — published URLs auto-unpublish after this many seconds
  of mission idle (no ticks, no operator messages). Default 900 (15
  min).

### 4.4 Safety

The 0.0.0.0 case is the one to mind: a worker that opens a port on
0.0.0.0 instead of 127.0.0.1 is fine for bhatti (sandboxes are
isolated), but means the auto-published URL serves whatever the worker
chose to serve there. This is fine for trusted operators; matters when
karkhana.dev playground launches (covered in a separate plan).

---

## 5. Canvas tile types

The supervisor produces things that aren't workers. The canvas needs to
show them.

### 5.1 New tile types

**Preview tile.** Live iframe of a published URL. Width matches a
worker tile (~520px); shows the URL in the header, a status dot
(reachable/unreachable, polled every 10s), and a context menu with:

- Open in new tab
- Copy URL
- Unpublish (operator confirmation)
- Fork the backing sandbox (calls `bhatti.RestoreSnapshot` from the
  worker's current state, gives the operator their own copy via SSH/CLI)

Edge: dashed from the producing worker to the preview tile.

**Volume tile.** File-tree view of a shared volume. Polls
`bhatti.Exec(any_attached_worker, "find /workspace/shared -maxdepth 3
-printf …")` every 5s while the volume is mounted in at least one
running worker. Shows file count, total size, last-modified.
Context menu:

- Browse (expands a tree)
- Download a file (streams through karkhana from a side-car exec)
- Snapshot the volume (for handoff)

Edge: solid from the volume tile to each worker that has it mounted.

**Artifact tile.** Already exists in main from v0.6's `finish()`.
Stays. Now linked from any preview tiles or volume tiles the artifact
references in its markdown body (auto-detected URLs).

### 5.2 Persistence

All three tile types persist in the canvas after `finish()`. The
operator can revisit the mission a week later and the preview tiles
still reflect whether the URLs are reachable (probably not, by then —
the recipe's `ttl_secs` will have unpublished them). The tile shows the
historical URL with a "republish" affordance: clicking it resumes the
backing worker (paused or stopped) and re-runs `publish_port`. Round
trip ~3-5s on the warm path.

### 5.3 Implementation notes

`ui/src/components/PreviewTile.tsx` and `VolumeTile.tsx` as new files,
~200 lines each. The existing `AgentTile.tsx` (1271 lines, too big — a
v0.8 refactor target) is not touched by this plan; preview/volume
tiles are independent components.

Reachability polling: a single timer at the canvas level
fans out HEAD requests every 10s, batched. Cheap.

---

## 6. Data model additions

Three new tables. Migration in `pkg/store/migrations/`.

```sql
-- A bhatti snapshot karkhana has taken. The fork_snapshots table in
-- the v0.6 schema already exists; this is a rename/clarification of
-- usage: fork_snapshots holds bhatti checkpoint IDs that the driver
-- might fan-out from.

ALTER TABLE fork_snapshots ADD COLUMN
    bhatti_snapshot_id TEXT;             -- the ID bhatti returned
ALTER TABLE fork_snapshots ADD COLUMN
    source_worker_id TEXT REFERENCES agents(id);

-- A public URL karkhana has published via bhatti.
CREATE TABLE published_ports (
    id              TEXT PRIMARY KEY,    -- pub_<12hex>
    mission_id      TEXT NOT NULL REFERENCES missions(id),
    agent_id        TEXT NOT NULL REFERENCES agents(id),
    port            INTEGER NOT NULL,
    alias           TEXT NOT NULL,
    public_url      TEXT NOT NULL,
    bhatti_rule_id  TEXT NOT NULL,
    auto            INTEGER NOT NULL DEFAULT 0,    -- 1 if auto-discovered
    created_at      TEXT NOT NULL,
    unpublished_at  TEXT,                          -- null = still live
    ttl_secs        INTEGER,
    canvas_x        REAL,                          -- preview tile position
    canvas_y        REAL
);
CREATE INDEX idx_pubports_mission ON published_ports(mission_id);
CREATE INDEX idx_pubports_agent   ON published_ports(agent_id);
CREATE INDEX idx_pubports_live    ON published_ports(unpublished_at) WHERE unpublished_at IS NULL;

-- A bhatti persistent volume karkhana has created.
CREATE TABLE mission_volumes (
    id            TEXT PRIMARY KEY,      -- vol_<12hex>
    mission_id    TEXT NOT NULL REFERENCES missions(id),
    bhatti_name   TEXT NOT NULL UNIQUE,  -- e.g. vol_msn_abc123_workspace
    note          TEXT,
    created_at    TEXT NOT NULL,
    canvas_x      REAL,
    canvas_y      REAL
);
CREATE INDEX idx_volumes_mission ON mission_volumes(mission_id);

-- Per-worker volume mounts (many-to-many)
CREATE TABLE agent_volume_mounts (
    agent_id    TEXT NOT NULL REFERENCES agents(id),
    volume_id   TEXT NOT NULL REFERENCES mission_volumes(id),
    mount_path  TEXT NOT NULL,
    readonly    INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (agent_id, volume_id)
);
```

The `agents.recipe` column (already in schema) finally gets used; the
hard-coded `"computer-use"` literal in `spawnWorker` is replaced by the
recipe.Name from the spawn call.

---

## 7. Workflow C — build, publish, view

**Goal:** "Take this short spec — a landing page for a fictional
SaaS — and build me an MVP I can play with."

The 2-3 minute demo that proves Karkhana does something no hosted
research-agent can.

### 7.1 Storyline

```
t=0       Operator right-clicks canvas, types the goal. Driver tile
          materialises.

t=0+2s    Driver thinks: "this is build-then-look. Two workers: one
          dev, one viewer. I'll spawn the dev first."

          spawn_worker({
            recipe: "headless-dev",
            shared_volume: "msn_workspace",
            task: "Implement <spec>. Use vite + react. Run the dev
                   server on :5173. When it's serving, write_note
                   ('preview_ready', port=5173). Continue iterating
                   on the design until the spec is satisfied. Drop
                   any reference images you grab at /workspace/shared."
          })

t=0+5s    Dev worker boots (kk-dev image, ~3s). Log tile appears
          beneath the driver. Worker starts cloning a vite starter.

t=0+45s   Log shows `npm install` finishing, `vite` starting.
          Auto-publish poller notices :5173 on the dev worker.

t=0+47s   Preview tile materialises on the canvas next to the dev
          log, showing the live vite app (initial scaffolding).

          Tick fires:
            "worker w_abc12 started listening on :5173 → published at
             https://w-abc12-5173.bhatti.sh"

t=0+50s   Driver reacts: "Preview is live. I'll spawn a viewer to QA
          the first cut."

          spawn_worker({
            recipe: "desktop-watch",
            task: "Open https://w-abc12-5173.bhatti.sh in chromium.
                   Screenshot it. Compare to the spec at <ref>.
                   write_note('qa_round_1', findings)."
          })

t=0+90s   Viewer's desktop tile fills with the loading vite app.
          Operator watches both tiles live: dev log scrolling on the
          left, real chromium rendering of the page on the right.

t=1+10s   Viewer writes three QA notes: "missing hero CTA", "form
          field labels overlap on mobile", "footer references the
          wrong domain."

t=1+15s   Tick. Driver: "QA has 3 findings. I'll steer dev to fix and
          re-check."

          steer_worker(dev, "QA found 3 issues (see notes qa_round_1).
                             Fix and the preview will hot-reload.")

t=1+45s   Dev worker iterates. Vite hot-reloads the preview tile (no
          republish needed; the URL points to a live server).

t=2+15s   Driver: "I think we're close. Re-running QA."
          terminate_worker(viewer_1, "round 1 complete")
          spawn_worker({ recipe: "desktop-watch", task: "Re-QA the
                         same URL." })

t=2+45s   Viewer 2 writes 'qa_round_2': "all 3 issues fixed; one new
          one — copy on the pricing card runs off the right edge at
          1024px."

t=3+00s   Driver steers dev once more. Dev fixes.

t=3+45s   Viewer 3: "looks good — matches the spec."

t=4+00s   Driver:
            snapshot_worker(dev, note="MVP complete")
            snapshot_volume(msn_workspace, note="MVP source + assets")
            finish(
              result: "MVP complete. Live preview:
                       https://w-abc12-5173.bhatti.sh (active 15min).
                       Source snapshot: snap_xyz789. To fork:
                       `bhatti sandboxes restore snap_xyz789`.",
              title: "SaaS landing page MVP"
            )

t=4+05s   Artifact tile appears. Driver enters idle. Operator clicks
          the preview tile, the live URL opens in their own browser,
          they play with what the agents built.

t=∞       Operator can return next day. Preview URL has been
          unpublished (TTL hit). Preview tile shows "republish?". One
          click → driver resumes the dev worker (was paused after
          idle hit), re-publishes the port, preview is live again in
          ~5s.
```

### 7.2 What this proves

Nothing in this storyline could happen on hosted-sandbox-of-the-month.
Specifically:

- The preview URL is on **your domain** routing to **your sandbox**, no
  third-party preview-deployment service.
- The dev sandbox **doesn't die** when the agent finishes; it's paused.
  The operator's "fork this" affordance is a button, not a re-run.
- The shared volume **carries assets between dev and viewer** without
  copy-pasting through markdown.
- The supervisor **composes substrate, not LLMs.** The interesting
  decisions are which primitives to compose in what order.

### 7.3 Reusable shape

Workflow C is one instance of a pattern: **producer → publish →
consumer**. Other prompts of the same shape:

- "Write an API in FastAPI from this spec; spawn a viewer to hit each
  endpoint with curl and report responses."
- "Generate three dashboard variants; publish each; have a viewer rank
  them."
- "Build a static site from these markdown files; serve it; let me
  click around."

All of these compose the same five primitives:
spawn(dev) → auto-publish → spawn(viewer) → iterate via steer →
finish-with-forkable-state.

---

## 8. Workflow B — scout, snapshot, fork-N

**Goal:** "Compare how 8 different SaaS pricing pages look at scroll
depth 50%, in dark mode."

This was v0.5's headline. Deferred in v0.6. Cheap to land now that
snapshot+fork are first-class tools.

### 8.1 Storyline

```
t=0       Operator types goal. Driver tile materialises.

t=0+2s    Driver: "8 pages, same prep work each (chromium, dark mode,
          window size). I'll prime once, snapshot, fork 8."

          spawn_worker({
            recipe: "desktop-watch",
            task: "Open chromium to about:blank. Use the OS
                   dark-mode toggle. Resize window to 1440x900. Then
                   call done()."
          })

t=0+8s    Scout worker primes the state and terminates politely.

t=0+9s    Driver: snapshot_worker(scout_id, note="dark-mode chromium
                                   primed @ 1440x900")
          → snap_abc

t=0+12s   Driver: fork_workers(snap_abc, [
            { task: "Navigate to https://X. Scroll to 50%.
                     screenshot. write_note('pricing_X', …) call done()." },
            ...8 entries...
          ])

t=0+20s   8 worker tiles materialise in a 4×2 grid below the driver.
          Each one continues from the EXACT state of the scout
          (chromium open, dark mode on, window 1440x900). The first
          screen shows each navigating to its assigned URL.

t=0+30s   Workers write notes. Tick stream:
            "worker_1 wrote 'pricing_asana' (3 paragraphs)"
            "worker_2 wrote 'pricing_notion' ..."
            ...

t=0+55s   All 8 finished. Driver:
            read_notes("pricing_*")
            ... composes comparison table ...
            finish(result: <markdown table>, title: "8 pricing pages
                                                     compared")

Total time: ~1 minute. Compared to:
  - 8 cold boots: ~30s × 8 (serial waste) or ~30s wall (parallel boots,
    but every one repeats the dark-mode + resize prep)
  - Hosted alternative: not possible. Browserbase, E2B, no one
    publishes a snapshot-fork primitive.
```

### 8.2 What this proves

The economics. A cold-boot fan-out of 8 desktops costs 8 × the boot
work. A scout-snapshot-fork-8 costs 1 × boot work + 8 × restore (~3s
each). On the hardware bhatti deploys to (Pi 5, Graviton, bare metal),
this is the difference between "expensive to demo" and "trivial."

It also proves karkhana isn't just a research wrapper. Workflow B's
output is a comparison table — same shape as ChatGPT deep research.
The wedge is *not the output*; it's the **substrate path** to get
there, and the resulting compute cost. We commit to bench numbers (in
bhatti's plan), not in this one.

---

## 9. Out of scope / anti-goals

Things deliberately *not* in this plan, with reasons.

- **Sub-drivers (workers spawning workers).** v0.9. Composition story
  is interesting but premature — we need to land the first-class
  primitive tools first and watch operators use them.

- **Worker-level read of the blackboard.** I argued for this in the
  first review. Reverting that: with shared volumes (§3, §5), workers
  can pass artifacts to each other through the filesystem. The notes
  table is for *driver synthesis*, not peer coordination. Cleaner
  separation. Reconsider if a recipe genuinely needs peer notes.

- **Typed artifacts / typed notes.** Markdown is enough for v0.7. v0.9.

- **The `cmd/karkhana/main.go` 2971-line split.** Painful but not
  blocking. Folded into the self-host kit plan; that plan rewrites
  for OSS readability anyway.

- **Auth, cost caps, abandoned-mission cleanup.** Self-host kit plan.

- **Bench numbers.** Bhatti's plan.

- **Multi-mission shared volumes.** v0.9 if anyone asks.

- **Recipe marketplace, hosted recipe registry.** v1.x.

- **Operator memory across missions** ("remember I said I prefer
  shadcn"). v0.9.

- **The driver as a "writer" instead of "synthesiser"** (e.g. driver
  produces drafts and revises). Different mode; explore after v0.7
  lands.

- **MCP for any of this.** Pi extensions remain in-process; the case
  in v0.6 §2.7 still holds.

- **Postgres migration.** Single-operator single-host. SQLite WAL is
  fine.

Things actively *anti*:

- **Adding more tools to fix the "researching github" failure.** The
  fix is recipe selection + headless-dev preamble. Do not add
  `clone_repo`, `read_repo_file`, `repo_summary`. The model knows git
  + rg; what it lacked was permission and recipe.

- **Generalising the curl block.** Push it down per-recipe (P4). Do
  not relax the global block while desktop-watch is the only recipe;
  do not extend it to other tools (the block is a recipe policy, not
  a tool feature).

- **Synchronous fan-out tools.** `fork_workers` returns after restore
  but BEFORE any forked worker finishes work. Ticks handle the rest.
  We are not reintroducing `wait_for_workers`.

---

## 10. Phasing

Calendar-week granularity, ~2 calendar weeks total. Assumes the
iteration rhythm from v0.6.

### Week 1 — Prompts + recipes (the iteration unlock)

```
Day 1   Extract preambles to prompts/*.tmpl. Behaviour-identical commit.
        Add pkg/prompts with render + hot-reload.
Day 2   Snapshot tests; CI green; KARKHANA_DEV=1 works.
Day 3   Recipe schema (pkg/recipe). Three recipes wired:
          desktop-watch (= today)
          headless-dev (= new, kk-dev image)
          mixed
        agents.recipe finally populated end-to-end.
Day 4   Author images/kk-dev/Dockerfile. Build + push to
        ghcr.io/sahil-shubham/karkhana-kk-dev:latest from CI.
        Karkhana startup check that recipe.image resolves to a local
        bhatti image; emits the exact `bhatti image pull` command in
        the error if not.
        Secrets refactor: delete piEnvFromHost(); populate
        SandboxSpec.SecretNames from recipe.Secrets; document the
        one-time `bhatti secret set ...` step.
Day 5   Write worker.headless-dev.tmpl + driver.tmpl additions
        (recipe-picking section). Manual end-to-end test on the
        github-research failure case; verify driver picks
        headless-dev + desktop-watch instead of 5× desktop-watch.
```

End of week 1: the failure case is fixed; karkhana is iterable on
prompts in seconds, not minutes; OSS contributors can add recipes.

### Week 2 — Primitives, canvas, demos

```
Day 6   New driver tools: snapshot_worker, fork_workers, publish_port
        (the three Workflow B/C critical path).
        Tables: published_ports, mission_volumes,
        agent_volume_mounts.
Day 7   create_volume, attach_volume; shared_volume param on
        spawn_worker; mount path inside sandbox.
Day 8   Auto-publish poller (pkg/ports/discoverer.go). Tick injection
        for port.published. Preview tile component on the canvas.
Day 9   pause_worker / resume_worker tools. Volume tile component on
        the canvas. Reachability polling for preview tiles.
Day 10  Workflow C end-to-end. Record 90s video.
        Workflow B end-to-end. Record 60s video.
        Update README + landing page (links to the videos).
```

End of week 2: karkhana is a compositional supervisor. Two demos. Two
videos. Ready for the self-host kit plan.

### Slack

~25% buffer assumed. If kk-dev image bake reveals a bhatti template
quirk, or auto-publish polling needs back-pressure tuning, push the
volume tile to a v0.7.1 follow-up.

---

## What comes after

Not in this plan, but the natural next moves once it lands:

- **Self-host kit + OSS readiness.** Single-binary distribution,
  `karkhana.yaml`, auth, cost caps, recipe-authoring guide. The plan
  that makes karkhana give-it-to-anyone shaped. Has the
  `cmd/karkhana/main.go` split and the `AgentTile.tsx` decomposition
  folded in as cleanup-during-rewrite.

- **karkhana.dev playground.** Trial tokens, curated example prompts,
  conversion flow. Depends on bhatti's trial-tenant primitives plan
  (your concern, not in this doc).

- **Sub-drivers, typed artifacts, operator memory.** Demand-driven;
  none on the critical path.

- **The driver as a more-than-supervisor** (writer, debugger,
  reviewer — each with its own prompt + tool slice). Probably the
  long-term direction once recipes are proven as the right
  abstraction.

The shape of all of those is "more composition on the same primitive
set," which is the whole bet. We don't add primitives lightly.
