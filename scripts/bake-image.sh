#!/usr/bin/env bash
# bake-image.sh — one-shot bootstrap for the kk-base bhatti image.
#
# Boots a temporary computer-tier sandbox, installs everything a
# Karkhana worker needs, then snapshots the rootfs as a reusable
# bhatti image (default name: kk-base). Subsequent worker spawns
# just restore the snapshot — pi is already there, scrot/xdotool
# are already there, the computer-use extension is already there,
# spawn time drops from ~30s to ~2s.
#
# Layers baked:
#   1. apt:  scrot, xdotool, wmctrl  (computer-use tool deps)
#   2. npm:  @mariozechner/pi-coding-agent  (the agent itself)
#   3. files: extensions/computer-use/  (Karkhana's GUI tools)
#       - uploaded via bhatti's PUT /sandboxes/:id/files API
#       - npm install --omit=dev inside the extension dir to
#         resolve typebox
#
# Idempotent: if the image already exists, exits early (use
# --force to rebuild).
#
# Usage:
#   ./scripts/bake-image.sh                  # default: kk-base
#   ./scripts/bake-image.sh --name my-image  # custom name
#   ./scripts/bake-image.sh --force          # rebuild even if exists
#   ./scripts/bake-image.sh --skip-extension # bake pi only (no GUI tools)

set -euo pipefail

IMAGE_NAME="kk-base"
FORCE=0
SKIP_EXTENSION=0
PI_PACKAGE="@mariozechner/pi-coding-agent"

# Where the extension lives in the repo and where it goes in the
# image. The driver passes this same in-image path via --extension
# (see pkg/config/config.go for the default).
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
EXTENSION_LOCAL_DIR="$REPO_ROOT/extensions/computer-use"
EXTENSION_REMOTE_DIR="/usr/local/share/karkhana/extensions/computer-use"

while [[ $# -gt 0 ]]; do
  case $1 in
    --name) IMAGE_NAME="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --skip-extension) SKIP_EXTENSION=1; shift ;;
    --pi-package) PI_PACKAGE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- bhatti credentials & helpers ---

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

# Run a command inside the sandbox. Args after $1 (sandbox id)
# are the argv. Echoes stdout. Exits non-zero on failure.
remote_exec() {
  local sbid="$1"; shift
  local timeout="${REMOTE_TIMEOUT:-60}"
  local cmd_json
  cmd_json=$(python3 -c "import json,sys; print(json.dumps({'cmd': sys.argv[1:], 'timeout_sec': int('$timeout')}))" "$@")
  local res
  res=$(curl_b -X POST "$BHATTI_URL/sandboxes/$sbid/exec" \
         -H 'Content-Type: application/json' -d "$cmd_json")
  local exit_code stdout stderr
  exit_code=$(echo "$res" | python3 -c "import sys,json; print(json.load(sys.stdin).get('exit_code',-1))")
  stdout=$(echo "$res" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stdout',''))")
  stderr=$(echo "$res" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stderr',''))")
  if [[ "$exit_code" != "0" ]]; then
    echo "remote_exec failed (exit=$exit_code): $*" >&2
    [[ -n "$stdout" ]] && echo "  stdout: $stdout" >&2
    [[ -n "$stderr" ]] && echo "  stderr: $stderr" >&2
    return 1
  fi
  printf '%s' "$stdout"
}

# Upload a local file into the sandbox at the given remote path.
# Uses bhatti's PUT /sandboxes/:id/files?path=... API. Atomic
# write (temp + rename) per bhatti's contract.
remote_put_file() {
  local sbid="$1" local_path="$2" remote_path="$3"
  if [[ ! -f "$local_path" ]]; then
    echo "remote_put_file: local file missing: $local_path" >&2
    return 1
  fi
  local size
  size=$(wc -c < "$local_path" | tr -d ' ')
  # URL-encode the remote path (only really matters if path has spaces).
  local encoded
  encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe='/'))" "$remote_path")
  curl -sS -X PUT \
    -H "Authorization: Bearer $BHATTI_TOKEN" \
    -H "Content-Type: application/octet-stream" \
    -H "Content-Length: $size" \
    --data-binary "@$local_path" \
    "$BHATTI_URL/sandboxes/$sbid/files?path=$encoded" >/dev/null
}

# --- 1. handle pre-existing image ---
#
# Bhatti's POST /sandboxes/:id/save-image refuses to overwrite an
# existing image — it returns:
#   {"error": "image \"X\" already exists — delete first"}
# So when --force is set we DELETE the existing one first via
# DELETE /images/:name. Without --force, we exit early so a
# stale image isn't silently replaced.

HAS=$(curl_b "$BHATTI_URL/images" \
  | python3 -c "
import sys, json
try:    imgs = json.load(sys.stdin)
except: imgs = []
print('yes' if any(i.get('name') == '$IMAGE_NAME' for i in imgs) else 'no')")

if [[ "$HAS" == "yes" ]]; then
  if [[ $FORCE -eq 0 ]]; then
    echo "image '$IMAGE_NAME' already exists. use --force to rebuild." >&2
    echo "(set KARKHANA_WORKER_IMAGE=$IMAGE_NAME in .env to use it)" >&2
    exit 0
  fi
  log "--force set; deleting existing image '$IMAGE_NAME' first"
  DEL_RES=$(curl_b -X DELETE "$BHATTI_URL/images/$IMAGE_NAME" -w "\n%{http_code}")
  HTTP_CODE=$(echo "$DEL_RES" | tail -1)
  if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "204" && "$HTTP_CODE" != "404" ]]; then
    echo "image delete returned $HTTP_CODE; aborting:" >&2
    echo "$DEL_RES" | head -1 >&2
    exit 1
  fi
fi

# --- 2. spin up build sandbox ---

if [[ $SKIP_EXTENSION -eq 0 ]]; then
  if [[ ! -f "$EXTENSION_LOCAL_DIR/index.ts" || ! -f "$EXTENSION_LOCAL_DIR/package.json" ]]; then
    echo "error: extension files missing in $EXTENSION_LOCAL_DIR" >&2
    echo "       (use --skip-extension to bake without computer-use tools)" >&2
    exit 1
  fi
fi

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

# Wait until running.
for _ in $(seq 1 30); do
  ST=$(curl_b "$BHATTI_URL/sandboxes/$SBID" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))")
  [[ "$ST" == "running" ]] && break
  sleep 1
done
log "status: $ST"
[[ "$ST" != "running" ]] && { echo "sandbox didn't reach running"; exit 1; }

# --- 3. apt: install GUI automation deps ---

if [[ $SKIP_EXTENSION -eq 0 ]]; then
  log "apt-installing scrot xdotool wmctrl (GUI automation deps)"
  REMOTE_TIMEOUT=120 remote_exec "$SBID" \
    sudo apt-get update -qq >/dev/null
  REMOTE_TIMEOUT=180 remote_exec "$SBID" \
    sudo apt-get install -y -qq scrot xdotool wmctrl >/dev/null
  log "verifying tools available"
  remote_exec "$SBID" which scrot xdotool wmctrl >/dev/null
fi

# --- 4. npm: install pi-coding-agent globally ---

log "installing $PI_PACKAGE globally (~30s)"
REMOTE_TIMEOUT=240 remote_exec "$SBID" \
  sudo npm install -g --silent "$PI_PACKAGE" >/dev/null
log "verifying pi"
PI_VER=$(remote_exec "$SBID" pi --version 2>/dev/null | head -1)
log "pi: $PI_VER"

# --- 5. files: upload computer-use extension + npm install its deps ---

if [[ $SKIP_EXTENSION -eq 0 ]]; then
  log "creating extension dir: $EXTENSION_REMOTE_DIR"
  REMOTE_TIMEOUT=10 remote_exec "$SBID" \
    sudo mkdir -p "$EXTENSION_REMOTE_DIR" >/dev/null
  # Make it world-writable just for the upload step; we'll lock
  # it down after npm install finishes.
  REMOTE_TIMEOUT=10 remote_exec "$SBID" \
    sudo chmod 0777 "$EXTENSION_REMOTE_DIR" >/dev/null

  log "uploading extension files"
  remote_put_file "$SBID" "$EXTENSION_LOCAL_DIR/index.ts"     "$EXTENSION_REMOTE_DIR/index.ts"
  remote_put_file "$SBID" "$EXTENSION_LOCAL_DIR/package.json" "$EXTENSION_REMOTE_DIR/package.json"
  if [[ -f "$EXTENSION_LOCAL_DIR/README.md" ]]; then
    remote_put_file "$SBID" "$EXTENSION_LOCAL_DIR/README.md" "$EXTENSION_REMOTE_DIR/README.md"
  fi

  log "installing extension deps (typebox)"
  REMOTE_TIMEOUT=120 remote_exec "$SBID" \
    bash -c "cd $EXTENSION_REMOTE_DIR && sudo npm install --omit=dev --silent" >/dev/null

  log "verifying extension loads via pi"
  # `pi --extension <path> --version` exercises the extension
  # loader without dropping into the agent loop. If the
  # extension throws on load we'll see it here, before bake.
  if ! REMOTE_TIMEOUT=20 remote_exec "$SBID" \
       pi --extension "$EXTENSION_REMOTE_DIR/index.ts" --version >/dev/null 2>&1; then
    echo "warning: pi --extension <path> --version failed. The image is still" >&2
    echo "         being baked, but the extension may not load at runtime." >&2
    echo "         Check pi's log on the next mission spawn." >&2
  fi

  REMOTE_TIMEOUT=10 remote_exec "$SBID" \
    sudo chmod -R 0755 "$EXTENSION_REMOTE_DIR" >/dev/null || true
fi

# --- 6. snapshot the rootfs ---

log "saving sandbox rootfs as image '$IMAGE_NAME'"
SAVE_RES=$(curl_b -X POST "$BHATTI_URL/sandboxes/$SBID/save-image" \
  -H 'Content-Type: application/json' \
  -d "{\"name\": \"$IMAGE_NAME\"}")
# bhatti returns {"error": "..."} on save failure; don't claim
# success in that case.
if echo "$SAVE_RES" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'error' in d else 1)" 2>/dev/null; then
  echo "save-image failed:" >&2
  echo "$SAVE_RES" | python3 -m json.tool >&2 || echo "$SAVE_RES" >&2
  exit 1
fi
echo "$SAVE_RES" | python3 -m json.tool >&2 || true

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
if [[ $SKIP_EXTENSION -eq 0 ]]; then
  echo "  Includes: pi + scrot + xdotool + wmctrl + computer-use extension"
else
  echo "  Includes: pi only (no computer-use extension)"
fi
echo ""
echo "Now add this to ~/Projects/karkhana/.env:"
echo "  KARKHANA_WORKER_IMAGE=$IMAGE_NAME"
echo ""
echo "Karkhana picks it up on next restart."
