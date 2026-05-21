#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  resume_single_task.sh --state STATE [--node NODE] [--container NAME] [--port PORT]
    [--timeout SECONDS] [--interval SECONDS] [--report-dir DIR] [--run-id ID] [--dry-run]

Purpose:
  Controlled resume after run_single_task.sh stops before benchmark, for example
  SERVICE_TIMEOUT, SERVICE_STARTED, or WAITING_READY.

Sequence:
  wait_vllm_ready.sh -> run_bench.sh -> render_report.py -> stop_service.sh
  -> render_report.py -> show_state.sh

It does not create containers, start services, run docker rm, or hand-write SSH/Docker/vLLM commands.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_CONTAINER_ROOT="${OUTPUT_CONTAINER_ROOT:-/mnt/skilltest/vllm-perf-validation-single}"
OUTPUT_HOST_ROOT="${OUTPUT_HOST_ROOT:-/public/home/liuzhh8/skilltest/vllm-perf-validation-single}"
SKILL_CONTAINER_ROOT="${SKILL_CONTAINER_ROOT:-/mnt/.claude/skills/vllm-perf-validation-single}"

STATE=""
NODE=""
CONTAINER=""
PORT=""
TIMEOUT=""
INTERVAL=60
REPORT_DIR=""
RUN_ID=""
DRY_RUN=0

to_host_path() {
  local path="$1"
  if [[ "$path" == "$OUTPUT_CONTAINER_ROOT"* ]]; then
    printf '%s%s\n' "$OUTPUT_HOST_ROOT" "${path#$OUTPUT_CONTAINER_ROOT}"
  else
    printf '%s\n' "$path"
  fi
}

to_container_path() {
  local path="$1"
  if [[ "$path" == "$OUTPUT_HOST_ROOT"* ]]; then
    printf '%s%s\n' "$OUTPUT_CONTAINER_ROOT" "${path#$OUTPUT_HOST_ROOT}"
  else
    printf '%s\n' "$path"
  fi
}

state_get() {
  local path="$1"
  python3 - "$STATE_HOST" "$path" <<'PY'
import json
import sys

state_file, dotted = sys.argv[1], sys.argv[2]
with open(state_file, "r", encoding="utf-8-sig") as f:
    data = json.load(f)
cur = data
for key in dotted.split("."):
    if not isinstance(cur, dict) or key not in cur:
        print("")
        sys.exit(0)
    cur = cur[key]
print(cur if cur is not None else "")
PY
}

extract_value() {
  local key="$1"
  local file="$2"
  grep -E "^${key}=" "$file" | tail -1 | cut -d= -f2-
}

run_step_capture() {
  local name="$1"
  local outfile="$2"
  shift 2
  echo "== ${name} =="
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY_RUN_STEP:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@" 2>&1 | tee "$outfile"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state) STATE="$2"; shift 2 ;;
    --node) NODE="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --report-dir) REPORT_DIR="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$STATE" ]] || { echo "missing --state" >&2; exit 2; }
STATE_HOST="$(to_host_path "$STATE")"
STATE_CONTAINER="$(to_container_path "$STATE")"
[[ -f "$STATE_HOST" || "$DRY_RUN" == "1" ]] || { echo "state file not found: $STATE_HOST" >&2; exit 2; }

if [[ "$DRY_RUN" != "1" ]]; then
  [[ -n "$NODE" ]] || NODE="$(state_get node)"
  [[ -n "$CONTAINER" ]] || CONTAINER="$(state_get container.name)"
  [[ -n "$PORT" ]] || PORT="$(state_get model.port)"
  LOG_CONTAINER="$(state_get paths.log_file_container)"
  [[ -n "$LOG_CONTAINER" ]] || LOG_CONTAINER="$(to_container_path "$(state_get paths.log_file)")"
  WORK_DIR_CONTAINER="$(state_get paths.work_dir_container)"
  [[ -n "$WORK_DIR_CONTAINER" ]] || WORK_DIR_CONTAINER="$(to_container_path "$(state_get paths.work_dir_host)")"
  CONTAINER_MODEL_PATH="$(state_get model.container_model_path)"
  TP="$(state_get model.tp)"
  TEST_MODE="$(state_get test.mode)"
  [[ -n "$TEST_MODE" ]] || TEST_MODE="custom"
  [[ -n "$TIMEOUT" ]] || TIMEOUT="$(state_get timing.readiness_timeout_seconds)"
  [[ -n "$TIMEOUT" ]] || TIMEOUT=3600
  if [[ -z "$REPORT_DIR" ]]; then
    REPORT_DIR="${OUTPUT_HOST_ROOT}/reports"
  fi
  if [[ -z "$RUN_ID" ]]; then
    RUN_ID="$(basename "$(dirname "$STATE_HOST")")"
  fi
else
  NODE="${NODE:-<NODE>}"
  CONTAINER="${CONTAINER:-<CONTAINER>}"
  PORT="${PORT:-<PORT>}"
  LOG_CONTAINER="<LOG_CONTAINER_FROM_STATE>"
  WORK_DIR_CONTAINER="<WORK_DIR_CONTAINER_FROM_STATE>"
  CONTAINER_MODEL_PATH="<CONTAINER_MODEL_PATH_FROM_STATE>"
  TP="<TP_FROM_STATE>"
  TEST_MODE="custom"
  TIMEOUT="${TIMEOUT:-3600}"
  REPORT_DIR="${REPORT_DIR:-${OUTPUT_HOST_ROOT}/reports}"
  RUN_ID="${RUN_ID:-<RUN_ID_FROM_STATE>}"
fi

for var in NODE CONTAINER PORT LOG_CONTAINER WORK_DIR_CONTAINER CONTAINER_MODEL_PATH TP TEST_MODE TIMEOUT REPORT_DIR RUN_ID; do
  [[ -n "${!var}" ]] || { echo "state missing required field: ${var}" >&2; exit 2; }
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

run_step_capture "resume_wait_vllm_ready" "$TMP_DIR/wait.out" \
  env VERBOSE=1 SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" \
    bash "$SCRIPT_DIR/wait_vllm_ready.sh" \
      --node "$NODE" \
      --container "$CONTAINER" \
      --port "$PORT" \
      --log "$LOG_CONTAINER" \
      --model-path "$CONTAINER_MODEL_PATH" \
      --state "$STATE_CONTAINER" \
      --timeout "$TIMEOUT" \
      --interval "$INTERVAL"

if [[ "$DRY_RUN" == "1" ]]; then
  SERVED_MODEL_ID="<SERVED_MODEL_ID_FROM_WAIT>"
else
  SERVED_MODEL_ID="$(extract_value SERVED_MODEL_ID "$TMP_DIR/wait.out")"
fi
[[ -n "$SERVED_MODEL_ID" ]] || { echo "wait_vllm_ready did not output SERVED_MODEL_ID" >&2; exit 1; }

run_step_capture "resume_run_bench" "$TMP_DIR/bench.out" \
  env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" \
    OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" \
    OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" \
    bash "$SCRIPT_DIR/run_bench.sh" \
      --node "$NODE" \
      --container "$CONTAINER" \
      --test-mode "$TEST_MODE" \
      --served-model-id "$SERVED_MODEL_ID" \
      --port "$PORT" \
      --tp "$TP" \
      --work-dir "$WORK_DIR_CONTAINER" \
      --state "$STATE_CONTAINER"

if [[ "$DRY_RUN" == "1" ]]; then
  CSV_HOST="<CSV_HOST_FROM_BENCH>"
else
  CSV_HOST="$(extract_value CSV_HOST "$TMP_DIR/bench.out")"
fi
[[ -n "$CSV_HOST" ]] || { echo "run_bench did not output CSV_HOST" >&2; exit 1; }

run_step_capture "resume_render_report_before_stop" "$TMP_DIR/report_before.out" \
  python3 "$SCRIPT_DIR/render_report.py" \
    --run-id "$RUN_ID" \
    --state "$STATE_HOST" \
    --csv "$CSV_HOST" \
    --report-dir "$REPORT_DIR"

run_step_capture "resume_stop_service" "$TMP_DIR/stop.out" \
  env SKILL_HOST_ROOT="$SKILL_ROOT" \
    OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" \
    OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" \
    bash "$SCRIPT_DIR/stop_service.sh" \
      --node "$NODE" \
      --container "$CONTAINER" \
      --port "$PORT" \
      --state "$STATE_HOST"

run_step_capture "resume_render_report_final" "$TMP_DIR/report_final.out" \
  python3 "$SCRIPT_DIR/render_report.py" \
    --run-id "$RUN_ID" \
    --state "$STATE_HOST" \
    --csv "$CSV_HOST" \
    --report-dir "$REPORT_DIR"

run_step_capture "resume_show_state" "$TMP_DIR/show_state.out" \
  bash "$SCRIPT_DIR/show_state.sh" --state "$STATE_HOST"
