#!/bin/bash
# Deploy karkhana orchestrator to bhatti
# Usage: ./deploy.sh          # first time: create sandbox + start
#        ./deploy.sh workflow  # update WORKFLOW.md only (hot reload)
#        ./deploy.sh restart   # restart the orchestrator process
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/elixir/.env"

ORCH_NAME="karkhana-orchestrator"

# The orchestrator run script: pulls latest code, starts mix, restarts on crash.
# Written into the sandbox and executed via setsid so it survives bhatti exec exit.
RUNNER_SCRIPT='#!/bin/bash
cd /home/lohar/karkhana/elixir && source .env
while true; do
  echo "$(date -Iseconds) Pulling latest..." >> /tmp/karkhana.log
  cd /home/lohar/karkhana && git pull origin main --ff-only 2>> /tmp/karkhana.log || true
  cd /home/lohar/karkhana/elixir
  echo "$(date -Iseconds) Starting orchestrator..." >> /tmp/karkhana.log
  mix run --no-halt >> /tmp/karkhana.log 2>&1
  EXIT=$?
  echo "$(date -Iseconds) Orchestrator exited ($EXIT), restarting in 5s..." >> /tmp/karkhana.log
  sleep 5
done'

start_orchestrator() {
  bhatti exec "$ORCH_NAME" -- bash -c "
    pkill -f 'karkhana-run.sh' 2>/dev/null || true
    pkill -f 'mix run' 2>/dev/null || true
    sleep 1
    cat > /home/lohar/karkhana-run.sh << 'SCRIPT'
${RUNNER_SCRIPT}
SCRIPT
    chmod +x /home/lohar/karkhana-run.sh
    setsid /home/lohar/karkhana-run.sh < /dev/null > /dev/null 2>&1 &
  "
}

case "${1:-start}" in
  workflow)
    # Hot-reload: push WORKFLOW.md into the running orchestrator
    bhatti file write "$ORCH_NAME" /home/lohar/karkhana/elixir/WORKFLOW.md < "$SCRIPT_DIR/elixir/WORKFLOW.md"
    echo "WORKFLOW.md updated. Orchestrator will hot-reload within seconds."
    ;;

  restart)
    start_orchestrator
    echo "Orchestrator restarted."
    ;;

  start|"")
    echo "Creating orchestrator sandbox..."
    # Idempotent: bhatti returns existing sandbox if name exists
    bhatti create --name "$ORCH_NAME" --image karkhana-pi-v2 --cpus 1 --memory 2048 --keep-hot

    echo "Installing Erlang/Elixir via elixir-install..."
    # Write install script and run detached (avoids Cloudflare 524 timeout)
    cat <<'INSTALL_SCRIPT' | bhatti file write "$ORCH_NAME" /tmp/install-orchestrator.sh
#!/bin/bash -l
set -e
log() { echo "$(date -Iseconds) $1"; }

log "Installing elixir-install..."
curl -fsSL https://raw.githubusercontent.com/cigrainger/elixir-install/main/bin/elixir-install | bash >> /tmp/install.log 2>&1
export PATH="$HOME/.elixir-install/bin:$PATH"
echo 'export PATH="$HOME/.elixir-install/bin:$PATH"' >> ~/.bashrc

log "Installing Erlang/OTP 27..."
elixir-install otp 27 >> /tmp/install.log 2>&1

log "Installing Elixir 1.18..."
elixir-install elixir 1.18 >> /tmp/install.log 2>&1

# Source the paths that elixir-install set up
source ~/.bashrc 2>/dev/null || true
export PATH="$HOME/.elixir-install/installs/otp/27/bin:$HOME/.elixir-install/installs/elixir/1.18/bin:$PATH"

log "Installing hex + rebar..."
mix local.hex --force >> /tmp/install.log 2>&1
mix local.rebar --force >> /tmp/install.log 2>&1

log "Cloning karkhana..."
cd /home/lohar
git clone https://github.com/sahil-shubham/karkhana.git 2>/dev/null || true
cd karkhana/elixir

log "Installing deps..."
mix deps.get >> /tmp/install.log 2>&1

log "Compiling..."
mix compile >> /tmp/install.log 2>&1

log "INSTALL_DONE"
INSTALL_SCRIPT

    bhatti exec "$ORCH_NAME" --timeout 10 -- bash -c \
      'chmod +x /tmp/install-orchestrator.sh; nohup /tmp/install-orchestrator.sh > /tmp/install-progress.log 2>&1 & disown; echo ok' \
      || true

    echo "Waiting for install (this takes 3-8 minutes)..."
    while true; do
      sleep 15
      LAST=$(bhatti exec "$ORCH_NAME" --timeout 10 -- tail -1 /tmp/install-progress.log 2>/dev/null || echo "...")
      echo "  $LAST"
      if echo "$LAST" | grep -q "INSTALL_DONE"; then
        break
      fi
    done

    echo "Deploying env and WORKFLOW.md..."
    bhatti file write "$ORCH_NAME" /home/lohar/karkhana/elixir/.env < "$SCRIPT_DIR/elixir/.env"
    bhatti file write "$ORCH_NAME" /home/lohar/karkhana/elixir/WORKFLOW.md < "$SCRIPT_DIR/elixir/WORKFLOW.md"

    echo "Starting orchestrator..."
    start_orchestrator

    echo ""
    echo "Karkhana orchestrator deployed!"
    echo "  Update prompt:  ./deploy.sh workflow"
    echo "  Restart:        ./deploy.sh restart"
    echo "  Logs:           bhatti exec $ORCH_NAME -- tail -f /tmp/karkhana.log"
    ;;
esac
