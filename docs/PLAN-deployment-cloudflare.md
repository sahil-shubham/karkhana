# Karkhana — Cloudflare deployment kit

*Authors: Sahil Shubham*

Karkhana is a single Go binary running alongside a bhatti host. It
serves HTTP + WebSockets + a same-origin KasmVNC proxy on one port,
and embeds the React UI. That shape — a stateful daemon next to
bhatti — does not fit Cloudflare Pages or Workers as a host. It does
fit very well behind Cloudflare's tunnel + access layer, with
Cloudflare hosting only what genuinely benefits from edge delivery
(the marketing site, future Turnstile gating).

This plan is the concrete deployment path for karkhana.dev and the
shape that ships in the self-host kit as the recommended Cloudflare
recipe. Other shapes (raw systemd, docker-compose, exposed port +
caddy) belong in the self-host kit plan; this document is
Cloudflare-specific.

Three deployments, three subdomains:

```
karkhana.dev          Cloudflare Pages         marketing + docs (static)
app.karkhana.dev      Cloudflare Tunnel        karkhana itself, gated by Access
play.karkhana.dev     Cloudflare Tunnel        future: public playground,
                                               gated by Turnstile (deferred)
```

The app subdomain is the only one this plan implements end-to-end.
Marketing site lands later as part of the OSS launch. The playground
shape is sketched at the end so it composes cleanly when we add it.

---

## Current state

- `karkhana.dev` is registered, DNS on Cloudflare. No subdomains in
  use yet.
- karkhana binary runs on the bhatti host (a Pi 5 / Graviton box /
  bare-metal) listening on `:4000`.
- No public exposure today; only reachable via SSH-tunnel for
  development.
- No auth in karkhana itself (the v0.6 §4 hardening item, still
  open). Anyone on `:4000` can dispatch missions and spend the
  bhatti credit.

What we want at the end of this plan:

- `app.karkhana.dev` resolves to karkhana via a Cloudflare Tunnel,
  with no public ports on the bhatti host.
- An allowlist of operator emails can sign in via Cloudflare Access
  (Google OAuth, GitHub OAuth, or email-OTP) and reach the app.
- WebSocket streaming for the canvas event bus + KasmVNC iframe
  proxy works through the tunnel.
- No auth code in karkhana itself. Cloudflare Access is the auth
  layer; karkhana trusts the JWT header Access sets.

---

## Design principles

**D1. Cloudflare is auth + ingress, not compute.** Karkhana is a
stateful daemon; it stays where bhatti is. Cloudflare Tunnel gives us
a public hostname without exposing ports.

**D2. No auth in karkhana yet.** Cloudflare Access handles
identity. Karkhana reads `Cf-Access-Authenticated-User-Email` from
request headers and trusts it. Adding karkhana-native auth (in the
self-host kit plan) doesn't break this — it stacks underneath, with
Access still in front.

**D3. WebSockets work through Tunnel.** `cloudflared` supports WS
natively; no special config beyond enabling the tunnel.

**D4. KasmVNC proxy stays same-origin.** The existing kasmproxy in
karkhana (`pkg/kasmproxy/proxy.go`) already rewrites `/websockify`
paths and injects the auth shim. Tunnel passes those through
unchanged.

**D5. No state on Cloudflare.** No Workers KV, no D1, no R2 for
mission data. SQLite stays on the bhatti host. The only Cloudflare
state is the Access policy and tunnel config.

**D6. The deploy is reproducible.** Cloudflared config and Access
policy live in `deploy/cloudflare/` in the repo as version-controlled
files (Terraform or just `cloudflared.yml`), so an OSS contributor
running their own karkhana.dev-equivalent has a template to copy.

---

## 1. Topology

```
                              ┌───────────────────────────────────┐
                              │ Cloudflare edge                   │
                              │                                   │
   operator browser ───────▶  │  app.karkhana.dev                 │
                              │  ┌────────────────────────────┐   │
                              │  │  Cloudflare Access         │   │
                              │  │  - email allowlist         │   │
                              │  │  - Google OAuth (preferred)│   │
                              │  │  - JWT minted on success   │   │
                              │  └──────────┬─────────────────┘   │
                              │             │                     │
                              │             ▼                     │
                              │  ┌────────────────────────────┐   │
                              │  │  Cloudflare Tunnel         │   │
                              │  │  (TLS-terminated here)     │   │
                              │  └──────────┬─────────────────┘   │
                              └─────────────┼─────────────────────┘
                                            │ outbound conn from bhatti host
                                            │ (no inbound ports)
                              ┌─────────────┼─────────────────────┐
                              │ Your bhatti host                  │
                              │  ┌──────────▼────────────────┐    │
                              │  │  cloudflared              │    │
                              │  │  service (systemd)        │    │
                              │  └──────────┬────────────────┘    │
                              │             │  http://127.0.0.1:4000
                              │             ▼                     │
                              │  ┌────────────────────────────┐   │
                              │  │  karkhana (single binary)  │   │
                              │  │  - HTTP + WS + UI          │   │
                              │  │  - KasmVNC proxy           │   │
                              │  │  - SQLite                  │   │
                              │  └──────────┬─────────────────┘   │
                              │             │ localhost only       │
                              │             ▼                     │
                              │  ┌────────────────────────────┐   │
                              │  │  bhatti daemon  :8080      │   │
                              │  │  + sandboxes (Firecracker) │   │
                              │  └────────────────────────────┘   │
                              └───────────────────────────────────┘
```

Karkhana binds to `127.0.0.1:4000` (not `0.0.0.0`). The bhatti host
has no inbound public port. All ingress is via cloudflared's outbound
TLS connection.

---

## 2. Cloudflared installation and tunnel

### 2.1 Install on the bhatti host

```bash
# Pi 5 / arm64
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 \
  -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared

# x86_64
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
  -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared
```

### 2.2 Create the tunnel

One-time, requires browser login:

```bash
cloudflared tunnel login
# opens browser, picks karkhana.dev zone, drops cert.pem in ~/.cloudflared

cloudflared tunnel create karkhana-app
# prints tunnel UUID, drops <uuid>.json credentials file
```

### 2.3 Route DNS

```bash
cloudflared tunnel route dns karkhana-app app.karkhana.dev
```

This creates a CNAME on the Cloudflare side pointing
`app.karkhana.dev` at the tunnel.

### 2.4 Config file

`deploy/cloudflare/cloudflared.yml` (committed; UUID and cred path
filled per-host):

```yaml
tunnel: <uuid>
credentials-file: /etc/cloudflared/<uuid>.json

ingress:
  - hostname: app.karkhana.dev
    service: http://127.0.0.1:4000
    originRequest:
      # WebSockets require this:
      noTLSVerify: true
      # KasmVNC frames can be heavy; raise the default 100s.
      connectTimeout: 30s
      tlsTimeout: 10s
      # Karkhana streams long-lived WS for the event bus; keep alive.
      keepAliveTimeout: 90s
      keepAliveConnections: 100
  - service: http_status:404
```

### 2.5 Run as a service

```bash
sudo cloudflared --config /etc/cloudflared/cloudflared.yml service install
sudo systemctl enable --now cloudflared
sudo systemctl status cloudflared
```

Tunnel comes up; `https://app.karkhana.dev` resolves and hits
karkhana within ~2 seconds.

---

## 3. Cloudflare Access policy

Without Access, anyone who guesses the hostname reaches karkhana.
With Access in front, every request must carry a Cloudflare-signed
JWT proving an authorized identity.

### 3.1 Application config

In the Cloudflare dashboard (Zero Trust → Access → Applications):

```
Type:          Self-hosted
Name:          Karkhana App
Session:       24 hours
Domain:        app.karkhana.dev
Path:          (blank — covers everything)
```

### 3.2 Policy (early-access shape)

```
Name:          Operators allowlist
Action:        Allow
Include:
  - Emails:    sahil@example.com, friend@example.com, ...
  - OR Email domain: <your company domain>
```

For the broader OSS-launch shape, switch to Google OAuth or GitHub
OAuth + an email allowlist:

```
Action: Allow
Include:
  - Login methods: Google
  - AND Emails:    <allowlist>
```

### 3.3 What karkhana sees

When Access is in front, every request to karkhana arrives with
these headers:

```
Cf-Access-Authenticated-User-Email: sahil@example.com
Cf-Access-Jwt-Assertion: <signed JWT>
Cf-Connecting-Ip: <user's real IP>
```

Karkhana reads the email header to populate `agents.created_by` and
the missions list (instead of the current hardcoded `"operator"`).
The JWT can be verified against Cloudflare's JWKS for defense in
depth, but the simpler trust-the-header model is acceptable given
that the only way the header is set is through Cloudflare Access —
karkhana refuses connections that didn't come through cloudflared
by binding to 127.0.0.1.

```go
// pkg/server/middleware/access.go (new)
func CloudflareAccess(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        email := r.Header.Get("Cf-Access-Authenticated-User-Email")
        if email == "" && !isLocalLoopback(r) {
            http.Error(w, "unauthenticated", http.StatusUnauthorized)
            return
        }
        if email != "" {
            ctx := context.WithValue(r.Context(), CtxOperatorEmail, email)
            r = r.WithContext(ctx)
        }
        next.ServeHTTP(w, r)
    })
}
```

`isLocalLoopback` lets the `/internal/driver/*` path keep working —
the driver pi-rpc subprocess on the same host hits karkhana over
loopback and doesn't pass through Cloudflare.

### 3.4 What about WebSockets?

Access supports WebSockets natively. The JWT cookie set during
initial HTTP auth is sent on the WS upgrade request; Access verifies
it; the upgrade proceeds. No special handling needed.

### 3.5 What about KasmVNC?

The KasmVNC iframe is served from the same origin (`/proxy/<agent>/`
on `app.karkhana.dev`). Same JWT cookie, same Access policy, same
verification. The kasmproxy's URL rewriting (handles
`/websockify` path-rewrite) doesn't change.

The one wrinkle: KasmVNC opens a long-lived WS (the VNC stream).
Cloudflare Tunnel + Access both pass through long-lived WS fine, but
the connection occasionally drops on tunnel reloads (e.g.,
`cloudflared` redeploy). The existing iframe-pool reparenting in
`AgentTile.tsx` already handles this — reconnect logic kicks in
within ~2s.

---

## 4. Karkhana changes for this deployment

Three small changes, all of which are no-ops without Cloudflare in
front so they're safe to land before the tunnel is up.

### 4.1 Bind to 127.0.0.1 in deployment mode

`KARKHANA_ADDR` already exists as a config knob. Default stays
`:4000` for local dev; production deploy sets `KARKHANA_ADDR=127.0.0.1:4000`.
Document in `deploy/cloudflare/README.md`.

### 4.2 Access-header middleware

`pkg/server/middleware/access.go` (sketch in §3.3). Mounted only
when `KARKHANA_TRUST_CF_ACCESS=true` (so local dev still works).
Populates `r.Context()` with the operator email; mission/agent
creation paths read it instead of hardcoded `"operator"`.

### 4.3 Logout link

The UI gains a small "sign out" affordance — links to
`https://app.karkhana.dev/cdn-cgi/access/logout`, which Cloudflare
handles. Trivial; one anchor tag in the topbar.

---

## 5. The marketing site (later)

Not in this plan's critical path; sketched here so the topology
above stays right when it lands.

```
karkhana.dev (root)         Cloudflare Pages
  ├── /                     marketing copy, "what is karkhana", videos
  ├── /docs/                docs site (mdx + Pages)
  └── /app                  redirect → app.karkhana.dev
```

The marketing site is its own git repo (or a `web/` subfolder),
deployed via Pages on every push to `main`. Independent of the
app's deploy cycle.

Bhatti.sh follows the same pattern and is the precedent; we copy
its setup. No new tooling.

---

## 6. The playground (deferred, sketched only)

```
play.karkhana.dev
  └── Cloudflare Worker (entry)
      ├── Turnstile challenge
      ├── Trial-token mint (calls bhatti's trial-tenant API — TBD,
      │   in a separate bhatti-side plan)
      └── Proxy to Tunnel → karkhana (different deployment instance,
                                     bound to trial-tenant scope)
```

The interesting bit on the Cloudflare side is the Worker. It:

- Serves a small landing page with the Workflow C demo video.
- Gates entry with Turnstile (Cloudflare's hCaptcha equivalent,
  free, lower friction than email-verify).
- On success, hits an internal API (auth via Worker secret) to mint
  a bhatti trial token and signed-cookie it.
- Reverse-proxies subsequent requests to the karkhana instance via
  Tunnel.

Karkhana itself doesn't change; it reads the trial-tenant token
from a header the Worker sets. The playground is a thin layer in
front of a karkhana-in-trial-mode deployment.

This is **not in v0.7 scope.** It depends on bhatti's trial-tenant
primitives, which are your side of the work. Filing here so the
Cloudflare topology accommodates it without rework when we get to
it.

---

## 7. Operator runbook

The complete go-from-zero-to-app.karkhana.dev sequence, in 10
minutes. This is what ships in the self-host kit's
`deploy/cloudflare/README.md`.

```bash
# 1. Karkhana binary is running on this host (out of scope here;
#    see the self-host kit plan).

# 2. Install cloudflared (5 min)
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') \
  -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared

# 3. Login + create tunnel (2 min, opens browser once)
cloudflared tunnel login
cloudflared tunnel create karkhana-app
cloudflared tunnel route dns karkhana-app app.karkhana.dev

# 4. Drop config (1 min)
sudo mkdir -p /etc/cloudflared
sudo cp <repo>/deploy/cloudflare/cloudflared.yml /etc/cloudflared/
sudo cp ~/.cloudflared/<uuid>.json /etc/cloudflared/
# edit /etc/cloudflared/cloudflared.yml — paste your tunnel UUID

# 5. Run as service (1 min)
sudo cloudflared --config /etc/cloudflared/cloudflared.yml service install
sudo systemctl enable --now cloudflared

# 6. Cloudflare Access policy (1 min, in dashboard)
#    Zero Trust → Access → Applications → Add → Self-hosted
#    Domain: app.karkhana.dev
#    Policy: Allow emails: <your allowlist>

# 7. Done. Open https://app.karkhana.dev in incognito;
#    Access challenges you, you sign in, karkhana loads.
```

Files committed to the repo to support this:

```
deploy/cloudflare/
  README.md                     this runbook
  cloudflared.yml.example       config template (UUID placeholder)
  systemd/cloudflared.service   optional override unit
  access-policy.example.json    documented Access policy (commented)
```

---

## 8. Out of scope

- **Karkhana hosted on Workers or Pages.** Stateful daemon; wrong
  shape.
- **Cloudflare Workers KV / D1 / R2 for mission state.** SQLite on
  the bhatti host. We do not want a second source of truth.
- **Cloudflare WAF rules for karkhana.** Trust boundary is at Access;
  no public surface to protect.
- **Multi-region deploys.** Single bhatti host = single karkhana =
  single tunnel. When multi-host bhatti lands (your plan, not mine),
  revisit.
- **Cloudflare Stream for the demo videos.** Pages + R2 (or
  YouTube/Vimeo) handles videos fine. Stream adds cost without
  benefit at our scale.
- **Replacing Cloudflare Access with karkhana-native auth.** Access
  is the right answer at this scale. Karkhana-native auth lives in
  the self-host kit plan for operators who don't want Cloudflare in
  their stack.

---

## 9. Phasing

Tiny, because most of the work is Cloudflare config.

```
Day 1   Bind karkhana to 127.0.0.1:4000 in production mode.
        Write Access-header middleware (40 lines).
        Wire CtxOperatorEmail through mission/agent creation paths.
        Add /cdn-cgi/access/logout link to UI topbar.

Day 2   Set up cloudflared on the bhatti host. Create tunnel.
        Route DNS for app.karkhana.dev. Install systemd service.
        Verify WS + KasmVNC iframe + event bus all work through it.

Day 3   Configure Cloudflare Access. Email allowlist policy.
        End-to-end test: open incognito, hit app.karkhana.dev,
        Access challenge, sign in, run a mission, watch a
        KasmVNC desktop stream, sign out.
        Commit deploy/cloudflare/ artifacts to the repo.
```

~3 days, mostly waiting on DNS propagation and Cloudflare dashboard
clicks.

---

## What comes after

- **Self-host kit plan.** This Cloudflare path is the recommended
  one; the kit also documents raw-systemd-with-caddy as an
  alternative for operators who want zero Cloudflare dependency.
- **Marketing site on Pages.** When the OSS launch lands and we have
  the Workflow C video.
- **`play.karkhana.dev` playground.** When bhatti's trial-tenant
  primitives are ready. Worker + Turnstile + Tunnel; sketched in
  §6.
- **Cloudflared sidecar inside the bhatti host.** If bhatti ever
  wants its own `bhatti.sh`-style hosted dashboard, the same
  topology works for it — just a second tunnel to a different
  hostname.
