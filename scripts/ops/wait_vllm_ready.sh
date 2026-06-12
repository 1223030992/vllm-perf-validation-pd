#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  wait_vllm_ready.sh --role prefill|decode --node NODE --container NAME \
    --port PORT --log LOG --model-path PATH [--state STATE] \
    [--timeout SECONDS] [--interval SECONDS] [--dry-run]
USAGE
}

quote_sh() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
run_in_container() {
  local script="$1" docker_cmd
  docker_cmd="docker exec -i $(quote_sh "$CONTAINER") bash -lc 'tmp=/tmp/vllm_ops_wait_\$\$.sh; cat > \"\$tmp\"; bash \"\$tmp\"; rc=\$?; rm -f \"\$tmp\"; exit \$rc'"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN_WAIT_ROLE=$ROLE"
    printf 'ssh %q %q\n' "$NODE" "$docker_cmd"
    echo "--- container script ---"
    printf '%s\n' "$script"
    return 0
  fi
  printf '%s\n' "$script" | ssh "$NODE" "$docker_cmd"
}

ROLE=""; NODE=""; CONTAINER=""; PORT=""; LOG=""; MODEL_PATH=""; STATE=""
TIMEOUT=1800; INTERVAL=30; DRY_RUN=0
SKILL_CONTAINER_ROOT="${SKILL_CONTAINER_ROOT:-/mnt/.claude/skills/vllm-perf-validation-pd}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --node) NODE="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --log) LOG="$2"; shift 2 ;;
    --model-path) MODEL_PATH="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "unknown_arg=$1" >&2; usage; exit 2 ;;
  esac
done
for var in ROLE NODE CONTAINER PORT LOG MODEL_PATH; do
  [[ -n "${!var}" ]] || { echo "missing_arg=$var" >&2; exit 2; }
done
[[ "$ROLE" == "prefill" || "$ROLE" == "decode" ]] || { echo "invalid_role=$ROLE" >&2; exit 2; }
[[ -n "$STATE" ]] || STATE="$(dirname "$(dirname "$LOG")")/state.json"

remote_script=$(cat <<EOF
set -euo pipefail
ROLE=$(quote_sh "$ROLE"); PORT=$(quote_sh "$PORT"); LOG=$(quote_sh "$LOG"); MODEL_PATH=$(quote_sh "$MODEL_PATH")
STATE=$(quote_sh "$STATE"); TIMEOUT=$(quote_sh "$TIMEOUT"); INTERVAL=$(quote_sh "$INTERVAL")
SKILL_CONTAINER_ROOT=$(quote_sh "$SKILL_CONTAINER_ROOT"); PID_FILE=\${LOG%.log}.pid
FAIL_RE='Traceback|ImportError|ModuleNotFoundError|RuntimeError|Killed|OOM|out[[:space:]]of[[:space:]]memory|hipError|ROCm[[:space:]]error'
START_TS=\$(date +%s); LAST_LOG=""; LAST_HEALTH_CODE=""; LAST_MODELS_JSON=""

classify_log_failure() {
  local text="\$1"
  if printf '%s' "\$text" | grep -Eqi 'Please install mooncake|No module named .mooncake|mooncake_transfer_engine'; then
    printf '%s\n' mooncake_transfer_engine_missing
  elif printf '%s' "\$text" | grep -Eqi 'ModuleNotFoundError|ImportError|No module named'; then
    printf '%s\n' python_dependency_missing
  elif printf '%s' "\$text" | grep -Eqi 'out[[:space:]]of[[:space:]]memory|OOM|Killed'; then
    printf '%s\n' out_of_memory
  else
    printf '%s\n' log_failure_signal
  fi
}

record_role_failure() {
  local reason="\$1" summary
  summary=\$(printf '%s\n' "\$LAST_LOG" | tail -40 | head -c 4000)
  python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" \
    --set "status=SERVICE_FAILED" --set "pd.roles.\$ROLE.status=FAILED" \
    --set "failure.reason=\$reason" --set "failure.detail=\$ROLE" \
    --set "pd.roles.\$ROLE.log_tail=\$summary"
}

python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" --set "status=WAITING_READY" --set "pd.roles.\$ROLE.status=WAITING_READY" --set "pd.roles.\$ROLE.readiness_start_epoch=\$START_TS" --set "pd.roles.\$ROLE.readiness_timeout_seconds=\$TIMEOUT"

while true; do
  ELAPSED=\$((\$(date +%s) - START_TS))
  LOG_TAIL=\$(tail -100 "\$LOG" 2>/dev/null || true); LAST_LOG="\$LOG_TAIL"

  if [[ "\$LOG_TAIL" =~ \$FAIL_RE ]]; then
    REASON=\$(classify_log_failure "\$LOG_TAIL")
    record_role_failure "\$REASON"
    echo "SERVICE_LOG_FAILURE role=\$ROLE reason=\$REASON" >&2; echo "\$LOG_TAIL"; exit 1
  fi
  if [[ -f "\$PID_FILE" ]]; then
    PID=\$(cat "\$PID_FILE" 2>/dev/null || true)
    if [[ -n "\$PID" ]] && ! kill -0 "\$PID" 2>/dev/null; then
      REASON=\$(classify_log_failure "\$LOG_TAIL")
      [[ "\$REASON" != "log_failure_signal" ]] || REASON=service_process_exited
      record_role_failure "\$REASON"
      echo "SERVICE_PROCESS_EXITED role=\$ROLE reason=\$REASON" >&2; echo "\$LOG_TAIL"; exit 1
    fi
  fi

  HEALTH_CODE=\$(curl -sS -m 10 -o /tmp/vllm-health-\$ROLE.txt -w '%{http_code}' "http://127.0.0.1:\$PORT/health" 2>/dev/null || true)
  MODELS_JSON=\$(curl -sS -m 10 "http://127.0.0.1:\$PORT/v1/models" 2>/dev/null || true)
  LAST_HEALTH_CODE="\$HEALTH_CODE"; LAST_MODELS_JSON="\$MODELS_JSON"
  SERVED_MODEL_ID=\$(MODELS_JSON="\$MODELS_JSON" python3 - <<'PY' 2>/dev/null
import json
import os
try:
    rows = json.loads(os.environ.get("MODELS_JSON", "")).get("data") or []
    print(rows[0].get("id", "") if rows else "")
except Exception:
    print("")
PY
)

  if [[ "\$HEALTH_CODE" == "200" && -n "\$SERVED_MODEL_ID" ]]; then
    python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" --set "status=ROLE_READY" --set "pd.roles.\$ROLE.status=READY" --set "pd.roles.\$ROLE.health_code=200" --set "pd.roles.\$ROLE.served_model_id=\$SERVED_MODEL_ID" --set "pd.roles.\$ROLE.models_json_summary=\$MODELS_JSON" --set "pd.roles.\$ROLE.readiness_duration_seconds=\$ELAPSED"
    echo "ROLE_READY=\$ROLE"; echo "SERVED_MODEL_ID=\$SERVED_MODEL_ID"; exit 0
  fi

  if (( ELAPSED >= TIMEOUT )); then
    python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" --set "status=SERVICE_TIMEOUT" --set "pd.roles.\$ROLE.status=TIMEOUT" --set "pd.roles.\$ROLE.health_code=\$LAST_HEALTH_CODE" --set "pd.roles.\$ROLE.models_json_summary=\$LAST_MODELS_JSON" --set "failure.reason=readiness_timeout" --set "failure.detail=\$ROLE"
    echo "SERVICE_READY_TIMEOUT role=\$ROLE elapsed=\$ELAPSED" >&2; echo "\$LAST_LOG"; exit 1
  fi
  sleep "\$INTERVAL"
done
EOF
)

run_in_container "$remote_script"
