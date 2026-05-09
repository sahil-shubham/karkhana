#!/usr/bin/env bash
# bake-image.sh — one-shot bootstrap for the kk-base bhatti image.
#
# Spawns a temporary computer-tier sandbox, installs pi-coding-agent
# inside it, then saves the rootfs as a reusable bhatti image
# (default name: kk-base). After this runs, every Karkhana mission
# boots from the snapshot — pi is already there, no npm install,
# spawn time drops from ~30s to ~2s.
#
# Idempotent: if kk-base already exists, exit early unless --force.
#
# Usage:
#   ./scripts/bake-image.sh                  # default: kk-base
#   ./scripts/bake-image.sh --name my-image  # custom name
#   ./scripts/bake-image.sh --force          # rebuild even if exists

set -euo pipefail

IMAGE_NAME="kk-base"
FORCE=0
PI_PACKAGE="@mariozechner/pi-coding-agent"

while [[ $# -gt 0 ]]; do
  case $1 in
    --name) IMAGE_NAME="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --pi-package) PI_PACKAGE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# //'
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Pull bhatti config from the same place Karkhana uses.
BHATTI_URL=$(grep '^api_url:' ~/.bhatti/config.yaml | awk '{print $2}')
BHATTI_TOKEN=$(grep '^auth_token:' ~/.bhatti/config.yaml | awk '{print $2}')
if [[ -z "$BHATTI_URL" || -z "$BHATTI_TOKEN" ]]; then
  echo "error: ~/.bhatti/config.yaml missing api_url or auth_token" >&2
  exit 1
fi

curl_b() {
  curl -sS -H "Authorization: Bearer $BHATTI_TOKEN" "$@"
}

log() { printf "  %s\n" "$*" >&2; }

# 1. Check if the image already exists.
if [[ $FORCE -eq 0 ]]; then
  if curl_b "$BHATTI_URL/images" \
       | python3 -c "
import sys, json
imgs = json.load(sys.stdin) if sys.stdin.isatty() == False else []
sys.exit(0 if any((i.get('name') == '$IMAGE_NAME') for i in imgs) else 1)
" 2>/dev/null; then
    echo "image '$IMAGE_NAME' already exists. use --force to rebuild." >&2
    echo "(set KARKHANA_WORKER_IMAGE=$IMAGE_NAME in .env to use it)" >&2
    exit 0
  fi
fi

# 2. Create a build sandbox.
BUILD_NAME="kk-bake-$$"
log "creating build sandbox: $BUILD_NAME"
RESP=$(curl_b -X POST "$BHATTI_URL/sandboxes" \
  -H 'Content-Type: application/json' \
  -d "{
    \"name\": \"$BUILD_NAME\",
    \"image\": \"computer\",
    \"cpus\": 2,
    \"memory_mb\": 4096,
    \"disk_size_mb\": 10240,
    \"keep_hot\": true
  }")
SBID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
log "sandbox: $SBID"

cleanup() {
  log "cleanup: terminating $SBID"
  curl_b -X DELETE "$BHATTI_URL/sandboxes/$SBID" -o /dev/null || true
}
trap cleanup EXIT

# Wait until running. Bhatti's POST /sandboxes is supposed to block
# until status=running, but we double-check.
for _ in $(seq 1 30); do
  ST=$(curl_b "$BHATTI_URL/sandboxes/$SBID" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))")
  [[ "$ST" == "running" ]] && break
  sleep 1
done
log "status: $ST"
[[ "$ST" != "running" ]] && { echo "sandbox didn't reach running"; exit 1; }

# 3. Install pi inside.
log "installing $PI_PACKAGE (this is the slow part — ~30s)"
INSTALL_RES=$(curl_b -X POST "$BHATTI_URL/sandboxes/$SBID/exec" \
  -H 'Content-Type: application/json' \
  -d "{
    \"cmd\": [\"sudo\", \"npm\", \"install\", \"-g\", \"--silent\", \"$PI_PACKAGE\"],
    \"timeout_sec\": 240
  }")
EXIT=$(echo "$INSTALL_RES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('exit_code',-1))")
if [[ "$EXIT" != "0" ]]; then
  echo "npm install failed (exit=$EXIT):" >&2
  echo "$INSTALL_RES" | python3 -m json.tool >&2 || echo "$INSTALL_RES" >&2
  exit 1
fi
log "pi installed"

# 4. Verify pi runs.
log "verifying pi"
VERIFY_RES=$(curl_b -X POST "$BHATTI_URL/sandboxes/$SBID/exec" \
  -H 'Content-Type: application/json' \
  -d '{"cmd": ["pi", "--version"], "timeout_sec": 10}')
VERSION=$(echo "$VERIFY_RES" | python3 -c "import sys,json; r=json.load(sys.stdin); print((r.get('stdout','') or r.get('stderr','')).strip())")
log "pi: $VERSION"

# 5. Save the rootfs as an image.
# The bhatti API for save-image is POST /sandboxes/:id/save-image.
log "saving sandbox rootfs as image '$IMAGE_NAME' (a few seconds)"
SAVE_RES=$(curl_b -X POST "$BHATTI_URL/sandboxes/$SBID/save-image" \
  -H 'Content-Type: application/json' \
  -d "{\"name\": \"$IMAGE_NAME\"}")
echo "$SAVE_RES" | python3 -m json.tool >&2 || true

# 6. Verify the image now exists.
log "verifying image"
HAS=$(curl_b "$BHATTI_URL/images" \
  | python3 -c "
import sys, json
imgs = json.load(sys.stdin)
print('yes' if any(i.get('name') == '$IMAGE_NAME' for i in imgs) else 'no')")
[[ "$HAS" != "yes" ]] && { echo "save-image did not register '$IMAGE_NAME'"; exit 1; }

echo ""
echo "✓ image '$IMAGE_NAME' baked successfully."
echo ""
echo "Now add this to ~/Projects/karkhana/.env:"
echo "  KARKHANA_WORKER_IMAGE=$IMAGE_NAME"
echo ""
echo "Karkhana picks it up on next restart."
