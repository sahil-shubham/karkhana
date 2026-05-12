# syntax=docker/dockerfile:1.7
#
# karkhana-kk-dev — headless dev sandbox for Karkhana workers.
#
# Built and pushed to ghcr.io/sahil-shubham/karkhana-kk-dev:latest
# on tag (see .github/workflows/images.yml). Operators pull into
# their bhatti host via:
#
#     bhatti image pull ghcr.io/sahil-shubham/karkhana-kk-dev:latest --name kk-dev
#
# Then the karkhana recipe `headless-dev` resolves `image: kk-dev`
# to this local copy on every spawn.
#
# What's in it: Debian bookworm + Node 22 (for pi-coding-agent),
# Python 3, Go, git/gh, ripgrep, jq, fd. No chromium, no xfce,
# no scrot/xdotool — that's by design. Workers that need a
# headful desktop run the desktop-watch recipe instead (kk-base
# image).
#
# Build from project root so the COPY of extensions/ resolves:
#     docker buildx build --file images/kk-dev/Dockerfile -t kk-dev:dev .
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV TZ=Etc/UTC

# ---------------------------------------------------------------
# Base packages. Single RUN to minimize layer count + apt cache.
# ---------------------------------------------------------------
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg \
      git openssh-client \
      python3 python3-pip python3-venv pipx \
      golang-go \
      ripgrep jq fd-find \
      file less vim-tiny tini \
      build-essential pkg-config \
      sudo locales \
 && sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen \
 && locale-gen \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------
# Node 22 from NodeSource (pi-coding-agent needs Node 18+).
# ---------------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && node --version && npm --version

# ---------------------------------------------------------------
# gh CLI. Useful for headless workers reading repo metadata,
# enumerating PRs/issues without scraping HTML.
# ---------------------------------------------------------------
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
 && chmod a+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------
# pi-coding-agent, baked in so worker spawn doesn't pay 30s of
# `npm install -g` per cold boot.
# ---------------------------------------------------------------
RUN npm install -g --silent --omit=dev @mariozechner/pi-coding-agent \
 && pi --version || true

# ---------------------------------------------------------------
# Karkhana headless-dev extension (computer-use-cli). The recipe
# `headless-dev` references this path:
#     /usr/local/share/karkhana/extensions/computer-use-cli/index.ts
# ---------------------------------------------------------------
COPY extensions/computer-use-cli /usr/local/share/karkhana/extensions/computer-use-cli

# ---------------------------------------------------------------
# fd-find ships as `fdfind` on Debian; alias it to `fd` for
# consistency with the rest of the world.
# ---------------------------------------------------------------
RUN ln -sf /usr/bin/fdfind /usr/local/bin/fd

# ---------------------------------------------------------------
# Workspace + lohar user (bhatti convention: uid 1000, /workspace).
# ---------------------------------------------------------------
RUN useradd -m -s /bin/bash -u 1000 lohar \
 && mkdir -p /workspace && chown lohar:lohar /workspace \
 && echo 'lohar ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/lohar \
 && chmod 0440 /etc/sudoers.d/lohar

USER lohar
WORKDIR /workspace

# ---------------------------------------------------------------
# Default CMD is irrelevant — bhatti's lohar PID 1 takes over.
# Provide a bash shell as a sensible fallback for `docker run`
# during local image testing.
# ---------------------------------------------------------------
CMD ["/bin/bash"]
