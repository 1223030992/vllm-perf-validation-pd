#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: start_mooncake_proxy.sh --node NODE --container NAME --launcher-script PATH --work-dir WORK_DIR --state STATE --prefill-url URL --prefill-transfer-port PORT --decode-url URL --port PORT --mooncake-proxy-script PATH [--dry-run]"
}

quote_sh() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
run_in_container() {
  local script="$1" docker_cmd
  docker_cmd="docker exec -i -w $(quote_sh "$SKILL_CONTAINER_ROOT") $(quote_sh "$CONTAINER") bash -lc 'tmp=/tmp/vllm_pd_proxy_\$\$.sh; cat > \"\$tmp\"; bash \"\$tmp\"; rc=\$?; rm -f \"\$tmp\"; exit \$rc'"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN_PROXY=1"
    printf 'ssh %q %q\n' "$NODE" "$docker_cmd"
    echo "--- container script ---"
    printf '%s\n' "$script"
    return 0
  fi
  printf '%s\n' "$script" | ssh "$NODE" "$docker_cmd"
}

NODE=""; CONTAINER=""; LAUNCHER_SCRIPT_REL=""; WORK_DIR=""; STATE=""; PREFILL_URL=""
PREFILL_TRANSFER_PORT=""; DECODE_URL=""; PORT=""; MOONCAKE_PROXY_SCRIPT_REL=""; DRY_RUN=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime_config.sh"
SKILL_USER=""; USER_ABBR=""; HOME_ROOT=""; HOST_HOME_ROOT=""; SKILL_HOST_ROOT=""
OUTPUT_HOST_ROOT="${OUTPUT_HOST_ROOT:-}"; OUTPUT_CONTAINER_ROOT="${OUTPUT_CONTAINER_ROOT:-}"; CONTAINER_PREFIX=""

while [[ $# -gt 0 ]]; do
  if runtime_config_parse_common_arg "$1" "${2-}"; then shift 2; continue; fi
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --launcher-script) LAUNCHER_SCRIPT_REL="$2"; shift 2 ;;
    --work-dir) WORK_DIR="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --prefill-url) PREFILL_URL="$2"; shift 2 ;;
    --prefill-transfer-port) PREFILL_TRANSFER_PORT="$2"; shift 2 ;;
    --decode-url) DECODE_URL="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --mooncake-proxy-script) MOONCAKE_PROXY_SCRIPT_REL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "unknown_arg=$1" >&2; usage; exit 2 ;;
  esac
done
for var in NODE CONTAINER LAUNCHER_SCRIPT_REL WORK_DIR STATE PREFILL_URL PREFILL_TRANSFER_PORT DECODE_URL PORT MOONCAKE_PROXY_SCRIPT_REL; do
  [[ -n "${!var}" ]] || { echo "missing_arg=$var" >&2; exit 2; }
done
resolve_runtime_config

LAUNCHER_SCRIPT="${SKILL_CONTAINER_ROOT%/}/${LAUNCHER_SCRIPT_REL#./}"
PROXY_SCRIPT="${SKILL_CONTAINER_ROOT%/}/${MOONCAKE_PROXY_SCRIPT_REL#./}"
LOG="${WORK_DIR}/logs/mooncake-proxy-${PORT}.log"
PID="${WORK_DIR}/logs/mooncake-proxy-${PORT}.pid"
remote_script=$(cat <<EOF
set -euo pipefail
WORK_DIR=$(quote_sh "$WORK_DIR"); STATE=$(quote_sh "$STATE"); LAUNCHER_SCRIPT=$(quote_sh "$LAUNCHER_SCRIPT")
PROXY_SCRIPT=$(quote_sh "$PROXY_SCRIPT"); LOG=$(quote_sh "$LOG"); PID=$(quote_sh "$PID")
PREFILL_URL=$(quote_sh "$PREFILL_URL"); PREFILL_TRANSFER_PORT=$(quote_sh "$PREFILL_TRANSFER_PORT")
DECODE_URL=$(quote_sh "$DECODE_URL"); PORT=$(quote_sh "$PORT"); SKILL_CONTAINER_ROOT=$(quote_sh "$SKILL_CONTAINER_ROOT")
mkdir -p "\$WORK_DIR/logs"
for required_file in "\$LAUNCHER_SCRIPT" "\$PROXY_SCRIPT"; do
  if [[ ! -f "\$required_file" ]]; then
    python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" --set "status=PROXY_FAILED" --set "pd.proxy.status=FAILED" --set "failure.reason=proxy_script_missing" --set "failure.detail=\$required_file"
    echo "PROXY_SCRIPT_MISSING=\$required_file" >&2
    exit 1
  fi
done
rm -f "\$LOG" "\$PID"
START_TS=\$(date +%s)
python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" --set "status=PROXY_STARTING" --set "pd.proxy.status=STARTING" --set "pd.proxy.node=$(printf '%s' "$NODE")" --set "pd.proxy.container=$(printf '%s' "$CONTAINER")" --set "pd.proxy.port=\$PORT" --set "pd.proxy.prefill_url=\$PREFILL_URL" --set "pd.proxy.prefill_transfer_port=\$PREFILL_TRANSFER_PORT" --set "pd.proxy.decode_url=\$DECODE_URL" --set "pd.proxy.launcher_script=\$LAUNCHER_SCRIPT" --set "pd.proxy.log_file=\$LOG" --set "pd.proxy.pid_file=\$PID"
nohup bash "\$LAUNCHER_SCRIPT" --proxy-script "\$PROXY_SCRIPT" --prefill-url "\$PREFILL_URL" --prefill-transfer-port "\$PREFILL_TRANSFER_PORT" --decode-url "\$DECODE_URL" --port "\$PORT" > "\$LOG" 2>&1 &
echo \$! > "\$PID"
python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" --set "pd.proxy.status=STARTED" --set "pd.proxy.pid=\$(cat "\$PID")" --set "pd.proxy.startup_duration_seconds=\$((\$(date +%s) - START_TS))"
sleep 3
echo "PROXY_LOG_CONTAINER=\$LOG"; echo "PROXY_PID_CONTAINER=\$PID"; tail -120 "\$LOG" || true
EOF
)
run_in_container "$remote_script"
