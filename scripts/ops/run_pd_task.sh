#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/version.sh"
SCRIPT_VERSION="$OPS_VERSION"
echo "PD_SCRIPT_VERSION=$SCRIPT_VERSION"

if python3 "$SCRIPT_DIR/pd_invocation_contract.py" "$@"; then
  :
else
  invocation_rc=$?
  exit "$invocation_rc"
fi

usage() {
  cat <<'USAGE'
Usage:
  run_pd_task.sh (--config CONFIG | --profile PROFILE [--deployment FILE] [--test-preset PRESET]) \
    --user USER --abbr ABBR \
    [--assume-yes] [--dry-run] --image IMAGE [--image-id IMAGE_ID] \
    [--mooncake-wheel URL_OR_CONTAINER_PATH] \
    [--max-model-len N] [--gpu-memory-utilization VALUE] \
    [--image-prefix PREFIX] \
    [--host-model-path PATH] [--container-model-path PATH] \
    [--prefill-node IP] [--prefill-service-ip IP] [--prefill-vllm-host-ip IP] \
    [--decode-node IP] [--decode-service-ip IP] [--decode-vllm-host-ip IP] \
    [--prefill-port PORT] [--decode-port PORT] [--prefill-transfer-port PORT] \
    [--proxy-port PORT] [--network-ifname IFNAME] [--nccl-ib-hca HCA] \
    [--mooncake-dest-device-affinity 0|1] \
    [--ready-timeout SECONDS] [--proxy-timeout SECONDS] \
    [--proxy-request-timeout SECONDS] [--bench-timeout SECONDS] [--interval SECONDS] \
    [--input-lens LIST] [--output-len N] [--concurrencies LIST] \
    [--num-prompts-mult N] [--request-rate RATE] [--percentiles LIST] \
    [--pchit-input-len N] [--pchit-output-len N] [--pchit-batches LIST] \
    [--pc-hit-target PCT] [--pchit-mode fixed|sla-search] \
    [--ttft-sla-ms N] [--tpot-sla-ms N] [--sla-stat mean|p95|p99] \
    [--keep-containers-on-failure] [--verbose-dry-run]

  run_pd_task.sh --cleanup-state STATE --user USER --abbr ABBR [--dry-run]
USAGE
}

quote_sh() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
extract_value() { grep -E "^$1=" "$2" | tail -1 | cut -d= -f2-; }
to_host_path() {
  local path="$1"
  if [[ "$path" == "$OUTPUT_CONTAINER_ROOT"* ]]; then
    printf '%s%s\n' "$OUTPUT_HOST_ROOT" "${path#$OUTPUT_CONTAINER_ROOT}"
  else
    printf '%s\n' "$path"
  fi
}
run_step_capture() {
  local name="$1" outfile="$2"; shift 2
  CURRENT_STAGE="$name"
  echo "== ${name} =="
  if [[ "$DRY_RUN" == "1" && "$VERBOSE_DRY_RUN" == "0" ]]; then
    if "$@" >"$outfile" 2>&1; then
      echo "DRY_RUN_STAGE=$name"
      grep -E '^(DRY_RUN|PD_.*DRY_RUN|WARN_|[A-Z_]+_CHECK=)' "$outfile" | tail -20 || true
      return 0
    else
      local rc=$?
      tail -80 "$outfile" >&2 || true
      return "$rc"
    fi
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY_RUN_STEP:'; printf ' %q' "$@"; printf '\n'
  fi
  "$@" 2>&1 | tee "$outfile"
  return "${PIPESTATUS[0]}"
}
default_image_prefix() {
  local token
  if [[ -n "$EXPECTED_IMAGE_ID" ]]; then
    printf '%s\n' "${EXPECTED_IMAGE_ID:0:4}"
    return 0
  fi
  token="${IMAGE##*:}"
  token="${token##*/}"
  token="$(printf '%s' "$token" | tr -cd 'A-Za-z0-9' | tr 'A-Z' 'a-z')"
  [[ ${#token} -ge 4 ]] || token="image"
  printf '%s\n' "${token:0:4}"
}
update_state_host() {
  [[ "$DRY_RUN" == "0" ]] || return 0
  python3 "$SCRIPT_DIR/update_state.py" --state "$STATE_HOST" "$@"
}
render_report() {
  [[ "$DRY_RUN" == "0" ]] || return 0
  OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" \
    python3 "$SCRIPT_DIR/render_report.py" --run-id "$RUN_ID" --state "$STATE_HOST" --csv "$CSV_HOST" --report-dir "$REPORT_DIR"
}
emit_task_summary() {
  [[ "$DRY_RUN" == "0" && -f "${STATE_HOST:-}" ]] || return 0
  echo "== task_summary =="
  python3 "$SCRIPT_DIR/show_state.py" --state "$STATE_HOST" || true
}
should_keep_containers() {
  [[ "$KEEP_CONTAINERS_ON_FAILURE" == "1" ]] || return 1
  case "$1" in
    start_proxy|wait_proxy|run_bench) return 0 ;;
    *) return 1 ;;
  esac
}
fail_task() {
  local stage="$1" rc="$2" outfile="$3" keep=0
  echo "PD_TASK_FAILED_RC=$rc" >&2
  if should_keep_containers "$stage"; then
    keep=1
    if [[ "${PREFILL_CONTAINER_MAY_EXIST:-0}" == "1" ]]; then
      bash "$SCRIPT_DIR/stop_service.sh" --role prefill --node "$PREFILL_NODE" --container "$PREFILL_CONTAINER" --port "$PREFILL_PORT" --state "$STATE_HOST" --preserve-failure --restore-permissions-only "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}" || true
    fi
  else
    if [[ "${DECODE_CONTAINER_MAY_EXIST:-0}" == "1" ]]; then
      echo "== cleanup_stop_decode =="
      bash "$SCRIPT_DIR/stop_service.sh" --role decode --node "$DECODE_NODE" --container "$DECODE_CONTAINER" --port "$DECODE_PORT" --state "$STATE_HOST" --preserve-failure "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}" || true
    fi
    if [[ "${PREFILL_CONTAINER_MAY_EXIST:-0}" == "1" ]]; then
      echo "== cleanup_stop_prefill =="
      bash "$SCRIPT_DIR/stop_service.sh" --role prefill --node "$PREFILL_NODE" --container "$PREFILL_CONTAINER" --port "$PREFILL_PORT" --state "$STATE_HOST" --preserve-failure "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}" || true
    fi
  fi
  if [[ "$DRY_RUN" == "0" ]]; then
    python3 "$SCRIPT_DIR/record_failure.py" --state "$STATE_HOST" --stage "$stage" --exit-code "$rc" --output-file "$outfile" >/dev/null 2>&1 || true
  fi
  if [[ "$keep" == "1" ]]; then
    update_state_host --set "cleanup.policy=keep" --set "cleanup.containers_preserved=true" \
      --set "pd.roles.prefill.stop_status=PRESERVED" --set "pd.roles.decode.stop_status=PRESERVED" || true
    echo "CLEANUP_POLICY=keep" >&2
    echo "CONTAINERS_PRESERVED=1" >&2
  else
    update_state_host --set "cleanup.policy=auto_stop" --set "cleanup.containers_preserved=false" || true
  fi
  if [[ "$DRY_RUN" == "0" && -f "$STATE_HOST" ]]; then
    render_report || true
    emit_task_summary
  fi
  echo "PD_TASK_FAILED=1" >&2
  echo "STATE_HOST=$STATE_HOST" >&2
  echo "REPORT_JSON_HOST=${REPORT_DIR}/${RUN_ID}.json" >&2
  echo "REPORT_MD_HOST=${REPORT_DIR}/${RUN_ID}.md" >&2
  exit "$rc"
}
run_stage() {
  local name="$1" outfile="$2" rc; shift 2
  if run_step_capture "$name" "$outfile" "$@"; then
    return 0
  else
    rc=$?
    fail_task "$name" "$rc" "$outfile"
  fi
}

CONFIG=""; PROFILE=""; DEPLOYMENT=""; TEST_PRESET=""; CLEANUP_STATE=""; ASSUME_YES=0; DRY_RUN=0; VERBOSE_DRY_RUN=0; KEEP_CONTAINERS_ON_FAILURE=0
IMAGE_ARG=""; EXPECTED_IMAGE_ID=""; IMAGE_PREFIX=""; MOONCAKE_WHEEL_ARG=""; DATE_PART="$(date +%m%d)"; RUN_ID=""
HOST_MODEL_PATH_ARG=""; CONTAINER_MODEL_PATH_ARG=""
MAX_MODEL_LEN_ARG=""; GPU_MEMORY_UTILIZATION_ARG=""
PREFILL_NODE_ARG=""; PREFILL_SERVICE_IP_ARG=""; PREFILL_VLLM_HOST_IP_ARG=""; PREFILL_PORT_ARG=""; PREFILL_TRANSFER_PORT_ARG=""
DECODE_NODE_ARG=""; DECODE_SERVICE_IP_ARG=""; DECODE_VLLM_HOST_IP_ARG=""; DECODE_PORT_ARG=""
PROXY_PORT_ARG=""; NETWORK_IFNAME_ARG=""; NCCL_IB_HCA_ARG=""; MOONCAKE_DEST_DEVICE_AFFINITY_ARG=""
INPUT_LENS_ARG=""; OUTPUT_LEN_ARG=""; CONCURRENCIES_ARG=""; NUM_PROMPTS_MULT_ARG=""; REQUEST_RATE_ARG=""; PERCENTILES_ARG=""
PCHIT_INPUT_LEN_ARG=""; PCHIT_OUTPUT_LEN_ARG=""; PCHIT_BATCHES_ARG=""; PC_HIT_TARGET_ARG=""; PCHIT_MODE_ARG=""
TTFT_SLA_MS_ARG=""; TPOT_SLA_MS_ARG=""; SLA_STAT_ARG=""
READY_TIMEOUT=1800; PROXY_TIMEOUT=600; PROXY_REQUEST_TIMEOUT=180; BENCH_TIMEOUT=3600; INTERVAL=30; CURRENT_STAGE="init"

source "$SCRIPT_DIR/runtime_config.sh"
SKILL_USER=""; USER_ABBR=""; HOME_ROOT=""; HOST_HOME_ROOT=""; SKILL_HOST_ROOT=""
OUTPUT_HOST_ROOT="${OUTPUT_HOST_ROOT:-}"; OUTPUT_CONTAINER_ROOT="${OUTPUT_CONTAINER_ROOT:-}"; CONTAINER_PREFIX=""

while [[ $# -gt 0 ]]; do
  if runtime_config_parse_common_arg "$1" "${2-}"; then shift 2; continue; fi
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --deployment) DEPLOYMENT="$2"; shift 2 ;;
    --test-preset) TEST_PRESET="$2"; shift 2 ;;
    --cleanup-state) CLEANUP_STATE="$2"; shift 2 ;;
    --date) DATE_PART="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --image) IMAGE_ARG="$2"; shift 2 ;;
    --image-id|--image-digest) EXPECTED_IMAGE_ID="${2#sha256:}"; shift 2 ;;
    --mooncake-wheel) MOONCAKE_WHEEL_ARG="$2"; shift 2 ;;
    --image-prefix) IMAGE_PREFIX="$2"; shift 2 ;;
    --host-model-path) HOST_MODEL_PATH_ARG="$2"; shift 2 ;;
    --container-model-path) CONTAINER_MODEL_PATH_ARG="$2"; shift 2 ;;
    --max-model-len) MAX_MODEL_LEN_ARG="$2"; shift 2 ;;
    --gpu-memory-utilization) GPU_MEMORY_UTILIZATION_ARG="$2"; shift 2 ;;
    --prefill-node) PREFILL_NODE_ARG="$2"; shift 2 ;;
    --prefill-service-ip) PREFILL_SERVICE_IP_ARG="$2"; shift 2 ;;
    --prefill-vllm-host-ip) PREFILL_VLLM_HOST_IP_ARG="$2"; shift 2 ;;
    --prefill-port) PREFILL_PORT_ARG="$2"; shift 2 ;;
    --prefill-transfer-port) PREFILL_TRANSFER_PORT_ARG="$2"; shift 2 ;;
    --decode-node) DECODE_NODE_ARG="$2"; shift 2 ;;
    --decode-service-ip) DECODE_SERVICE_IP_ARG="$2"; shift 2 ;;
    --decode-vllm-host-ip) DECODE_VLLM_HOST_IP_ARG="$2"; shift 2 ;;
    --decode-port) DECODE_PORT_ARG="$2"; shift 2 ;;
    --proxy-port) PROXY_PORT_ARG="$2"; shift 2 ;;
    --network-ifname) NETWORK_IFNAME_ARG="$2"; shift 2 ;;
    --nccl-ib-hca) NCCL_IB_HCA_ARG="$2"; shift 2 ;;
    --mooncake-dest-device-affinity) MOONCAKE_DEST_DEVICE_AFFINITY_ARG="$2"; shift 2 ;;
    --ready-timeout) READY_TIMEOUT="$2"; shift 2 ;;
    --proxy-timeout) PROXY_TIMEOUT="$2"; shift 2 ;;
    --proxy-request-timeout) PROXY_REQUEST_TIMEOUT="$2"; shift 2 ;;
    --bench-timeout) BENCH_TIMEOUT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --input-lens) INPUT_LENS_ARG="$2"; shift 2 ;;
    --output-len) OUTPUT_LEN_ARG="$2"; shift 2 ;;
    --concurrencies) CONCURRENCIES_ARG="$2"; shift 2 ;;
    --num-prompts-mult) NUM_PROMPTS_MULT_ARG="$2"; shift 2 ;;
    --request-rate) REQUEST_RATE_ARG="$2"; shift 2 ;;
    --percentiles) PERCENTILES_ARG="$2"; shift 2 ;;
    --pchit-input-len) PCHIT_INPUT_LEN_ARG="$2"; shift 2 ;;
    --pchit-output-len) PCHIT_OUTPUT_LEN_ARG="$2"; shift 2 ;;
    --pchit-batches) PCHIT_BATCHES_ARG="$2"; shift 2 ;;
    --pc-hit-target) PC_HIT_TARGET_ARG="$2"; shift 2 ;;
    --pchit-mode) PCHIT_MODE_ARG="$2"; shift 2 ;;
    --ttft-sla-ms) TTFT_SLA_MS_ARG="$2"; shift 2 ;;
    --tpot-sla-ms) TPOT_SLA_MS_ARG="$2"; shift 2 ;;
    --sla-stat) SLA_STAT_ARG="$2"; shift 2 ;;
    --keep-containers-on-failure) KEEP_CONTAINERS_ON_FAILURE=1; shift ;;
    --assume-yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose-dry-run) DRY_RUN=1; VERBOSE_DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *)
      python3 "$SCRIPT_DIR/pd_invocation_contract.py" "$1" || true
      exit 2
      ;;
  esac
done

if [[ -n "$CLEANUP_STATE" ]]; then
  [[ -z "$CONFIG$PROFILE$DEPLOYMENT$TEST_PRESET$IMAGE_ARG" ]] || { echo "cleanup_state_conflicts_with_run_args=1" >&2; exit 2; }
  resolve_runtime_config
  [[ "$CLEANUP_STATE" == /* ]] || { echo "cleanup_state_must_be_absolute=$CLEANUP_STATE" >&2; exit 2; }
  case "$CLEANUP_STATE" in "$OUTPUT_HOST_ROOT"/*) ;; *) echo "cleanup_state_outside_output_root=$CLEANUP_STATE" >&2; exit 2 ;; esac
  [[ -f "$CLEANUP_STATE" ]] || { echo "cleanup_state_missing=$CLEANUP_STATE" >&2; exit 2; }
  eval "$(python3 "$SCRIPT_DIR/cleanup_state_config.py" --state "$CLEANUP_STATE")"
  DRY_ARGS=(); if [[ "$DRY_RUN" == "1" ]]; then DRY_ARGS=(--dry-run); fi
  COMMON_ARGS=(--user "$SKILL_USER" --abbr "$USER_ABBR" --home-root "$HOME_ROOT" --host-home-root "$HOST_HOME_ROOT" --skill-host-root "$SKILL_HOST_ROOT" --output-host-root "$OUTPUT_HOST_ROOT" --output-container-root "$OUTPUT_CONTAINER_ROOT" --container-prefix "$CONTAINER_PREFIX")
  bash "$SCRIPT_DIR/stop_service.sh" --role prefill --node "$CLEANUP_PREFILL_NODE" --container "$CLEANUP_PREFILL_CONTAINER" --port "$CLEANUP_PREFILL_PORT" --state "$CLEANUP_STATE" --preserve-failure --restore-permissions-only "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}" || true
  if [[ "$DRY_RUN" == "0" ]]; then
    python3 "$SCRIPT_DIR/update_state.py" --state "$CLEANUP_STATE" --set "cleanup.status=STOPPING" --set "cleanup.policy=manual" >/dev/null
  fi
  cleanup_rc=0
  bash "$SCRIPT_DIR/stop_service.sh" --role decode --node "$CLEANUP_DECODE_NODE" --container "$CLEANUP_DECODE_CONTAINER" --port "$CLEANUP_DECODE_PORT" --state "$CLEANUP_STATE" --preserve-failure "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}" || cleanup_rc=1
  bash "$SCRIPT_DIR/stop_service.sh" --role prefill --node "$CLEANUP_PREFILL_NODE" --container "$CLEANUP_PREFILL_CONTAINER" --port "$CLEANUP_PREFILL_PORT" --state "$CLEANUP_STATE" --preserve-failure "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}" || cleanup_rc=1
  if [[ "$DRY_RUN" == "0" ]]; then
    if [[ "$cleanup_rc" == "0" ]]; then
      python3 "$SCRIPT_DIR/update_state.py" --state "$CLEANUP_STATE" --set "cleanup.status=COMPLETED" --set "cleanup.containers_preserved=false" >/dev/null
    else
      python3 "$SCRIPT_DIR/update_state.py" --state "$CLEANUP_STATE" --set "cleanup.status=FAILED" >/dev/null || true
    fi
  fi
  echo "CLEANUP_STATE=$CLEANUP_STATE"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "PD_CLEANUP_DRY_RUN_DONE=1"
  else
    echo "PD_CLEANUP_DONE=$((cleanup_rc == 0 ? 1 : 0))"
  fi
  exit "$cleanup_rc"
fi

[[ -n "$CONFIG" || -n "$PROFILE" ]] || { echo "missing_arg=--config_or_--profile" >&2; exit 2; }
[[ -z "$CONFIG" || -z "$PROFILE$DEPLOYMENT$TEST_PRESET" ]] || { echo "config_conflicts_with_composed_config=1" >&2; exit 2; }
resolve_runtime_config
CONFIG_PATH="${CONFIG:-composed:${PROFILE}:${DEPLOYMENT}:${TEST_PRESET}}"
CONFIG_ARGS=()
if [[ -n "$CONFIG" ]]; then
  CONFIG_REAL="$CONFIG"; [[ "$CONFIG_REAL" == /* ]] || CONFIG_REAL="$SKILL_ROOT/$CONFIG_REAL"
  CONFIG_ARGS=(--config "$CONFIG_REAL")
else
  CONFIG_ARGS=(--profile "$PROFILE")
  [[ -z "$DEPLOYMENT" ]] || CONFIG_ARGS+=(--deployment "$DEPLOYMENT")
  [[ -z "$TEST_PRESET" ]] || CONFIG_ARGS+=(--test-preset "$TEST_PRESET")
fi
eval "$(python3 "$SCRIPT_DIR/pd_config.py" "${CONFIG_ARGS[@]}" --shell)"

MODE="${MODE:-pd}"; PD_BACKEND="${PD_BACKEND:-mooncake_vllm018}"; PD_TOPOLOGY="${PD_TOPOLOGY:-1p1d}"
TEST_MODE="${TEST_MODE:-custom}"; IMAGE="$IMAGE_ARG"; MODEL_NAME="${MODEL_NAME:-}"
MOONCAKE_WHEEL="${MOONCAKE_WHEEL_ARG:-${PD_RUNTIME_MOONCAKE_WHEEL:-}}"
MODEL_SHORT="${MODEL_MODEL_SHORT:-${MODEL_SHORT:-}}"
HOST_MODEL_PATH="${HOST_MODEL_PATH_ARG:-${MODEL_HOST_MODEL_PATH:-}}"
CONTAINER_MODEL_PATH="${CONTAINER_MODEL_PATH_ARG:-${MODEL_CONTAINER_MODEL_PATH:-}}"
PREFILL_NODE="${PREFILL_NODE_ARG:-${PD_ROLES_PREFILL_NODE:-}}"
PREFILL_SERVICE_IP="${PREFILL_SERVICE_IP_ARG:-${PD_ROLES_PREFILL_SERVICE_IP:-$PREFILL_NODE}}"
PREFILL_VLLM_HOST_IP="${PREFILL_VLLM_HOST_IP_ARG:-${PD_ROLES_PREFILL_VLLM_HOST_IP:-$PREFILL_SERVICE_IP}}"
PREFILL_PORT="${PREFILL_PORT_ARG:-${PD_ROLES_PREFILL_PORT:-9348}}"
PREFILL_TRANSFER_PORT="${PREFILL_TRANSFER_PORT_ARG:-${PD_ROLES_PREFILL_TRANSFER_PORT:-8998}}"
DECODE_NODE="${DECODE_NODE_ARG:-${PD_ROLES_DECODE_NODE:-}}"
DECODE_SERVICE_IP="${DECODE_SERVICE_IP_ARG:-${PD_ROLES_DECODE_SERVICE_IP:-$DECODE_NODE}}"
DECODE_VLLM_HOST_IP="${DECODE_VLLM_HOST_IP_ARG:-${PD_ROLES_DECODE_VLLM_HOST_IP:-$DECODE_SERVICE_IP}}"
DECODE_PORT="${DECODE_PORT_ARG:-${PD_ROLES_DECODE_PORT:-9349}}"
PROXY_ROLE="${PD_PROXY_NODE_ROLE:-prefill}"; PROXY_PORT="${PROXY_PORT_ARG:-${PD_PROXY_PORT:-8000}}"
NETWORK_IFNAME="${NETWORK_IFNAME_ARG:-${PD_NETWORK_IFNAME:-}}"; NCCL_IB_HCA="${NCCL_IB_HCA_ARG:-${PD_NETWORK_NCCL_IB_HCA:-}}"
MOONCAKE_DEST_DEVICE_AFFINITY="${MOONCAKE_DEST_DEVICE_AFFINITY_ARG:-${PD_RUNTIME_MOONCAKE_DEST_DEVICE_AFFINITY:-1}}"
PREFILL_SERVER_SCRIPT="${PD_SERVER_SCRIPTS_PREFILL:-}"
DECODE_SERVER_SCRIPT="${PD_SERVER_SCRIPTS_DECODE:-}"
PROXY_LAUNCHER_SCRIPT="${PD_SERVER_SCRIPTS_PROXY:-}"
MOONCAKE_PROXY_SCRIPT="${PD_MOONCAKE_PROXY_SCRIPT:-mooncake/examples/online_serving/disaggregated_serving/mooncake_connector/mooncake_connector_proxy.py}"
TP="${PD_SERVICE_DEFAULTS_TP:-1}"; GPU_RANGE="${PD_SERVICE_DEFAULTS_GPU_RANGE:-0}"
QUANTIZATION="${PD_SERVICE_DEFAULTS_QUANTIZATION:-}"; DTYPE="${PD_SERVICE_DEFAULTS_DTYPE:-auto}"
MAX_NUM_BATCHED_TOKENS="${PD_SERVICE_DEFAULTS_MAX_NUM_BATCHED_TOKENS:-}"
MAX_NUM_SEQS="${PD_SERVICE_DEFAULTS_MAX_NUM_SEQS:-}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION_ARG:-${PD_SERVICE_DEFAULTS_GPU_MEMORY_UTILIZATION:-}}"
MAX_MODEL_LEN="${MAX_MODEL_LEN_ARG:-${PD_SERVICE_DEFAULTS_MAX_MODEL_LEN:-}}"
SPECULATIVE_CONFIG="${PD_SERVICE_DEFAULTS_SPECULATIVE_CONFIG:-}"
COMPILATION_CONFIG="${PD_SERVICE_DEFAULTS_COMPILATION_CONFIG:-}"
EXTRA_ARGS="${PD_SERVICE_DEFAULTS_EXTRA_ARGS:-}"
PREFILL_EXTRA_ARGS="$(printf '%s %s' "$EXTRA_ARGS" "${PD_SERVICE_DEFAULTS_PREFILL_EXTRA_ARGS:-}" | xargs)"
DECODE_EXTRA_ARGS="$(printf '%s %s' "$EXTRA_ARGS" "${PD_SERVICE_DEFAULTS_DECODE_EXTRA_ARGS:-}" | xargs)"
CUSTOM_INPUT_LENS="${INPUT_LENS_ARG:-${TEST_PARAMS_INPUT_LENS:-512}}"
CUSTOM_OUTPUT_LEN="${OUTPUT_LEN_ARG:-${TEST_PARAMS_OUTPUT_LEN:-32}}"
CUSTOM_CONCURRENCIES="${CONCURRENCIES_ARG:-${TEST_PARAMS_CONCURRENCIES:-1}}"
CUSTOM_NUM_PROMPTS_MULT="${NUM_PROMPTS_MULT_ARG:-${TEST_PARAMS_NUM_PROMPTS_MULT:-1}}"
CUSTOM_REQUEST_RATE="${REQUEST_RATE_ARG:-${TEST_PARAMS_REQUEST_RATE:-}}"
CUSTOM_PERCENTILES="${PERCENTILES_ARG:-${TEST_PARAMS_PERCENTILES:-50,95,99}}"
PCHIT_INPUT_LEN="${PCHIT_INPUT_LEN_ARG:-${TEST_PARAMS_INPUT_LEN:-32768}}"
PCHIT_OUTPUT_LEN="${PCHIT_OUTPUT_LEN_ARG:-${TEST_PARAMS_OUTPUT_LEN:-1024}}"
PCHIT_BATCHES="${PCHIT_BATCHES_ARG:-${TEST_PARAMS_BATCHES:-1 2 3 4 5 6 7 8}}"
PCHIT_TARGET_PCT="${PC_HIT_TARGET_ARG:-${TEST_PARAMS_PC_HIT_TARGET:-90}}"
PCHIT_BENCHMARK_MODE="${PCHIT_MODE_ARG:-${TEST_PARAMS_PCHIT_BENCHMARK_MODE:-fixed}}"
PCHIT_TTFT_SLA_MS="${TTFT_SLA_MS_ARG:-${TEST_PARAMS_TTFT_SLA_MS:-5000}}"
PCHIT_TPOT_SLA_MS="${TPOT_SLA_MS_ARG:-${TEST_PARAMS_TPOT_SLA_MS:-50}}"
PCHIT_SLA_STAT="${SLA_STAT_ARG:-${TEST_PARAMS_SLA_STAT:-mean}}"

normalize_positive_int_list() {
  local name="$1" raw="$2" item normalized=""
  raw="${raw//,/ }"
  for item in $raw; do
    [[ "$item" =~ ^[1-9][0-9]*$ ]] || { echo "invalid_${name}=$item" >&2; return 2; }
    normalized="${normalized:+$normalized }$item"
  done
  [[ -n "$normalized" ]] || { echo "missing_${name}=1" >&2; return 2; }
  printf '%s\n' "$normalized"
}

[[ -n "$IMAGE" ]] || { echo "missing_arg=--image" >&2; exit 2; }
for var in MODEL_NAME MODEL_SHORT HOST_MODEL_PATH CONTAINER_MODEL_PATH PREFILL_NODE DECODE_NODE PREFILL_VLLM_HOST_IP DECODE_VLLM_HOST_IP PREFILL_SERVER_SCRIPT DECODE_SERVER_SCRIPT PROXY_LAUNCHER_SCRIPT; do
  [[ -n "${!var}" ]] || { echo "missing_config=$var" >&2; exit 2; }
done
[[ "$MODE" == "pd" ]] || { echo "unsupported_mode=$MODE" >&2; exit 2; }
[[ "$PD_BACKEND" == "mooncake_vllm018" ]] || { echo "unsupported_backend=$PD_BACKEND" >&2; exit 2; }
[[ "$PD_TOPOLOGY" == "1p1d" ]] || { echo "unsupported_topology=$PD_TOPOLOGY" >&2; exit 2; }
[[ "$TEST_MODE" == "custom" || "$TEST_MODE" == "pchit" ]] || { echo "unsupported_test_mode=$TEST_MODE" >&2; exit 2; }
if [[ "$TEST_MODE" == "pchit" && -n "$INPUT_LENS_ARG$OUTPUT_LEN_ARG$CONCURRENCIES_ARG$NUM_PROMPTS_MULT_ARG$REQUEST_RATE_ARG$PERCENTILES_ARG" ]]; then
  echo "custom_cli_args_not_allowed_for_pchit=1" >&2
  exit 2
fi
if [[ "$TEST_MODE" == "custom" ]]; then
  CUSTOM_INPUT_LENS="$(normalize_positive_int_list input_lens "$CUSTOM_INPUT_LENS")"
  CUSTOM_CONCURRENCIES="$(normalize_positive_int_list concurrencies "$CUSTOM_CONCURRENCIES")"
  [[ "$CUSTOM_OUTPUT_LEN" =~ ^[1-9][0-9]*$ ]] || { echo "invalid_output_len=$CUSTOM_OUTPUT_LEN" >&2; exit 2; }
  [[ "$CUSTOM_NUM_PROMPTS_MULT" =~ ^[1-9][0-9]*$ ]] || { echo "invalid_num_prompts_mult=$CUSTOM_NUM_PROMPTS_MULT" >&2; exit 2; }
  [[ "$CUSTOM_PERCENTILES" =~ ^[0-9]+([.][0-9]+)?(,[0-9]+([.][0-9]+)?)*$ ]] || { echo "invalid_percentiles=$CUSTOM_PERCENTILES" >&2; exit 2; }
  if [[ -n "$CUSTOM_REQUEST_RATE" && ! "$CUSTOM_REQUEST_RATE" =~ ^([1-9][0-9]*([.][0-9]+)?|0[.][0-9]*[1-9][0-9]*)$ ]]; then
    echo "invalid_request_rate=$CUSTOM_REQUEST_RATE" >&2; exit 2
  fi
fi
if [[ "$TEST_MODE" == "pchit" ]]; then
  [[ "$PCHIT_INPUT_LEN" =~ ^[1-9][0-9]*$ ]] || { echo "invalid_pchit_input_len=$PCHIT_INPUT_LEN" >&2; exit 2; }
  [[ "$PCHIT_OUTPUT_LEN" =~ ^[1-9][0-9]*$ ]] || { echo "invalid_pchit_output_len=$PCHIT_OUTPUT_LEN" >&2; exit 2; }
  PCHIT_BATCHES="$(normalize_positive_int_list pchit_batches "$PCHIT_BATCHES")"
  python3 -c 'import sys; value=float(sys.argv[1]); sys.exit(0 if 0 < value <= 100 else 1)' "$PCHIT_TARGET_PCT" || { echo "invalid_pc_hit_target=$PCHIT_TARGET_PCT" >&2; exit 2; }
  [[ "$PCHIT_BENCHMARK_MODE" == "fixed" || "$PCHIT_BENCHMARK_MODE" == "sla-search" ]] || { echo "invalid_pchit_mode=$PCHIT_BENCHMARK_MODE" >&2; exit 2; }
  [[ "$PCHIT_TTFT_SLA_MS" =~ ^[1-9][0-9]*$ ]] || { echo "invalid_ttft_sla_ms=$PCHIT_TTFT_SLA_MS" >&2; exit 2; }
  [[ "$PCHIT_TPOT_SLA_MS" =~ ^[1-9][0-9]*$ ]] || { echo "invalid_tpot_sla_ms=$PCHIT_TPOT_SLA_MS" >&2; exit 2; }
  [[ "$PCHIT_SLA_STAT" == "mean" || "$PCHIT_SLA_STAT" == "p95" || "$PCHIT_SLA_STAT" == "p99" ]] || { echo "invalid_sla_stat=$PCHIT_SLA_STAT" >&2; exit 2; }
fi
if [[ "$TEST_MODE" == "custom" ]]; then
  LIMIT_INPUT_LENS="$CUSTOM_INPUT_LENS"; LIMIT_OUTPUT_LEN="$CUSTOM_OUTPUT_LEN"
else
  LIMIT_INPUT_LENS="$PCHIT_INPUT_LEN"; LIMIT_OUTPUT_LEN="$PCHIT_OUTPUT_LEN"
fi
python3 "$SCRIPT_DIR/validate_runtime_limits.py" \
  --max-model-len "$MAX_MODEL_LEN" \
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
  --test-mode "$TEST_MODE" --input-lens "$LIMIT_INPUT_LENS" --output-len "$LIMIT_OUTPUT_LEN"
for numeric_arg in READY_TIMEOUT PROXY_TIMEOUT PROXY_REQUEST_TIMEOUT BENCH_TIMEOUT INTERVAL; do
  [[ "${!numeric_arg}" =~ ^[1-9][0-9]*$ ]] || { echo "invalid_${numeric_arg,,}=${!numeric_arg}" >&2; exit 2; }
done
[[ "$MOONCAKE_DEST_DEVICE_AFFINITY" == "0" || "$MOONCAKE_DEST_DEVICE_AFFINITY" == "1" ]] || {
  echo "invalid_mooncake_dest_device_affinity=$MOONCAKE_DEST_DEVICE_AFFINITY" >&2
  exit 2
}
if [[ -n "$IMAGE_PREFIX" && ! "$IMAGE_PREFIX" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
  echo "invalid_image_prefix=$IMAGE_PREFIX" >&2
  echo "image_prefix_hint=use_--image_for_repository_tag" >&2
  exit 2
fi
if [[ -n "$EXPECTED_IMAGE_ID" && ! "$EXPECTED_IMAGE_ID" =~ ^[A-Fa-f0-9]{4,64}$ ]]; then
  echo "invalid_image_id=$EXPECTED_IMAGE_ID" >&2
  exit 2
fi
EXPECTED_IMAGE_ID="$(printf '%s' "$EXPECTED_IMAGE_ID" | tr 'A-F' 'a-f')"
if [[ -n "$MOONCAKE_WHEEL" && ! "$MOONCAKE_WHEEL" =~ ^https?:// && "$MOONCAKE_WHEEL" != /* ]]; then
  echo "invalid_mooncake_wheel=$MOONCAKE_WHEEL" >&2
  echo "mooncake_wheel_hint=use_http_url_or_container_absolute_path" >&2
  exit 2
fi

if [[ "$PROXY_ROLE" == "decode" ]]; then PROXY_NODE="$DECODE_NODE"; PROXY_CONTAINER_ROLE="decode"; else PROXY_NODE="$PREFILL_NODE"; PROXY_CONTAINER_ROLE="prefill"; fi
if [[ -z "$IMAGE_PREFIX" ]]; then
  IMAGE_PREFIX="$(default_image_prefix)"
fi
IDENTITY_ARGS=(--model-short "$MODEL_SHORT" --mode "$TEST_MODE" --shell)
[[ -z "$RUN_ID" ]] || IDENTITY_ARGS+=(--run-id "$RUN_ID")
eval "$(python3 "$SCRIPT_DIR/run_identity.py" "${IDENTITY_ARGS[@]}")"
CONTAINER_RUN_TOKEN="$(date +%H%M%S)-${INVOCATION_ID##*-}"
PREFILL_CONTAINER="${PD_ROLES_PREFILL_CONTAINER:-${CONTAINER_PREFIX}-${MODEL_SHORT}p-${IMAGE_PREFIX}-${CONTAINER_RUN_TOKEN}}"
DECODE_CONTAINER="${PD_ROLES_DECODE_CONTAINER:-${CONTAINER_PREFIX}-${MODEL_SHORT}d-${IMAGE_PREFIX}-${CONTAINER_RUN_TOKEN}}"
if [[ "$PROXY_CONTAINER_ROLE" == "decode" ]]; then PROXY_CONTAINER="$DECODE_CONTAINER"; else PROXY_CONTAINER="$PREFILL_CONTAINER"; fi
WORK_DIR_CONTAINER="${OUTPUT_CONTAINER_ROOT}/work_dirs/${RUN_ID}"
WORK_DIR_HOST="$(to_host_path "$WORK_DIR_CONTAINER")"; STATE_CONTAINER="${WORK_DIR_CONTAINER}/state.json"
STATE_HOST="$(to_host_path "$STATE_CONTAINER")"; REPORT_DIR="${OUTPUT_HOST_ROOT}/reports"
if [[ "$DRY_RUN" == "0" && -e "$STATE_HOST" ]]; then
  echo "run_id_conflict=$RUN_ID state=$STATE_HOST" >&2
  exit 2
fi
CSV_HOST="${WORK_DIR_HOST}/csvs/${TEST_MODE}/all.csv"; PROXY_LOG="${WORK_DIR_CONTAINER}/logs/mooncake-proxy-${PROXY_PORT}.log"
PREFILL_LOG="${WORK_DIR_CONTAINER}/logs/${MODEL_SHORT}-prefill-vllm-server.log"; DECODE_LOG="${WORK_DIR_CONTAINER}/logs/${MODEL_SHORT}-decode-vllm-server.log"
TMP_DIR="$(mktemp -d)"; trap 'rm -rf "$TMP_DIR"' EXIT
PREFILL_CONTAINER_MAY_EXIST=0; DECODE_CONTAINER_MAY_EXIST=0
DRY_ARGS=(); if [[ "$DRY_RUN" == "1" ]]; then DRY_ARGS=(--dry-run); fi
ASSUME_ARGS=(); if [[ "$ASSUME_YES" == "1" ]]; then ASSUME_ARGS=(--assume-yes); fi
COMMON_ARGS=(--user "$SKILL_USER" --abbr "$USER_ABBR" --home-root "$HOME_ROOT" --host-home-root "$HOST_HOME_ROOT" --skill-host-root "$SKILL_HOST_ROOT" --output-host-root "$OUTPUT_HOST_ROOT" --output-container-root "$OUTPUT_CONTAINER_ROOT" --container-prefix "$CONTAINER_PREFIX")
TEST_STATE_ARGS=(--set "test.mode=$TEST_MODE")
if [[ "$TEST_MODE" == "custom" ]]; then
  TEST_STATE_ARGS+=(--set "test.params.input_lens=$CUSTOM_INPUT_LENS" --set "test.params.output_len=$CUSTOM_OUTPUT_LEN")
  TEST_STATE_ARGS+=(--set "test.params.concurrencies=$CUSTOM_CONCURRENCIES" --set "test.params.num_prompts_mult=$CUSTOM_NUM_PROMPTS_MULT")
  TEST_STATE_ARGS+=(--set "test.params.request_rate=$CUSTOM_REQUEST_RATE" --set "test.params.percentiles=$CUSTOM_PERCENTILES")
else
  TEST_STATE_ARGS+=(--set "test.params.input_len=$PCHIT_INPUT_LEN" --set "test.params.output_len=$PCHIT_OUTPUT_LEN")
  TEST_STATE_ARGS+=(--set "test.params.batches=$PCHIT_BATCHES" --set "test.params.pc_hit_target=$PCHIT_TARGET_PCT")
  TEST_STATE_ARGS+=(--set "test.params.pchit_benchmark_mode=$PCHIT_BENCHMARK_MODE" --set "test.params.ttft_sla_ms=$PCHIT_TTFT_SLA_MS")
  TEST_STATE_ARGS+=(--set "test.params.tpot_sla_ms=$PCHIT_TPOT_SLA_MS" --set "test.params.sla_stat=$PCHIT_SLA_STAT")
fi

cat <<EOF
EFFECTIVE_CONFIG_READY=1
SELECTED_IMAGE=$IMAGE
EXPECTED_IMAGE_ID=${EXPECTED_IMAGE_ID:-not_set}
MOONCAKE_WHEEL=${MOONCAKE_WHEEL:-not_set}
MOONCAKE_DEST_DEVICE_AFFINITY=$MOONCAKE_DEST_DEVICE_AFFINITY
MAX_MODEL_LEN=${MAX_MODEL_LEN:-not_set}
GPU_MEMORY_UTILIZATION=${GPU_MEMORY_UTILIZATION:-not_set}
BENCH_TIMEOUT=$BENCH_TIMEOUT
HOST_MODEL_PATH=$HOST_MODEL_PATH
CONTAINER_MODEL_PATH=$CONTAINER_MODEL_PATH
PREFILL_NODE=$PREFILL_NODE
PREFILL_SERVICE_IP=$PREFILL_SERVICE_IP
PREFILL_VLLM_HOST_IP=$PREFILL_VLLM_HOST_IP
PREFILL_PORT=$PREFILL_PORT
PREFILL_TRANSFER_PORT=$PREFILL_TRANSFER_PORT
DECODE_NODE=$DECODE_NODE
DECODE_SERVICE_IP=$DECODE_SERVICE_IP
DECODE_VLLM_HOST_IP=$DECODE_VLLM_HOST_IP
DECODE_PORT=$DECODE_PORT
PROXY_NODE=$PROXY_NODE
PROXY_PORT=$PROXY_PORT
NETWORK_IFNAME=${NETWORK_IFNAME:-not_set}
NCCL_IB_HCA=${NCCL_IB_HCA:-not_set}
TASK_RUN_ID=$RUN_ID
INVOCATION_ID=$INVOCATION_ID
PD_BACKEND=$PD_BACKEND
PD_TOPOLOGY=$PD_TOPOLOGY
PREFILL_CONTAINER=$PREFILL_CONTAINER
DECODE_CONTAINER=$DECODE_CONTAINER
PROXY_CONTAINER=$PROXY_CONTAINER
TEST_MODE=$TEST_MODE
CUSTOM_INPUT_LENS=${CUSTOM_INPUT_LENS:-not_applicable}
CUSTOM_OUTPUT_LEN=${CUSTOM_OUTPUT_LEN:-not_applicable}
CUSTOM_CONCURRENCIES=${CUSTOM_CONCURRENCIES:-not_applicable}
PCHIT_INPUT_LEN=${PCHIT_INPUT_LEN:-not_applicable}
PCHIT_OUTPUT_LEN=${PCHIT_OUTPUT_LEN:-not_applicable}
PCHIT_BATCHES=${PCHIT_BATCHES:-not_applicable}
WORK_DIR_HOST=$WORK_DIR_HOST
STATE_HOST=$STATE_HOST
EFFECTIVE_CONFIG_END=1
EOF

if [[ "$DRY_RUN" == "0" ]]; then
  run_stage initialize_state "$TMP_DIR/initialize_state.out" python3 "$SCRIPT_DIR/update_state.py" --state "$STATE_HOST" --reset --set "status=INITIALIZED" --set "config.path=$CONFIG_PATH" --set "invocation_id=$INVOCATION_ID" --set "image=$IMAGE" --set "ops.version=$SCRIPT_VERSION" \
    --set "model.name=$MODEL_NAME" --set "model.model_short=$MODEL_SHORT" --set "model.host_model_path=$HOST_MODEL_PATH" --set "model.container_model_path=$CONTAINER_MODEL_PATH" \
    --set "pd.backend=$PD_BACKEND" --set "pd.topology=$PD_TOPOLOGY" \
    --set "pd.runtime.mooncake_wheel=$MOONCAKE_WHEEL" \
    --set "pd.runtime.mooncake_dest_device_affinity=$MOONCAKE_DEST_DEVICE_AFFINITY" \
    --set "pd.service_defaults.max_model_len=$MAX_MODEL_LEN" \
    --set "pd.service_defaults.gpu_memory_utilization=$GPU_MEMORY_UTILIZATION" \
    --set "pd.roles.prefill.node=$PREFILL_NODE" --set "pd.roles.prefill.service_ip=$PREFILL_SERVICE_IP" --set "pd.roles.prefill.vllm_host_ip=$PREFILL_VLLM_HOST_IP" --set "pd.roles.prefill.port=$PREFILL_PORT" --set "pd.roles.prefill.transfer_port=$PREFILL_TRANSFER_PORT" --set "pd.roles.prefill.container=$PREFILL_CONTAINER" \
    --set "pd.roles.decode.node=$DECODE_NODE" --set "pd.roles.decode.service_ip=$DECODE_SERVICE_IP" --set "pd.roles.decode.vllm_host_ip=$DECODE_VLLM_HOST_IP" --set "pd.roles.decode.port=$DECODE_PORT" --set "pd.roles.decode.container=$DECODE_CONTAINER" \
    --set "pd.proxy.node=$PROXY_NODE" --set "pd.proxy.container=$PROXY_CONTAINER" --set "pd.proxy.port=$PROXY_PORT" \
    --set "test.bench_timeout_seconds=$BENCH_TIMEOUT" \
    "${TEST_STATE_ARGS[@]}" \
    --set "cleanup.policy=$([[ "$KEEP_CONTAINERS_ON_FAILURE" == "1" ]] && echo keep_on_late_failure || echo auto_stop)" --set "cleanup.containers_preserved=false" \
    --set "paths.work_dir_host=$WORK_DIR_HOST" --set "paths.work_dir_container=$WORK_DIR_CONTAINER" --set "paths.state_file_host=$STATE_HOST" --set "paths.state_file_container=$STATE_CONTAINER" --set "paths.csv_file_host=$CSV_HOST"
fi
run_stage ensure_workspace "$TMP_DIR/workspace.out" bash "$SCRIPT_DIR/ensure_workspace.sh" --node "$PREFILL_NODE" "${COMMON_ARGS[@]}" "${ASSUME_ARGS[@]}" "${DRY_ARGS[@]}"

IMAGE_ID_ARGS=(); if [[ -n "$EXPECTED_IMAGE_ID" ]]; then IMAGE_ID_ARGS=(--image-id "$EXPECTED_IMAGE_ID"); fi
run_stage preflight_pd "$TMP_DIR/preflight.out" bash "$SCRIPT_DIR/preflight_pd_node.sh" --prefill-node "$PREFILL_NODE" --decode-node "$DECODE_NODE" --proxy-node "$PROXY_NODE" --image "$IMAGE" "${IMAGE_ID_ARGS[@]}" --prefill-port "$PREFILL_PORT" --decode-port "$DECODE_PORT" --proxy-port "$PROXY_PORT" --host-model-path "$HOST_MODEL_PATH" --network-ifname "$NETWORK_IFNAME" --nccl-ib-hca "$NCCL_IB_HCA" --skill-host-root "$SKILL_HOST_ROOT" --prefill-server-script "$PREFILL_SERVER_SCRIPT" --decode-server-script "$DECODE_SERVER_SCRIPT" --proxy-launcher-script "$PROXY_LAUNCHER_SCRIPT" --mooncake-proxy-script "$MOONCAKE_PROXY_SCRIPT" "${DRY_ARGS[@]}"
if [[ "$DRY_RUN" == "0" ]]; then
  PREFILL_IMAGE_ID="$(extract_value PREFILL_IMAGE_ID "$TMP_DIR/preflight.out" || true)"
  DECODE_IMAGE_ID="$(extract_value DECODE_IMAGE_ID "$TMP_DIR/preflight.out" || true)"
  if [[ -z "$PREFILL_IMAGE_ID" || -z "$DECODE_IMAGE_ID" ]]; then
    printf 'IMAGE_ID_OUTPUT_MISSING prefill=%s decode=%s\n' "$PREFILL_IMAGE_ID" "$DECODE_IMAGE_ID" >"$TMP_DIR/record_image_ids.out"
    fail_task record_image_ids 1 "$TMP_DIR/record_image_ids.out"
  fi
  run_stage record_image_ids "$TMP_DIR/record_image_ids.out" update_state_host \
    --set "image_ref=$IMAGE" --set "image_ids.prefill=$PREFILL_IMAGE_ID" --set "image_ids.decode=$DECODE_IMAGE_ID"
fi

run_stage create_prefill_container "$TMP_DIR/create_prefill.out" bash "$SCRIPT_DIR/create_container.sh" --node "$PREFILL_NODE" --image "$IMAGE" --model-short "${MODEL_SHORT}p" --name "$PREFILL_CONTAINER" --date "$DATE_PART" --image-prefix "$IMAGE_PREFIX" --host-model-path "$HOST_MODEL_PATH" --container-model-path "$CONTAINER_MODEL_PATH" "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}"
PREFILL_CONTAINER_MAY_EXIST=1
run_stage create_decode_container "$TMP_DIR/create_decode.out" bash "$SCRIPT_DIR/create_container.sh" --node "$DECODE_NODE" --image "$IMAGE" --model-short "${MODEL_SHORT}d" --name "$DECODE_CONTAINER" --date "$DATE_PART" --image-prefix "$IMAGE_PREFIX" --host-model-path "$HOST_MODEL_PATH" --container-model-path "$CONTAINER_MODEL_PATH" "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}"
DECODE_CONTAINER_MAY_EXIST=1

RUNTIME_WHEEL_ARGS=(); if [[ -n "$MOONCAKE_WHEEL" ]]; then RUNTIME_WHEEL_ARGS=(--mooncake-wheel "$MOONCAKE_WHEEL"); fi
run_stage prepare_prefill_runtime "$TMP_DIR/runtime_prefill.out" env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" bash "$SCRIPT_DIR/prepare_pd_runtime.sh" --role prefill --node "$PREFILL_NODE" --container "$PREFILL_CONTAINER" --work-dir "$WORK_DIR_CONTAINER" --state "$STATE_CONTAINER" "${RUNTIME_WHEEL_ARGS[@]}" "${DRY_ARGS[@]}"
run_stage prepare_decode_runtime "$TMP_DIR/runtime_decode.out" env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" bash "$SCRIPT_DIR/prepare_pd_runtime.sh" --role decode --node "$DECODE_NODE" --container "$DECODE_CONTAINER" --work-dir "$WORK_DIR_CONTAINER" --state "$STATE_CONTAINER" "${RUNTIME_WHEEL_ARGS[@]}" "${DRY_ARGS[@]}"

run_stage start_prefill "$TMP_DIR/start_prefill.out" env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" bash "$SCRIPT_DIR/start_pd_role_service.sh" --role prefill --server-script "$PREFILL_SERVER_SCRIPT" --node "$PREFILL_NODE" --container "$PREFILL_CONTAINER" --model-name "$MODEL_NAME" --model-short "$MODEL_SHORT" --container-model-path "$CONTAINER_MODEL_PATH" --host-model-path "$HOST_MODEL_PATH" --port "$PREFILL_PORT" --transfer-port "$PREFILL_TRANSFER_PORT" --tp "$TP" --gpu-range "$GPU_RANGE" --work-dir "$WORK_DIR_CONTAINER" --state "$STATE_CONTAINER" --vllm-host-ip "$PREFILL_VLLM_HOST_IP" --network-ifname "$NETWORK_IFNAME" --nccl-ib-hca "$NCCL_IB_HCA" --mooncake-dest-device-affinity "$MOONCAKE_DEST_DEVICE_AFFINITY" --quantization "$QUANTIZATION" --dtype "$DTYPE" --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" --max-num-seqs "$MAX_NUM_SEQS" --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" --max-model-len "$MAX_MODEL_LEN" --speculative-config "$SPECULATIVE_CONFIG" --compilation-config "$COMPILATION_CONFIG" --extra-args "$PREFILL_EXTRA_ARGS" "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}"
run_stage start_decode "$TMP_DIR/start_decode.out" env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" bash "$SCRIPT_DIR/start_pd_role_service.sh" --role decode --server-script "$DECODE_SERVER_SCRIPT" --node "$DECODE_NODE" --container "$DECODE_CONTAINER" --model-name "$MODEL_NAME" --model-short "$MODEL_SHORT" --container-model-path "$CONTAINER_MODEL_PATH" --host-model-path "$HOST_MODEL_PATH" --port "$DECODE_PORT" --tp "$TP" --gpu-range "$GPU_RANGE" --work-dir "$WORK_DIR_CONTAINER" --state "$STATE_CONTAINER" --vllm-host-ip "$DECODE_VLLM_HOST_IP" --network-ifname "$NETWORK_IFNAME" --nccl-ib-hca "$NCCL_IB_HCA" --mooncake-dest-device-affinity "$MOONCAKE_DEST_DEVICE_AFFINITY" --quantization "$QUANTIZATION" --dtype "$DTYPE" --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" --max-num-seqs "$MAX_NUM_SEQS" --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" --max-model-len "$MAX_MODEL_LEN" --speculative-config "$SPECULATIVE_CONFIG" --compilation-config "$COMPILATION_CONFIG" --extra-args "$DECODE_EXTRA_ARGS" "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}"

run_stage wait_prefill "$TMP_DIR/wait_prefill.out" env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" bash "$SCRIPT_DIR/wait_vllm_ready.sh" --role prefill --node "$PREFILL_NODE" --container "$PREFILL_CONTAINER" --port "$PREFILL_PORT" --log "$PREFILL_LOG" --model-path "$CONTAINER_MODEL_PATH" --state "$STATE_CONTAINER" --timeout "$READY_TIMEOUT" --interval "$INTERVAL" "${DRY_ARGS[@]}"
run_stage wait_decode "$TMP_DIR/wait_decode.out" env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" bash "$SCRIPT_DIR/wait_vllm_ready.sh" --role decode --node "$DECODE_NODE" --container "$DECODE_CONTAINER" --port "$DECODE_PORT" --log "$DECODE_LOG" --model-path "$CONTAINER_MODEL_PATH" --state "$STATE_CONTAINER" --timeout "$READY_TIMEOUT" --interval "$INTERVAL" "${DRY_ARGS[@]}"
if [[ "$DRY_RUN" == "0" ]]; then
  PREFILL_LOG_HOST="$(to_host_path "$PREFILL_LOG")"
  DECODE_LOG_HOST="$(to_host_path "$DECODE_LOG")"
  run_stage diagnose_prefill_transfer "$TMP_DIR/diagnose_prefill_transfer.out" python3 "$SCRIPT_DIR/mooncake_transfer_diagnostics.py" --state "$STATE_HOST" --role prefill --log "$PREFILL_LOG_HOST" --configured-hcas "$NCCL_IB_HCA"
  run_stage diagnose_decode_transfer "$TMP_DIR/diagnose_decode_transfer.out" python3 "$SCRIPT_DIR/mooncake_transfer_diagnostics.py" --state "$STATE_HOST" --role decode --log "$DECODE_LOG_HOST" --configured-hcas "$NCCL_IB_HCA"
fi
DECODE_SERVED_MODEL_ID="$(extract_value SERVED_MODEL_ID "$TMP_DIR/wait_decode.out" || true)"
BENCH_MODEL_ID="${DECODE_SERVED_MODEL_ID:-$CONTAINER_MODEL_PATH}"; BENCH_MODEL_ID_SOURCE="config_fallback"
if [[ -n "$DECODE_SERVED_MODEL_ID" ]]; then BENCH_MODEL_ID_SOURCE="decode"; fi
if [[ "$DRY_RUN" == "0" ]]; then
  run_stage record_bench_model "$TMP_DIR/record_bench_model.out" update_state_host --set "model.bench_model_id=$BENCH_MODEL_ID" --set "model.bench_model_id_source=$BENCH_MODEL_ID_SOURCE"
fi

PREFILL_URL="http://${PREFILL_SERVICE_IP}:${PREFILL_PORT}"; DECODE_URL="http://${DECODE_SERVICE_IP}:${DECODE_PORT}"
run_stage start_proxy "$TMP_DIR/start_proxy.out" env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" bash "$SCRIPT_DIR/start_mooncake_proxy.sh" --node "$PROXY_NODE" --container "$PROXY_CONTAINER" --launcher-script "$PROXY_LAUNCHER_SCRIPT" --work-dir "$WORK_DIR_CONTAINER" --state "$STATE_CONTAINER" --prefill-url "$PREFILL_URL" --prefill-transfer-port "$PREFILL_TRANSFER_PORT" --decode-url "$DECODE_URL" --port "$PROXY_PORT" --mooncake-proxy-script "$MOONCAKE_PROXY_SCRIPT" "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}"
run_stage wait_proxy "$TMP_DIR/wait_proxy.out" env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" bash "$SCRIPT_DIR/wait_mooncake_proxy_ready.sh" --node "$PROXY_NODE" --container "$PROXY_CONTAINER" --port "$PROXY_PORT" --state "$STATE_CONTAINER" --log "$PROXY_LOG" --model-id "$BENCH_MODEL_ID" --prefill-url "$PREFILL_URL" --prefill-transfer-port "$PREFILL_TRANSFER_PORT" --decode-url "$DECODE_URL" --timeout "$PROXY_TIMEOUT" --request-timeout "$PROXY_REQUEST_TIMEOUT" --interval "$INTERVAL" "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}"

if [[ "$TEST_MODE" == "pchit" ]]; then
  BENCH_ENV=(env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" IMAGE_NAME="$IMAGE" INPUT_LEN="$PCHIT_INPUT_LEN" OUTPUT_LEN="$PCHIT_OUTPUT_LEN" BATCHES="$PCHIT_BATCHES" CONCURRENCY_MULTIPLIER="${TEST_PARAMS_CONCURRENCY_MULTIPLIER:-1}" PCHIT_TARGET_PCT="$PCHIT_TARGET_PCT" PCHIT_BENCHMARK_MODE="$PCHIT_BENCHMARK_MODE" TTFT_SLA_MS="$PCHIT_TTFT_SLA_MS" TPOT_SLA_MS="$PCHIT_TPOT_SLA_MS" SLA_STAT="$PCHIT_SLA_STAT" PREFIX_WARMUP_REQUESTS="${TEST_PARAMS_PREFIX_WARMUP_REQUESTS:-1}" CASE_WARMUP_REPEATS="${TEST_PARAMS_CASE_WARMUP_REPEATS:-0}" REQUEST_RATE="${TEST_PARAMS_REQUEST_RATE:-}")
else
  BENCH_ENV=(env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" IMAGE_NAME="$IMAGE" INPUT_LENS="$CUSTOM_INPUT_LENS" OUTPUT_LEN="$CUSTOM_OUTPUT_LEN" CONCURRENCIES="$CUSTOM_CONCURRENCIES" NUM_PROMPTS_MULT="$CUSTOM_NUM_PROMPTS_MULT" PERCENTILES="$CUSTOM_PERCENTILES" REQUEST_RATE="$CUSTOM_REQUEST_RATE")
fi
run_stage run_bench "$TMP_DIR/bench.out" "${BENCH_ENV[@]}" bash "$SCRIPT_DIR/run_bench.sh" --node "$PROXY_NODE" --container "$PROXY_CONTAINER" --test-mode "$TEST_MODE" --served-model-id "$BENCH_MODEL_ID" --port "$PROXY_PORT" --tp "$TP" --work-dir "$WORK_DIR_CONTAINER" --state "$STATE_CONTAINER" --prefill-log "$PREFILL_LOG" --decode-log "$DECODE_LOG" --bench-timeout "$BENCH_TIMEOUT" "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}"
CSV_HOST="$(extract_value CSV_HOST "$TMP_DIR/bench.out" || true)"; [[ -n "$CSV_HOST" ]] || CSV_HOST="${WORK_DIR_HOST}/csvs/${TEST_MODE}/all.csv"

echo "== stop_decode =="
if bash "$SCRIPT_DIR/stop_service.sh" --role decode --node "$DECODE_NODE" --container "$DECODE_CONTAINER" --port "$DECODE_PORT" --state "$STATE_HOST" "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}"; then
  DECODE_STOP_RC=0
else
  DECODE_STOP_RC=$?
fi
echo "== stop_prefill =="
if bash "$SCRIPT_DIR/stop_service.sh" --role prefill --node "$PREFILL_NODE" --container "$PREFILL_CONTAINER" --port "$PREFILL_PORT" --state "$STATE_HOST" "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}"; then
  PREFILL_STOP_RC=0
else
  PREFILL_STOP_RC=$?
fi

if [[ "$DRY_RUN" == "1" ]]; then
  [[ "$DECODE_STOP_RC" == "0" && "$PREFILL_STOP_RC" == "0" ]] || exit 1
  echo "PD_DRY_RUN_DONE=1"
  exit 0
fi
if [[ "$DECODE_STOP_RC" != "0" || "$PREFILL_STOP_RC" != "0" ]]; then
  update_state_host --set "status=STOP_FAILED" --set "failure.stage=stop" --set "failure.decode_stop_rc=$DECODE_STOP_RC" --set "failure.prefill_stop_rc=$PREFILL_STOP_RC" >/dev/null || true
  render_report || true
  emit_task_summary
  echo "PD_TASK_FAILED=1" >&2
  echo "STATE_HOST=$STATE_HOST" >&2
  echo "REPORT_JSON_HOST=${REPORT_DIR}/${RUN_ID}.json" >&2
  echo "REPORT_MD_HOST=${REPORT_DIR}/${RUN_ID}.md" >&2
  exit 1
fi

DECODE_CONTAINER_MAY_EXIST=0
PREFILL_CONTAINER_MAY_EXIST=0
run_stage finalize_state "$TMP_DIR/finalize_state.out" update_state_host --set "status=COMPLETED" --set "test.status=COMPLETED"
run_stage render_report "$TMP_DIR/render_report.out" render_report
emit_task_summary
echo "PD_TASK_DONE=1"
