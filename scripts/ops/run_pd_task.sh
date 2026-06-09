#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  run_pd_task.sh --config references/examples/glm47-vllm018-mooncake-1p1d-custom.yaml \
    --user USER --abbr ABBR [--assume-yes] [--dry-run] [--image-prefix PREFIX]
USAGE
}

quote_sh() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
extract_value() { grep -E "^$1=" "$2" | tail -1 | cut -d= -f2-; }
run_step_capture() {
  local name="$1" outfile="$2"; shift 2
  echo "== ${name} =="
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY_RUN_STEP:'
    printf ' %q' "$@"
    printf '\n'
  fi
  "$@" 2>&1 | tee "$outfile"
}
inspect_image_prefix() {
  local node="$1" image="$2" image_id
  image_id="$(ssh "$node" "docker image inspect $(quote_sh "$image") --format '{{.Id}}'" 2>/dev/null | head -1 || true)"
  image_id="${image_id#sha256:}"
  image_id="$(printf '%s' "$image_id" | tr -cd 'A-Za-z0-9')"
  if [[ ${#image_id} -ge 4 ]]; then printf '%s\n' "${image_id:0:4}"; return 0; fi
  echo "Cannot resolve image id; pass --image-prefix for dry-run or confirm image exists." >&2
  return 1
}
to_host_path() {
  local path="$1"
  if [[ "$path" == "$OUTPUT_CONTAINER_ROOT"* ]]; then
    printf '%s%s\n' "$OUTPUT_HOST_ROOT" "${path#$OUTPUT_CONTAINER_ROOT}"
  else
    printf '%s\n' "$path"
  fi
}

CONFIG=""; ASSUME_YES=0; DRY_RUN=0; IMAGE_PREFIX=""; DATE_PART="$(date +%m%d)"; RUN_ID=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/runtime_config.sh"
SKILL_USER=""; USER_ABBR=""; HOME_ROOT=""; HOST_HOME_ROOT=""; SKILL_HOST_ROOT=""; OUTPUT_HOST_ROOT="${OUTPUT_HOST_ROOT:-}"; OUTPUT_CONTAINER_ROOT="${OUTPUT_CONTAINER_ROOT:-}"; CONTAINER_PREFIX=""
while [[ $# -gt 0 ]]; do
  if runtime_config_parse_common_arg "$1" "${2-}"; then shift 2; continue; fi
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --date) DATE_PART="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --image-prefix) IMAGE_PREFIX="$2"; shift 2 ;;
    --assume-yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$CONFIG" ]] || { echo "missing --config" >&2; usage; exit 2; }
resolve_runtime_config
CONFIG_PATH="$CONFIG"
[[ "$CONFIG_PATH" == /* ]] || CONFIG_PATH="$SKILL_ROOT/$CONFIG_PATH"
eval "$(python3 "$SCRIPT_DIR/pd_config.py" --config "$CONFIG_PATH" --shell)"

MODE="${MODE:-pd}"
PD_BACKEND="${PD_BACKEND:-mooncake_vllm018}"
PD_TOPOLOGY="${PD_TOPOLOGY:-1p1d}"
TEST_MODE="${TEST_MODE:-custom}"
IMAGE="${IMAGE_NAME:-}"
MODEL_NAME="${MODEL_NAME:-}"
MODEL_SHORT="${MODEL_MODEL_SHORT:-${MODEL_SHORT:-}}"
HOST_MODEL_PATH="${MODEL_HOST_MODEL_PATH:-}"
CONTAINER_MODEL_PATH="${MODEL_CONTAINER_MODEL_PATH:-}"
PREFILL_NODE="${PD_ROLES_PREFILL_NODE:-}"
PREFILL_SERVICE_IP="${PD_ROLES_PREFILL_SERVICE_IP:-$PREFILL_NODE}"
PREFILL_VLLM_HOST_IP="${PD_ROLES_PREFILL_VLLM_HOST_IP:-$PREFILL_NODE}"
PREFILL_PORT="${PD_ROLES_PREFILL_PORT:-9348}"
PREFILL_TRANSFER_PORT="${PD_ROLES_PREFILL_TRANSFER_PORT:-8998}"
DECODE_NODE="${PD_ROLES_DECODE_NODE:-}"
DECODE_SERVICE_IP="${PD_ROLES_DECODE_SERVICE_IP:-$DECODE_NODE}"
DECODE_VLLM_HOST_IP="${PD_ROLES_DECODE_VLLM_HOST_IP:-$DECODE_NODE}"
DECODE_PORT="${PD_ROLES_DECODE_PORT:-9349}"
PROXY_ROLE="${PD_PROXY_NODE_ROLE:-prefill}"
PROXY_PORT="${PD_PROXY_PORT:-8000}"
NETWORK_IFNAME="${PD_NETWORK_IFNAME:-}"
NCCL_IB_HCA="${PD_NETWORK_NCCL_IB_HCA:-}"
MOONCAKE_PROXY_SCRIPT="${PD_MOONCAKE_PROXY_SCRIPT:-mooncake/examples/online_serving/disaggregated_serving/mooncake_connector/mooncake_connector_proxy.py}"
TP="${PD_SERVICE_DEFAULTS_TP:-8}"
GPU_RANGE="${PD_SERVICE_DEFAULTS_GPU_RANGE:-0,1,2,3,4,5,6,7}"
QUANTIZATION="${PD_SERVICE_DEFAULTS_QUANTIZATION:-slimquant_marlin}"
DTYPE="${PD_SERVICE_DEFAULTS_DTYPE:-bfloat16}"
MAX_NUM_BATCHED_TOKENS="${PD_SERVICE_DEFAULTS_MAX_NUM_BATCHED_TOKENS:-16384}"
MAX_NUM_SEQS="${PD_SERVICE_DEFAULTS_MAX_NUM_SEQS:-256}"
GPU_MEMORY_UTILIZATION="${PD_SERVICE_DEFAULTS_GPU_MEMORY_UTILIZATION:-0.9}"
MAX_MODEL_LEN="${PD_SERVICE_DEFAULTS_MAX_MODEL_LEN:-40960}"
SPECULATIVE_CONFIG="${PD_SERVICE_DEFAULTS_SPECULATIVE_CONFIG:-{\"method\":\"mtp\",\"num_speculative_tokens\":2,\"quantization\":\"slimquant_marlin\"}}"
COMPILATION_CONFIG="${PD_SERVICE_DEFAULTS_COMPILATION_CONFIG:-{\"cudagraph_mode\":\"PIECEWISE\"}}"

for var in IMAGE MODEL_NAME MODEL_SHORT HOST_MODEL_PATH CONTAINER_MODEL_PATH PREFILL_NODE DECODE_NODE NETWORK_IFNAME; do
  [[ -n "${!var}" ]] || { echo "missing required config value: $var" >&2; exit 2; }
done
[[ "$MODE" == "pd" ]] || { echo "run_pd_task.sh requires mode: pd; got $MODE" >&2; exit 2; }
[[ "$PD_BACKEND" == "mooncake_vllm018" ]] || { echo "unsupported pd.backend: $PD_BACKEND" >&2; exit 2; }
[[ "$PD_TOPOLOGY" == "1p1d" ]] || { echo "pd.topology=$PD_TOPOLOGY is planned but not implemented" >&2; exit 2; }
[[ "$TEST_MODE" == "custom" || "$TEST_MODE" == "pchit" ]] || { echo "PD supports custom and pchit only; got $TEST_MODE" >&2; exit 2; }
if [[ "$PROXY_ROLE" == "decode" ]]; then PROXY_NODE="$DECODE_NODE"; PROXY_CONTAINER_ROLE="decode"; else PROXY_NODE="$PREFILL_NODE"; PROXY_CONTAINER_ROLE="prefill"; fi
if [[ -z "$IMAGE_PREFIX" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then IMAGE_PREFIX="AUTO"; else IMAGE_PREFIX="$(inspect_image_prefix "$PREFILL_NODE" "$IMAGE")"; fi
fi
PREFILL_CONTAINER="${PD_ROLES_PREFILL_CONTAINER:-${CONTAINER_PREFIX}-${DATE_PART}-${MODEL_SHORT}p-${IMAGE_PREFIX}}"
DECODE_CONTAINER="${PD_ROLES_DECODE_CONTAINER:-${CONTAINER_PREFIX}-${DATE_PART}-${MODEL_SHORT}d-${IMAGE_PREFIX}}"
if [[ "$PROXY_CONTAINER_ROLE" == "decode" ]]; then PROXY_CONTAINER="$DECODE_CONTAINER"; else PROXY_CONTAINER="$PREFILL_CONTAINER"; fi
[[ -n "$RUN_ID" ]] || RUN_ID="${MODEL_SHORT}-${TEST_MODE}-pd-${PD_TOPOLOGY}-$(date +%Y%m%d)-${CONTAINER_PREFIX}-${IMAGE_PREFIX}"
WORK_DIR_CONTAINER="${OUTPUT_CONTAINER_ROOT}/work_dirs/${MODEL_NAME}-${TEST_MODE}-pd-${PD_TOPOLOGY}-$(date +%Y%m%d)-${CONTAINER_PREFIX}-${IMAGE_PREFIX}"
WORK_DIR_HOST="$(to_host_path "$WORK_DIR_CONTAINER")"
STATE_CONTAINER="${WORK_DIR_CONTAINER}/state.json"
STATE_HOST="$(to_host_path "$STATE_CONTAINER")"
REPORT_DIR="${OUTPUT_HOST_ROOT}/reports"
TMP_DIR="$(mktemp -d)"; trap 'rm -rf "$TMP_DIR"' EXIT
DRY_ARGS=(); [[ "$DRY_RUN" == "1" ]] && DRY_ARGS=(--dry-run)
ASSUME_ARGS=(); [[ "$ASSUME_YES" == "1" ]] && ASSUME_ARGS=(--assume-yes)
COMMON_ARGS=(--user "$SKILL_USER" --abbr "$USER_ABBR" --home-root "$HOME_ROOT" --host-home-root "$HOST_HOME_ROOT" --skill-host-root "$SKILL_HOST_ROOT" --output-host-root "$OUTPUT_HOST_ROOT" --output-container-root "$OUTPUT_CONTAINER_ROOT" --container-prefix "$CONTAINER_PREFIX")

cat <<EOF
TASK_RUN_ID=$RUN_ID
PD_BACKEND=$PD_BACKEND
PD_TOPOLOGY=$PD_TOPOLOGY
PREFILL_CONTAINER=$PREFILL_CONTAINER
DECODE_CONTAINER=$DECODE_CONTAINER
PROXY_CONTAINER=$PROXY_CONTAINER
PROXY_PORT=$PROXY_PORT
TEST_MODE=$TEST_MODE
WORK_DIR_HOST=$WORK_DIR_HOST
STATE_HOST=$STATE_HOST
EOF

run_step_capture preflight_pd "$TMP_DIR/preflight.out" bash "$SCRIPT_DIR/preflight_pd_node.sh" --prefill-node "$PREFILL_NODE" --decode-node "$DECODE_NODE" --proxy-node "$PROXY_NODE" --image "$IMAGE" --prefill-port "$PREFILL_PORT" --decode-port "$DECODE_PORT" --proxy-port "$PROXY_PORT" --host-model-path "$HOST_MODEL_PATH" --network-ifname "$NETWORK_IFNAME" --nccl-ib-hca "$NCCL_IB_HCA" --skill-host-root "$SKILL_HOST_ROOT" --mooncake-proxy-script "$MOONCAKE_PROXY_SCRIPT" "${DRY_ARGS[@]}"
run_step_capture ensure_workspace "$TMP_DIR/workspace.out" bash "$SCRIPT_DIR/ensure_workspace.sh" --node "$PREFILL_NODE" "${COMMON_ARGS[@]}" "${ASSUME_ARGS[@]}" "${DRY_ARGS[@]}"
run_step_capture create_prefill_container "$TMP_DIR/create_prefill.out" bash "$SCRIPT_DIR/create_container.sh" --node "$PREFILL_NODE" --image "$IMAGE" --model-short "${MODEL_SHORT}p" --name "$PREFILL_CONTAINER" --date "$DATE_PART" --image-prefix "$IMAGE_PREFIX" "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}"
run_step_capture create_decode_container "$TMP_DIR/create_decode.out" bash "$SCRIPT_DIR/create_container.sh" --node "$DECODE_NODE" --image "$IMAGE" --model-short "${MODEL_SHORT}d" --name "$DECODE_CONTAINER" --date "$DATE_PART" --image-prefix "$IMAGE_PREFIX" "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}"
run_step_capture start_prefill "$TMP_DIR/start_prefill.out" env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" bash "$SCRIPT_DIR/start_pd_role_service.sh" --role prefill --node "$PREFILL_NODE" --container "$PREFILL_CONTAINER" --model-name "$MODEL_NAME" --model-short "$MODEL_SHORT" --container-model-path "$CONTAINER_MODEL_PATH" --host-model-path "$HOST_MODEL_PATH" --port "$PREFILL_PORT" --tp "$TP" --gpu-range "$GPU_RANGE" --work-dir "$WORK_DIR_CONTAINER" --state "$STATE_CONTAINER" --vllm-host-ip "$PREFILL_VLLM_HOST_IP" --network-ifname "$NETWORK_IFNAME" --nccl-ib-hca "$NCCL_IB_HCA" --quantization "$QUANTIZATION" --dtype "$DTYPE" --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" --max-num-seqs "$MAX_NUM_SEQS" --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" --max-model-len "$MAX_MODEL_LEN" --speculative-config "$SPECULATIVE_CONFIG" --compilation-config "$COMPILATION_CONFIG" "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}"
run_step_capture start_decode "$TMP_DIR/start_decode.out" env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" bash "$SCRIPT_DIR/start_pd_role_service.sh" --role decode --node "$DECODE_NODE" --container "$DECODE_CONTAINER" --model-name "$MODEL_NAME" --model-short "$MODEL_SHORT" --container-model-path "$CONTAINER_MODEL_PATH" --host-model-path "$HOST_MODEL_PATH" --port "$DECODE_PORT" --tp "$TP" --gpu-range "$GPU_RANGE" --work-dir "$WORK_DIR_CONTAINER" --state "$STATE_CONTAINER" --vllm-host-ip "$DECODE_VLLM_HOST_IP" --network-ifname "$NETWORK_IFNAME" --nccl-ib-hca "$NCCL_IB_HCA" --quantization "$QUANTIZATION" --dtype "$DTYPE" --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" --max-num-seqs "$MAX_NUM_SEQS" --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" --max-model-len "$MAX_MODEL_LEN" --speculative-config "$SPECULATIVE_CONFIG" --compilation-config "$COMPILATION_CONFIG" "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}"
PREFILL_LOG="${WORK_DIR_CONTAINER}/logs/${MODEL_SHORT}-prefill-vllm-server.log"
DECODE_LOG="${WORK_DIR_CONTAINER}/logs/${MODEL_SHORT}-decode-vllm-server.log"
run_step_capture wait_prefill "$TMP_DIR/wait_prefill.out" env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" bash "$SCRIPT_DIR/wait_vllm_ready.sh" --node "$PREFILL_NODE" --container "$PREFILL_CONTAINER" --port "$PREFILL_PORT" --log "$PREFILL_LOG" --model-path "$CONTAINER_MODEL_PATH" --state "$STATE_CONTAINER" --timeout 1800 --interval 30 "${DRY_ARGS[@]}"
run_step_capture wait_decode "$TMP_DIR/wait_decode.out" env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" bash "$SCRIPT_DIR/wait_vllm_ready.sh" --node "$DECODE_NODE" --container "$DECODE_CONTAINER" --port "$DECODE_PORT" --log "$DECODE_LOG" --model-path "$CONTAINER_MODEL_PATH" --state "$STATE_CONTAINER" --timeout 1800 --interval 30 "${DRY_ARGS[@]}"
DECODE_SERVED_MODEL_ID="$(extract_value SERVED_MODEL_ID "$TMP_DIR/wait_decode.out" || true)"
run_step_capture start_proxy "$TMP_DIR/start_proxy.out" env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" bash "$SCRIPT_DIR/start_mooncake_proxy.sh" --node "$PROXY_NODE" --container "$PROXY_CONTAINER" --work-dir "$WORK_DIR_CONTAINER" --state "$STATE_CONTAINER" --prefill-url "http://${PREFILL_SERVICE_IP}:${PREFILL_PORT}" --prefill-transfer-port "$PREFILL_TRANSFER_PORT" --decode-url "http://${DECODE_SERVICE_IP}:${DECODE_PORT}" --port "$PROXY_PORT" --mooncake-proxy-script "$MOONCAKE_PROXY_SCRIPT" "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}"
run_step_capture wait_proxy "$TMP_DIR/wait_proxy.out" env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" bash "$SCRIPT_DIR/wait_mooncake_proxy_ready.sh" --node "$PROXY_NODE" --container "$PROXY_CONTAINER" --port "$PROXY_PORT" --state "$STATE_CONTAINER" --timeout 600 --interval 10 "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}"
PROXY_SERVED_MODEL_ID="$(extract_value PROXY_SERVED_MODEL_ID "$TMP_DIR/wait_proxy.out" || true)"
BENCH_MODEL_ID="${PROXY_SERVED_MODEL_ID:-${DECODE_SERVED_MODEL_ID:-$CONTAINER_MODEL_PATH}}"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY_RUN_STEP: render_report before/after stop would use state=$STATE_HOST and csv=${WORK_DIR_HOST}/csvs/${TEST_MODE}/all.csv"
fi
if [[ "$TEST_MODE" == "pchit" ]]; then
  BENCH_ENV=(env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" IMAGE_NAME="$IMAGE" INPUT_LEN="${TEST_PARAMS_INPUT_LEN:-32768}" OUTPUT_LEN="${TEST_PARAMS_OUTPUT_LEN:-1024}" BATCHES="${TEST_PARAMS_BATCHES:-1 2 3 4 5 6 7 8}" CONCURRENCY_MULTIPLIER="${TEST_PARAMS_CONCURRENCY_MULTIPLIER:-1}" PCHIT_TARGET_PCT="${TEST_PARAMS_PC_HIT_TARGET:-90}" PCHIT_BENCHMARK_MODE="${TEST_PARAMS_PCHIT_BENCHMARK_MODE:-fixed}" TTFT_SLA_MS="${TEST_PARAMS_TTFT_SLA_MS:-5000}" TPOT_SLA_MS="${TEST_PARAMS_TPOT_SLA_MS:-50}" SLA_STAT="${TEST_PARAMS_SLA_STAT:-mean}" PREFIX_WARMUP_REQUESTS="${TEST_PARAMS_PREFIX_WARMUP_REQUESTS:-1}" CASE_WARMUP_REPEATS="${TEST_PARAMS_CASE_WARMUP_REPEATS:-0}" REQUEST_RATE="${TEST_PARAMS_REQUEST_RATE:-}")
else
  BENCH_ENV=(env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" IMAGE_NAME="$IMAGE" INPUT_LENS="${TEST_PARAMS_INPUT_LENS:-512}" OUTPUT_LEN="${TEST_PARAMS_OUTPUT_LEN:-32}" CONCURRENCIES="${TEST_PARAMS_CONCURRENCIES:-1}" NUM_PROMPTS_MULT="${TEST_PARAMS_NUM_PROMPTS_MULT:-1}" PERCENTILES="${TEST_PARAMS_PERCENTILES:-50,95,99}" REQUEST_RATE="${TEST_PARAMS_REQUEST_RATE:-}")
fi
run_step_capture run_bench "$TMP_DIR/bench.out" "${BENCH_ENV[@]}" bash "$SCRIPT_DIR/run_bench.sh" --node "$PROXY_NODE" --container "$PROXY_CONTAINER" --test-mode "$TEST_MODE" --served-model-id "$BENCH_MODEL_ID" --port "$PROXY_PORT" --tp "$TP" --work-dir "$WORK_DIR_CONTAINER" --state "$STATE_CONTAINER" "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}"
CSV_HOST="$(extract_value CSV_HOST "$TMP_DIR/bench.out" || true)"
[[ -n "$CSV_HOST" ]] || CSV_HOST="${WORK_DIR_HOST}/csvs/${TEST_MODE}/all.csv"
if [[ "$DRY_RUN" != "1" ]]; then
  OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" python3 "$SCRIPT_DIR/render_report.py" --run-id "$RUN_ID" --state "$STATE_HOST" --csv "$CSV_HOST" --report-dir "$REPORT_DIR" || true
fi
echo "== stop_decode =="
bash "$SCRIPT_DIR/stop_service.sh" --node "$DECODE_NODE" --container "$DECODE_CONTAINER" --port "$DECODE_PORT" --state "$STATE_HOST" "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}" || true
echo "== stop_prefill =="
bash "$SCRIPT_DIR/stop_service.sh" --node "$PREFILL_NODE" --container "$PREFILL_CONTAINER" --port "$PREFILL_PORT" --state "$STATE_HOST" "${COMMON_ARGS[@]}" "${DRY_ARGS[@]}" || true
if [[ "$DRY_RUN" != "1" ]]; then
  OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" python3 "$SCRIPT_DIR/render_report.py" --run-id "$RUN_ID" --state "$STATE_HOST" --csv "$CSV_HOST" --report-dir "$REPORT_DIR" || true
fi
echo "PD_TASK_DONE=1"
