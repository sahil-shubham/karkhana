# Operator setup

Karkhana runs alongside a bhatti host. Once bhatti is up, three
things need to be in place before missions can spawn:

1. The bhatti images the recipes reference.
2. The bhatti secrets the recipes inject.
3. Karkhana's own config (bhatti URL + token, default recipe).

Karkhana checks all three at startup and prints the exact command
needed for anything missing.

## 1. Pull images

Each recipe declares an `image:` field. Bhatti needs that image
pulled locally. The bundled recipes today reference two:

```bash
# headless-dev (kk-dev): Node + Python + Go + git/gh + ripgrep/jq.
# Built from images/kk-dev/Dockerfile and pushed to ghcr.io on tag.
bhatti image pull ghcr.io/sahil-shubham/karkhana-kk-dev:latest --name kk-dev

# desktop-watch + mixed (kk-base): XFCE + Chromium + KasmVNC.
# Built today via scripts/bake-image.sh against a running bhatti
# host. Dockerfile follow-up to come.
./scripts/bake-image.sh
```

If you haven't pulled them yet, karkhana's startup logs spell
the exact `bhatti image pull` command out for each missing one.
Missing the *default* recipe's image is a fatal startup error;
missing a non-default recipe's image is a warning (you just
can't spawn that recipe until you pull).

## 2. Set secrets

Each recipe declares the secrets it needs as `secrets: [NAME, ...]`.
Bhatti decrypts those at sandbox boot and injects them as env
vars. Karkhana never sees the values.

For the bundled recipes:

```bash
bhatti secret set ANTHROPIC_API_KEY sk-ant-...   # LLM provider
bhatti secret set GH_TOKEN          ghp_...      # used by headless-dev for gh CLI / git clone
```

Add more as your recipes need them. The `recipes/<name>.yaml`
file is the authoritative declaration of what each recipe
references. Karkhana startup warns about any recipe that names
a secret bhatti doesn't have.

## 3. Karkhana config

Bhatti URL + token come from `~/.bhatti/config.yaml` (auto-read)
or from env vars:

```bash
export KARKHANA_BHATTI_URL=https://your-bhatti.example/
export KARKHANA_BHATTI_TOKEN=<paste>
```

Default recipe (which one drivers pick when they don't specify):

```bash
export KARKHANA_DEFAULT_RECIPE=desktop-watch    # the default; or headless-dev / mixed
```

Then run:

```bash
make build         # produces bin/karkhana with the UI embedded
./bin/karkhana
```

## A note on the driver subprocess

The driver agent (one per mission) runs on the karkhana host as
a `pi --mode rpc` subprocess, not inside a bhatti sandbox. It
needs `ANTHROPIC_API_KEY` (or whichever provider) in karkhana's
own environment to authenticate against the LLM.

That's a single bootstrap env var karkhana reads at startup and
passes into each driver subprocess. Workers do NOT use this
path — only the driver. A future plan moves the driver inside
a bhatti sandbox too, eliminating the last karkhana-side secret
hold.

## Iterating

Set `KARKHANA_DEV=1` to enable hot-reload for prompts and
recipes:

- Edit `prompts/*.tmpl` → next mission/worker spawn picks up
  the change.
- Edit `recipes/*.yaml` → same.

In production, both are embedded in the binary via `go:embed`;
edits require a rebuild.
