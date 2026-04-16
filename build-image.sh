#!/bin/bash
# Build the karkhana-pi sandbox image from scratch.
#
# Usage: ./build-image.sh [image-name]
#   Default image name: karkhana-pi
#
# The resulting image has:
#   - Latest lohar (from minimal base)
#   - Node.js 22, Pi coding agent
#   - Erlang/OTP + Elixir (for the orchestrator)
#   - git, curl, jq, gh
set -euo pipefail

IMAGE_NAME="${1:-karkhana-pi}"
BUILD_SANDBOX="karkhana-build-$$"

echo "=== Building image: $IMAGE_NAME ==="
echo "Build sandbox: $BUILD_SANDBOX"

cleanup() {
  echo "Cleaning up build sandbox..."
  bhatti destroy "$BUILD_SANDBOX" 2>/dev/null || true
}
trap cleanup EXIT

echo "Creating build sandbox from minimal..."
bhatti create --name "$BUILD_SANDBOX" --image minimal --cpus 2 --memory 2048 --disk-size 4096

# Write the build script
cat <<'BUILDEOF' | bhatti file write "$BUILD_SANDBOX" /tmp/build.sh
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
log() { echo "$(date -Iseconds) $1"; }

# Enable universe repo (minimal only has main)
log "Enabling universe repo..."
sudo sed -i 's/^deb http:\/\/archive.ubuntu.com\/ubuntu noble main$/deb http:\/\/archive.ubuntu.com\/ubuntu noble main universe/' /etc/apt/sources.list
sudo apt-get update -qq

log "Installing Node.js 22..."
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y -qq nodejs

log "Installing Erlang + Elixir..."
sudo apt-get install -y -qq erlang elixir

log "Installing system tools..."
sudo apt-get install -y -qq git curl jq unzip

log "Installing GitHub CLI..."
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update -qq
sudo apt-get install -y -qq gh

log "Setting up corepack + hex + rebar..."
sudo corepack enable
mix local.hex --force
mix local.rebar --force

log "Installing Pi..."
sudo npm install -g @mariozechner/pi-coding-agent

log "Cleaning up..."
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*

log "BUILD_DONE"
BUILDEOF

# Launch detached (avoids Cloudflare 524 on long apt installs)
echo "Launching build..."
bhatti exec "$BUILD_SANDBOX" --timeout 10 -- bash -c \
  'chmod +x /tmp/build.sh; nohup /tmp/build.sh > /tmp/build.log 2>&1 & disown; echo ok' \
  || true

echo "Waiting for build (3-8 minutes)..."
while true; do
  sleep 15
  LAST=$(bhatti exec "$BUILD_SANDBOX" --timeout 10 -- tail -1 /tmp/build.log 2>/dev/null || echo "...")
  echo "  $LAST"
  if echo "$LAST" | grep -q "BUILD_DONE"; then
    break
  fi
  # Check for errors
  if echo "$LAST" | grep -q "^E: \|set -e"; then
    echo "Build failed! Full log:"
    bhatti exec "$BUILD_SANDBOX" --timeout 10 -- tail -30 /tmp/build.log 2>/dev/null || true
    exit 1
  fi
done

echo ""
echo "Verifying..."
bhatti exec "$BUILD_SANDBOX" --timeout 15 -- bash -lc \
  'echo "node:   $(node --version)"
   echo "pi:     $(pi --version)"
   echo "elixir: $(elixir --version | tail -1)"
   echo "erlang: $(erl -eval "io:format(\"~s~n\", [erlang:system_info(otp_release)]), halt()." -noshell)"
   echo "git:    $(git --version)"
   echo "gh:     $(gh --version | head -1)"
   echo "jq:     $(jq --version)"'

echo ""
echo "Saving image as $IMAGE_NAME..."
bhatti image save "$BUILD_SANDBOX" --name "$IMAGE_NAME"

echo ""
echo "Done!"
bhatti image list | grep "$IMAGE_NAME"
