#!/bin/bash
# Deploy karkhana orchestrator to bhatti
#
# Usage: ./deploy.sh          # first time: create sandbox + deploy release + start
#        ./deploy.sh upgrade   # download latest release, restart
#        ./deploy.sh workflow  # update WORKFLOW.md only (hot reload)
#        ./deploy.sh restart   # restart the orchestrator process
#        ./deploy.sh logs      # tail orchestrator logs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/elixir/.env"

ORCH_NAME="karkhana-orchestrator"
RELEASE_DIR="/home/lohar/karkhana-release"
REPO="sahil-shubham/karkhana"

# Detect sandbox architecture for release download
detect_arch() {
  local arch
  arch=$(bhatti exec "$ORCH_NAME" --timeout 10 -- uname -m 2>/dev/null || echo "x86_64")
  case "$arch" in
    x86_64|amd64) echo "linux-amd64" ;;
    aarch64|arm64) echo "linux-arm64" ;;
    *) echo "linux-amd64" ;;
  esac
}

# Download the latest release tarball from GitHub into the sandbox
download_release() {
  local version="$1"
  local target
  target=$(detect_arch)

  echo "Downloading karkhana $version ($target)..."

  # Download to local temp, then push into sandbox (avoids needing curl auth in sandbox)
  local tmpfile
  tmpfile=$(mktemp)
  curl -fsSL -o "$tmpfile" \
    "https://github.com/$REPO/releases/download/$version/karkhana-$version-$target.tar.gz"

  echo "Uploading release to sandbox..."
  bhatti file write "$ORCH_NAME" /tmp/karkhana-release.tar.gz < "$tmpfile"
  rm "$tmpfile"

  echo "Extracting..."
  bhatti exec "$ORCH_NAME" --timeout 15 -- bash -c "
    rm -rf $RELEASE_DIR
    mkdir -p $RELEASE_DIR
    cd $RELEASE_DIR
    tar xzf /tmp/karkhana-release.tar.gz --strip-components=1
    rm /tmp/karkhana-release.tar.gz
  "
}

# Install the runner script that auto-restarts on crash
install_runner() {
  cat <<SCRIPT | bhatti file write "$ORCH_NAME" /home/lohar/karkhana-run.sh
#!/bin/bash
cd $RELEASE_DIR
source /home/lohar/karkhana/.env 2>/dev/null || true

# Export WORKFLOW.md path for the orchestrator
export KARKHANA_WORKFLOW_PATH=/home/lohar/karkhana/elixir/WORKFLOW.md

while true; do
  echo "\$(date -Iseconds) Starting karkhana..." >> /tmp/karkhana.log

  # Pull latest WORKFLOW.md (hot-reloadable config)
  cd /home/lohar/karkhana && git pull origin main --ff-only 2>> /tmp/karkhana.log || true

  cd $RELEASE_DIR
  bin/karkhana start >> /tmp/karkhana.log 2>&1 || true
  # start runs in foreground — if it exits, we restart
  EXIT=\$?
  echo "\$(date -Iseconds) Karkhana exited (\$EXIT), restarting in 5s..." >> /tmp/karkhana.log
  sleep 5
done
SCRIPT
}

start_orchestrator() {
  bhatti exec "$ORCH_NAME" --timeout 10 -- bash -c "
    pkill -f 'karkhana-run.sh' 2>/dev/null || true
    pkill -f 'bin/karkhana' 2>/dev/null || true
    sleep 1
    chmod +x /home/lohar/karkhana-run.sh
    > /tmp/karkhana.log
    setsid /home/lohar/karkhana-run.sh </dev/null >/dev/null 2>&1 &
    disown
    echo started
  " || true
}

case "${1:-start}" in
  workflow)
    bhatti file write "$ORCH_NAME" /home/lohar/karkhana/elixir/WORKFLOW.md < "$SCRIPT_DIR/elixir/WORKFLOW.md"
    echo "WORKFLOW.md updated. Orchestrator will hot-reload within seconds."
    ;;

  restart)
    start_orchestrator
    echo "Orchestrator restarted."
    ;;

  upgrade)
    VERSION="${2:-$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")}"
    download_release "$VERSION"
    install_runner
    start_orchestrator
    echo "Upgraded to $VERSION and restarted."
    ;;

  logs)
    bhatti exec "$ORCH_NAME" --timeout 10 -- tail -50 /tmp/karkhana.log
    ;;

  start|"")
    echo "Creating orchestrator sandbox..."
    bhatti create --name "$ORCH_NAME" --image karkhana-pi-v2 --cpus 2 --memory 2048 --disk-size 4096 --keep-hot

    echo "Cloning karkhana repo (for WORKFLOW.md + .env)..."
    bhatti exec "$ORCH_NAME" --timeout 30 -- bash -lc "
      cd /home/lohar
      git clone https://github.com/$REPO.git karkhana 2>/dev/null || true
    "

    echo "Deploying config..."
    bhatti file write "$ORCH_NAME" /home/lohar/karkhana/elixir/.env < "$SCRIPT_DIR/elixir/.env"
    bhatti file write "$ORCH_NAME" /home/lohar/karkhana/elixir/WORKFLOW.md < "$SCRIPT_DIR/elixir/WORKFLOW.md"

    # Get latest release version
    VERSION="${2:-$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])")}"
    download_release "$VERSION"
    install_runner

    echo "Starting orchestrator..."
    start_orchestrator

    echo "Publishing dashboard..."
    bhatti publish "$ORCH_NAME" -p 4000 -a karkhana 2>/dev/null || true

    echo ""
    echo "Karkhana orchestrator deployed! ($VERSION)"
    echo "  Dashboard:      https://karkhana.bhatti.sh"
    echo "  Update prompt:  ./deploy.sh workflow"
    echo "  Upgrade:        ./deploy.sh upgrade"
    echo "  Restart:        ./deploy.sh restart"
    echo "  Logs:           ./deploy.sh logs"
    ;;
esac
