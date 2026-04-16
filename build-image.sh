#!/bin/bash
# Build the karkhana-pi sandbox image from scratch.
#
# Usage: ./build-image.sh [image-name]
#   Default image name: karkhana-pi
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

# Write the build script as a file, then push it in
TMPSCRIPT=$(mktemp)
cat > "$TMPSCRIPT" <<'BUILDEOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

log() { echo "$(date -Iseconds) $1"; }

log "Installing Node.js 22..."
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y -qq nodejs

log "Installing system tools..."
sudo apt-get install -y -qq git curl jq unzip

log "Installing GitHub CLI..."
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update -qq
sudo apt-get install -y -qq gh

log "Setting up corepack..."
sudo corepack enable

log "Installing Pi..."
sudo npm install -g @mariozechner/pi-coding-agent

log "Cleaning up..."
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*

log "BUILD_DONE"
BUILDEOF

echo "Uploading build script..."
bhatti file write "$BUILD_SANDBOX" /tmp/build.sh < "$TMPSCRIPT"
rm "$TMPSCRIPT"

echo "Launching build (background)..."
bhatti exec "$BUILD_SANDBOX" --timeout 10 -- bash -c \
  'chmod +x /tmp/build.sh; nohup /tmp/build.sh > /tmp/build.log 2>&1 & disown; echo ok' \
  || true

echo "Waiting for build to finish (this takes 2-5 minutes)..."
while true; do
  sleep 15

  # Read last line of build log
  LAST=$(bhatti exec "$BUILD_SANDBOX" --timeout 10 -- tail -1 /tmp/build.log 2>/dev/null || echo "...")

  echo "  $LAST"

  if echo "$LAST" | grep -q "BUILD_DONE"; then
    break
  fi
done

echo ""
echo "Verifying installation..."
bhatti exec "$BUILD_SANDBOX" --timeout 15 -- bash -lc \
  'echo "node: $(node --version)"; echo "pi: $(pi --version)"; echo "git: $(git --version)"; echo "gh: $(gh --version | head -1)"; echo "jq: $(jq --version)"'

echo ""
echo "Saving image as $IMAGE_NAME..."
bhatti image save "$BUILD_SANDBOX" --name "$IMAGE_NAME"

echo ""
echo "Done!"
bhatti image list | grep "$IMAGE_NAME"
