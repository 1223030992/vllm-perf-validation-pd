#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  pchit_warmup.sh --node NODE --container NAME --served-model-id ID --port PORT --tp TP \
    --work-dir WORK_DIR --state STATE --log LOG --input-len LEN --output-len LEN \
    --pc-hit-target PCT --warmup-cache-hit-rates "92,95" --batches "1,2,3,4" \
    [--warmup-concurrency-multiplier 4] [--pc-hit-tolerance 1] \
    [--pc-hit-timeout 1800] [--pc-hit-interval 30] [--dry-run]

Purpose:
  Run controlled Prefix Cache warmup through the client script, parse server log
  hit-rate observations, and stop once observed >= target - tolerance.
USAGE
}

quote_sh() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/runtime_config.sh"

normalize_list() {
  printf '%s' "$1" | tr ',' ' '
}

to_host_path() {
  local path="$1"
  local output_container_root="$OUTPUT_CONTAINER_ROOT"
  local output_host_root="$OUTPUT_HOST_ROOT"
  if [[ "$path" == "$output_container_root"* ]]; then
    printf '%s%s\n' "$output_host_root" "${path#$output_container_root}"
  else
    printf '%s\n' "$path"
  fi
}

to_container_path() {
  local path="$1"
  local output_container_root="$OUTPUT_CONTAINER_ROOT"
  local output_host_root="$OUTPUT_HOST_ROOT"
  if [[ "$path" == "$output_host_root"* ]]; then
    printf '%s%s\n' "$output_container_root" "${path#$output_host_root}"
  else
    printf '%s\n' "$path"
  fi
}

run_in_container() {
  local script="$1"
  local docker_cmd
  docker_cmd="docker exec -i -w $(quote_sh "$SKILL_CONTAINER_ROOT") $(quote_sh "$CONTAINER") bash -ic 'tmp=/tmp/vllm_ops_pchit_warmup_\$\$.sh; cat > \"\$tmp\"; bash \"\$tmp\"; rc=\$?; rm -f \"\$tmp\"; exit \$rc'"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN_STEP: pchit warmup will run in container"
    printf 'ssh %q %q\n' "$NODE" "$docker_cmd"
    echo "--- container script ---"
    printf '%s\n' "$script"
    return 0
  fi
  printf '%s\n' "$script" | ssh "$NODE" "$docker_cmd"
}

NODE=""
CONTAINER=""
SERVED_MODEL_ID=""
PORT=""
TP=""
WORK_DIR=""
STATE=""
LOG_FILE=""
INPUT_LEN=""
OUTPUT_LEN=""
PC_HIT_TARGET=""
WARMUP_CACHE_HIT_RATES="92,95"
BATCHES="1,2,3,4,5,6,7,8"
WARMUP_CONCURRENCY_MULTIPLIER=4
PC_HIT_TOLERANCE=1
PC_HIT_TIMEOUT=1800
PC_HIT_INTERVAL=30
DRY_RUN=0
SKILL_USER=""
USER_ABBR=""
HOME_ROOT=""
HOST_HOME_ROOT=""
SKILL_HOST_ROOT=""
OUTPUT_HOST_ROOT="${OUTPUT_HOST_ROOT:-}"
CONTAINER_PREFIX=""

while [[ $# -gt 0 ]]; do
  if runtime_config_parse_common_arg "$1" "${2-}"; then
    shift 2
    continue
  fi
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --served-model-id) SERVED_MODEL_ID="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --tp) TP="$2"; shift 2 ;;
    --work-dir) WORK_DIR="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --log) LOG_FILE="$2"; shift 2 ;;
    --input-len) INPUT_LEN="$2"; shift 2 ;;
    --output-len) OUTPUT_LEN="$2"; shift 2 ;;
    --pc-hit-target) PC_HIT_TARGET="$2"; shift 2 ;;
    --warmup-cache-hit-rates) WARMUP_CACHE_HIT_RATES="$2"; shift 2 ;;
    --batches) BATCHES="$2"; shift 2 ;;
    --warmup-concurrency-multiplier) WARMUP_CONCURRENCY_MULTIPLIER="$2"; shift 2 ;;
    --pc-hit-tolerance) PC_HIT_TOLERANCE="$2"; shift 2 ;;
    --pc-hit-timeout) PC_HIT_TIMEOUT="$2"; shift 2 ;;
    --pc-hit-interval) PC_HIT_INTERVAL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

for var in NODE CONTAINER SERVED_MODEL_ID PORT TP WORK_DIR STATE LOG_FILE INPUT_LEN OUTPUT_LEN PC_HIT_TARGET; do
  [[ -n "${!var}" ]] || { echo "missing required argument: ${var}" >&2; exit 2; }
done
resolve_runtime_config

WORK_DIR="$(to_container_path "$WORK_DIR")"
STATE="$(to_container_path "$STATE")"
LOG_FILE="$(to_container_path "$LOG_FILE")"
STATE_HOST="$(to_host_path "$STATE")"

WARMUP_RATES="$(normalize_list "$WARMUP_CACHE_HIT_RATES")"
WARMUP_BATCHES="$(normalize_list "$BATCHES")"

remote_script=$(cat <<EOF
set -euo pipefail
cd $(quote_sh "$SKILL_CONTAINER_ROOT")

WORK_DIR=$(quote_sh "$WORK_DIR")
STATE=$(quote_sh "$STATE")
LOG_FILE=$(quote_sh "$LOG_FILE")
SERVED_MODEL_ID=$(quote_sh "$SERVED_MODEL_ID")
PORT=$(quote_sh "$PORT")
TP=$(quote_sh "$TP")
INPUT_LEN=$(quote_sh "$INPUT_LEN")
OUTPUT_LEN=$(quote_sh "$OUTPUT_LEN")
PC_HIT_TARGET=$(quote_sh "$PC_HIT_TARGET")
PC_HIT_TOLERANCE=$(quote_sh "$PC_HIT_TOLERANCE")
PC_HIT_TIMEOUT=$(quote_sh "$PC_HIT_TIMEOUT")
PC_HIT_INTERVAL=$(quote_sh "$PC_HIT_INTERVAL")
WARMUP_CONCURRENCY_MULTIPLIER=$(quote_sh "$WARMUP_CONCURRENCY_MULTIPLIER")
WARMUP_RATES=$(quote_sh "$WARMUP_RATES")
WARMUP_BATCHES=$(quote_sh "$WARMUP_BATCHES")
SUMMARY_FILE="\$WORK_DIR/logs/pchit-warmup-summary.jsonl"

mkdir -p "\$WORK_DIR/logs"
: > "\$SUMMARY_FILE"

python3 $(quote_sh "$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py") --state "\$STATE" \
  --set "status=PCHIT_WARMUP_RUNNING" \
  --set "pchit.warmup.target_pct=\$PC_HIT_TARGET" \
  --set "pchit.warmup.tolerance_pct=\$PC_HIT_TOLERANCE" \
  --set "pchit.warmup.cache_hit_rates=\$WARMUP_RATES" \
  --set "pchit.warmup.batches=\$WARMUP_BATCHES" \
  --set "pchit.warmup.concurrency_multiplier=\$WARMUP_CONCURRENCY_MULTIPLIER" \
  --set "pchit.warmup.summary_file=\$SUMMARY_FILE"

start_epoch=\$(date +%s)
round=0
last_status=""
last_observed=""
last_line=""
last_rate=""

while true; do
  for warmup_rate in \$WARMUP_RATES; do
    now=\$(date +%s)
    elapsed=\$((now - start_epoch))
    if [[ "\$elapsed" -ge "\$PC_HIT_TIMEOUT" ]]; then
      python3 $(quote_sh "$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py") --state "\$STATE" \
        --set "status=PCHIT_WARMUP_TIMEOUT" \
        --set "failure.reason=PCHIT_WARMUP_TIMEOUT" \
        --set "pchit.warmup.status=TIMEOUT" \
        --set "pchit.warmup.last_warmup_rate=\$last_rate" \
        --set "pchit.warmup.last_observed_pct=\$last_observed" \
        --set "pchit.warmup.rounds=\$round" \
        --set "pchit.warmup.duration_seconds=\$elapsed" \
        --set "pchit.warmup.log_excerpt=\$last_line"
      echo "PCHIT_WARMUP_TIMEOUT: target=\$PC_HIT_TARGET tolerance=\$PC_HIT_TOLERANCE observed=\$last_observed" >&2
      exit 1
    fi

    round=\$((round + 1))
    last_rate="\$warmup_rate"
    echo ">>> pchit warmup round=\$round warmup_rate=\$warmup_rate target=\$PC_HIT_TARGET"

    CACHE_HIT_RATES="\$warmup_rate" \
      BATCHES="\$WARMUP_BATCHES" \
      INPUT_LEN="\$INPUT_LEN" \
      OUTPUT_LEN="\$OUTPUT_LEN" \
      CONCURRENCY_MULTIPLIER="\$WARMUP_CONCURRENCY_MULTIPLIER" \
      TEST_MODE="pchit_warmup" \
      PCHIT_WARMUP_ONLY=1 \
      SERVED_MODEL_ID="\$SERVED_MODEL_ID" \
      BENCH_MODEL_ID="\$SERVED_MODEL_ID" \
      WORK_DIR="\$WORK_DIR" \
      bash scripts/client-scripts/run_perf_test-pchit-control.sh "\$SERVED_MODEL_ID" "\$PORT" "\$TP" "\$warmup_rate"

    set +e
    parser_out=\$(python3 scripts/ops/pchit_log_parser.py --log "\$LOG_FILE" --target "\$PC_HIT_TARGET" --tolerance "\$PC_HIT_TOLERANCE" 2>&1)
    parser_rc=\$?
    set -e
    printf '%s\n' "\$parser_out"

    last_status=\$(printf '%s\n' "\$parser_out" | awk -F= '/^STATUS=/{print \$2}' | tail -1)
    last_observed=\$(printf '%s\n' "\$parser_out" | awk -F= '/^OBSERVED_PC_HIT_PCT=/{print \$2}' | tail -1)
    last_line=\$(printf '%s\n' "\$parser_out" | awk -F= '/^PC_HIT_LOG_LINE=/{print substr(\$0, index(\$0,\$2))}' | tail -1)
    [[ -n "\$last_observed" ]] || last_observed=""
    [[ -n "\$last_line" ]] || last_line="\$parser_out"

    printf '{"round":%s,"warmup_rate":"%s","target_pct":"%s","observed_pct":"%s","status":"%s","line":%s}\\n' \
      "\$round" "\$warmup_rate" "\$PC_HIT_TARGET" "\$last_observed" "\$last_status" \
      "\$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "\$last_line")" >> "\$SUMMARY_FILE"

    python3 $(quote_sh "$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py") --state "\$STATE" \
      --set "pchit.warmup.last_warmup_rate=\$warmup_rate" \
      --set "pchit.warmup.last_observed_pct=\$last_observed" \
      --set "pchit.warmup.rounds=\$round" \
      --set "pchit.warmup.log_excerpt=\$last_line"

    if [[ "\$parser_rc" == "0" ]]; then
      elapsed=\$((\$(date +%s) - start_epoch))
      python3 $(quote_sh "$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py") --state "\$STATE" \
        --set "status=PCHIT_WARMUP_DONE" \
        --set "pchit.warmup.status=PASS" \
        --set "pchit.warmup.target_pct=\$PC_HIT_TARGET" \
        --set "pchit.warmup.observed_pct=\$last_observed" \
        --set "pchit.warmup.tolerance_pct=\$PC_HIT_TOLERANCE" \
        --set "pchit.warmup.warmup_rate=\$warmup_rate" \
        --set "pchit.warmup.rounds=\$round" \
        --set "pchit.warmup.duration_seconds=\$elapsed" \
        --set "pchit.warmup.log_excerpt=\$last_line"
      echo "PCHIT_WARMUP_STATUS=PASS"
      echo "WARMUP_RATE=\$warmup_rate"
      echo "OBSERVED_PC_HIT_PCT=\$last_observed"
      echo "PCHIT_WARMUP_ROUNDS=\$round"
      echo "PCHIT_WARMUP_DURATION_SECONDS=\$elapsed"
      exit 0
    fi

    if [[ "\$parser_rc" == "1" ]]; then
      python3 $(quote_sh "$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py") --state "\$STATE" \
        --set "status=PCHIT_HIT_RATE_NOT_FOUND" \
        --set "failure.reason=PCHIT_HIT_RATE_NOT_FOUND" \
        --set "pchit.warmup.status=HIT_RATE_NOT_FOUND" \
        --set "pchit.warmup.rounds=\$round" \
        --set "pchit.warmup.log_excerpt=\$last_line"
      echo "PCHIT_HIT_RATE_NOT_FOUND: no parseable PC hit rate in \$LOG_FILE" >&2
      exit 1
    fi

  done
  sleep "\$PC_HIT_INTERVAL"
done
EOF
)

run_in_container "$remote_script"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "PCHIT_WARMUP_STATUS=<DRY_RUN>"
fi
