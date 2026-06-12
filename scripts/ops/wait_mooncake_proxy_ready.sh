#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: wait_mooncake_proxy_ready.sh --node NODE --container NAME --port PORT --state STATE --log LOG --model-id ID --prefill-url URL --prefill-transfer-port PORT --decode-url URL [--timeout SECONDS] [--request-timeout SECONDS] [--interval SECONDS] [--dry-run]"
}

quote_sh() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
NODE=""; CONTAINER=""; PORT=""; STATE=""; LOG=""; MODEL_ID=""; PREFILL_URL=""; PREFILL_TRANSFER_PORT=""; DECODE_URL=""
TIMEOUT=600; REQUEST_TIMEOUT=180; INTERVAL=10; DRY_RUN=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime_config.sh"
SKILL_USER=""; USER_ABBR=""; HOME_ROOT=""; HOST_HOME_ROOT=""; SKILL_HOST_ROOT=""
OUTPUT_HOST_ROOT="${OUTPUT_HOST_ROOT:-}"; OUTPUT_CONTAINER_ROOT="${OUTPUT_CONTAINER_ROOT:-}"; CONTAINER_PREFIX=""
while [[ $# -gt 0 ]]; do
  if runtime_config_parse_common_arg "$1" "${2-}"; then shift 2; continue; fi
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --log) LOG="$2"; shift 2 ;;
    --model-id) MODEL_ID="$2"; shift 2 ;;
    --prefill-url) PREFILL_URL="$2"; shift 2 ;;
    --prefill-transfer-port) PREFILL_TRANSFER_PORT="$2"; shift 2 ;;
    --decode-url) DECODE_URL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --request-timeout) REQUEST_TIMEOUT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "unknown_arg=$1" >&2; usage; exit 2 ;;
  esac
done
for var in NODE CONTAINER PORT STATE LOG MODEL_ID PREFILL_URL PREFILL_TRANSFER_PORT DECODE_URL; do
  [[ -n "${!var}" ]] || { echo "missing_arg=$var" >&2; exit 2; }
done
resolve_runtime_config

remote_script=$(cat <<EOF
set -euo pipefail
PORT=$(quote_sh "$PORT"); STATE=$(quote_sh "$STATE"); LOG=$(quote_sh "$LOG"); MODEL_ID=$(quote_sh "$MODEL_ID")
PREFILL_URL=$(quote_sh "$PREFILL_URL"); PREFILL_TRANSFER_PORT=$(quote_sh "$PREFILL_TRANSFER_PORT"); DECODE_URL=$(quote_sh "$DECODE_URL")
TIMEOUT=$(quote_sh "$TIMEOUT"); REQUEST_TIMEOUT=$(quote_sh "$REQUEST_TIMEOUT"); INTERVAL=$(quote_sh "$INTERVAL")
SKILL_CONTAINER_ROOT=$(quote_sh "$SKILL_CONTAINER_ROOT"); PID_FILE=\${LOG%.log}.pid
python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/proxy_readiness.py" \
  --state "\$STATE" --log "\$LOG" --pid-file "\$PID_FILE" \
  --proxy-url "http://127.0.0.1:\$PORT" --prefill-url "\$PREFILL_URL" \
  --prefill-transfer-port "\$PREFILL_TRANSFER_PORT" --decode-url "\$DECODE_URL" \
  --model-id "\$MODEL_ID" --timeout "\$TIMEOUT" --request-timeout "\$REQUEST_TIMEOUT" \
  --interval "\$INTERVAL"
EOF
)

docker_cmd="docker exec -i $(quote_sh "$CONTAINER") bash -lc 'tmp=/tmp/vllm_pd_wait_proxy_\$\$.sh; cat > \"\$tmp\"; bash \"\$tmp\"; rc=\$?; rm -f \"\$tmp\"; exit \$rc'"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY_RUN_WAIT_PROXY=1"
  printf 'ssh %q %q\n' "$NODE" "$docker_cmd"
  echo "--- container script ---"
  printf '%s\n' "$remote_script"
else
  printf '%s\n' "$remote_script" | ssh "$NODE" "$docker_cmd"
fi
