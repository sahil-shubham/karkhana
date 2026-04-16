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
    bhatti create --name "$ORCH_NAME" --image karkhana-pi --cpus 1 --memory 2048 --keep-hot

    echo "Installing Elixir + cloning karkhana..."
    bhatti exec "$ORCH_NAME" -- bash -lc '
      # Install Erlang + Elixir
      sudo apt-get update -qq
      sudo apt-get install -y -qq erlang elixir 2>&1 | tail -3

      # Clone karkhana
      cd /home/lohar
      git clone https://github.com/sahil-shubham/karkhana.git 2>/dev/null || true
      cd karkhana/elixir
      mix local.hex --force
      mix local.rebar --force
      mix deps.get
    '

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
