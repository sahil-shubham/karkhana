# kk-dev — headless dev sandbox

The bhatti image powering Karkhana's `headless-dev` recipe.

Debian bookworm + Node 22 + Python 3 + Go + git + gh + ripgrep
+ jq + fd, with pi-coding-agent and Karkhana's headless worker
extension pre-baked. No chromium, no XFCE, no scrot/xdotool —
that's by design. Headless workers boot in ~1s and use ~2GB of
RAM; the desktop counterpart (`kk-base`) takes ~30s cold and
~4GB.

## Get it onto your bhatti host

Once per host:

```bash
bhatti image pull ghcr.io/sahil-shubham/karkhana-kk-dev:latest --name kk-dev
```

Karkhana checks at startup that every recipe's `image:` resolves
to a local bhatti image; if it doesn't, it prints exactly that
command in the error.

## Build locally

From the project root (the build context needs to include
`extensions/computer-use-cli`):

```bash
docker buildx build \
  --file images/kk-dev/Dockerfile \
  --platform linux/amd64,linux/arm64 \
  --tag kk-dev:dev \
  --load \
  .
```

For multi-arch push to ghcr.io, replace `--load` with `--push`
and add `--tag ghcr.io/sahil-shubham/karkhana-kk-dev:<tag>`.

## CI

`.github/workflows/images.yml` builds + pushes on tags matching
`kk-dev-v*` and on every push to `main` (`:latest`).

## What's in it

| Tool                | Purpose                                  |
|---------------------|------------------------------------------|
| `pi`                | The agent runtime (pi-coding-agent).     |
| `node`              | Node 22 LTS, required by pi.             |
| `python3`, `pip`    | For ad-hoc scripts.                      |
| `go`                | Compile small Go utilities.              |
| `git`, `gh`         | Clone and query GitHub.                  |
| `ripgrep`, `fd`     | Fast search across cloned repos.         |
| `jq`                | JSON munging for `gh` / `curl` output.   |
| `curl`, `wget`      | Allowed for headless-dev workers.        |
| `sudo`              | The lohar user has passwordless sudo.    |

User: `lohar` (uid 1000), `/workspace` as cwd, passwordless sudo
— matches the bhatti host-side convention.

## What's NOT in it

- chromium / chromedriver / kasmvnc / xfce — use `kk-base`.
- scrot / xdotool — those are GUI tools.
- rust toolchain — adds ~1GB; not yet warranted. Author a
  derived image if you need it.
- Docker daemon / containerd — workers don't run containers
  inside workers (bhatti is the layer below).
