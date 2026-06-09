#!/usr/bin/env bash
set -euo pipefail
usage() { echo "Usage: start_mooncake_proxy.sh --node NODE --container NAME --work-dir WORK_DIR --state STATE --prefill-url URL --prefill-transfer-port PORT --decode-url URL --port PORT --mooncake-proxy-script PATH [--dry-run]"; }
quote_sh() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
run_in_container() {
  local script="$1" docker_cmd
  docker_cmd="docker exec -i -w $(quote_sh "$SKILL_CONTAINER_ROOT") $(quote_sh "$CONTAINER") bash -ic 'tmp=/tmp/vllm_pd_proxy_\$\$.sh; cat > \"\$tmp\"; bash \"\$tmp\"; rc=\$?; rm -f \"\$tmp\"; exit \$rc'"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "即将在容器内启动 Mooncake proxy:"
    printf 'ssh %q %q\n' "$NODE" "$docker_cmd"
    echo "--- container script ---"
    printf '%s\n' "$script"
  else
    printf '%s\n' "$script" | ssh "$NODE" "$docker_cmd"
  fi
}
NODE=""; CONTAINER=""; WORK_DIR=""; STATE=""; PREFILL_URL=""; PREFILL_TRANSFER_PORT=""; DECODE_URL=""; PORT=""; MOONCAKE_PROXY_SCRIPT=""; DRY_RUN=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime_config.sh"
SKILL_USER=""; USER_ABBR=""; HOME_ROOT=""; HOST_HOME_ROOT=""; SKILL_HOST_ROOT=""; OUTPUT_HOST_ROOT="${OUTPUT_HOST_ROOT:-}"; OUTPUT_CONTAINER_ROOT="${OUTPUT_CONTAINER_ROOT:-}"; CONTAINER_PREFIX=""
while [[ $# -gt 0 ]]; do
  if runtime_config_parse_common_arg "$1" "${2-}"; then shift 2; continue; fi
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --work-dir) WORK_DIR="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --prefill-url) PREFILL_URL="$2"; shift 2 ;;
    --prefill-transfer-port) PREFILL_TRANSFER_PORT="$2"; shift 2 ;;
    --decode-url) DECODE_URL="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --mooncake-proxy-script) MOONCAKE_PROXY_SCRIPT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
for var in NODE CONTAINER WORK_DIR STATE PREFILL_URL PREFILL_TRANSFER_PORT DECODE_URL PORT MOONCAKE_PROXY_SCRIPT; do [[ -n "${!var}" ]] || { echo "missing argument: $var" >&2; exit 2; }; done
resolve_runtime_config
PROXY_SCRIPT="${SKILL_CONTAINER_ROOT%/}/${MOONCAKE_PROXY_SCRIPT#./}"
LOG="${WORK_DIR}/logs/mooncake-proxy-${PORT}.log"; PID="${WORK_DIR}/logs/mooncake-proxy-${PORT}.pid"
remote_script=$(cat <<EOF
set -euo pipefail
WORK_DIR=$(quote_sh "$WORK_DIR"); STATE=$(quote_sh "$STATE"); PROXY_SCRIPT=$(quote_sh "$PROXY_SCRIPT"); LOG=$(quote_sh "$LOG"); PID=$(quote_sh "$PID")
PREFILL_URL=$(quote_sh "$PREFILL_URL"); PREFILL_TRANSFER_PORT=$(quote_sh "$PREFILL_TRANSFER_PORT"); DECODE_URL=$(quote_sh "$DECODE_URL"); PORT=$(quote_sh "$PORT"); SKILL_CONTAINER_ROOT=$(quote_sh "$SKILL_CONTAINER_ROOT")
mkdir -p "\$WORK_DIR/logs"
if [[ ! -f "\$PROXY_SCRIPT" ]]; then
  python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" --set "pd.proxy.status=FAILED" --set "failure.reason=mooncake_proxy_script_missing" --set "failure.detail=\$PROXY_SCRIPT"
  echo "MOONCAKE_PROXY_SCRIPT_MISSING: \$PROXY_SCRIPT" >&2
  exit 1
fi
rm -f "\$LOG" "\$PID"; START_TS=\$(date +%s)
python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" --set "pd.proxy.status=STARTING" --set "pd.proxy.node=$(printf '%s' "$NODE")" --set "pd.proxy.container=$(printf '%s' "$CONTAINER")" --set "pd.proxy.port=\$PORT" --set "pd.proxy.prefill_url=\$PREFILL_URL" --set "pd.proxy.prefill_transfer_port=\$PREFILL_TRANSFER_PORT" --set "pd.proxy.decode_url=\$DECODE_URL" --set "pd.proxy.log_file=\$LOG" --set "pd.proxy.pid_file=\$PID"
nohup python3 "\$PROXY_SCRIPT" --prefill "\$PREFILL_URL" "\$PREFILL_TRANSFER_PORT" --decode "\$DECODE_URL" --port "\$PORT" > "\$LOG" 2>&1 &
echo \$! > "\$PID"
python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" --set "pd.proxy.status=STARTED" --set "pd.proxy.pid=\$(cat "\$PID")" --set "pd.proxy.startup_duration_seconds=\$((\$(date +%s) - START_TS))"
sleep 3
echo "PROXY_LOG_CONTAINER=\$LOG"; echo "PROXY_PID_CONTAINER=\$PID"; tail -120 "\$LOG" || true
EOF
)
run_in_container "$remote_script"
