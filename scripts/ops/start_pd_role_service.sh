#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  start_pd_role_service.sh --role prefill|decode --server-script PATH \
    --node NODE --container NAME --model-name NAME --model-short SHORT \
    --container-model-path PATH --host-model-path PATH --port PORT --tp TP \
    --gpu-range RANGE --work-dir WORK_DIR --state STATE \
    [--transfer-port PORT] [--vllm-host-ip IP] [--network-ifname IFNAME] \
    [--nccl-ib-hca HCA] [--mooncake-dest-device-affinity 0|1] \
    [--extra-args ARGS] [--dry-run]
USAGE
}

quote_sh() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

run_in_container() {
  local script="$1" docker_cmd
  docker_cmd="docker exec -i -w $(quote_sh "$SKILL_CONTAINER_ROOT") $(quote_sh "$CONTAINER") bash -lc 'tmp=/tmp/vllm_pd_role_\$\$.sh; cat > \"\$tmp\"; bash \"\$tmp\"; rc=\$?; rm -f \"\$tmp\"; exit \$rc'"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN_ROLE=$ROLE"
    printf 'ssh %q %q\n' "$NODE" "$docker_cmd"
    echo "--- container script ---"
    printf '%s\n' "$script"
    return 0
  fi
  printf '%s\n' "$script" | ssh "$NODE" "$docker_cmd"
}

ROLE=""; SERVER_SCRIPT_REL=""; NODE=""; CONTAINER=""; MODEL_NAME=""; MODEL_SHORT=""
CONTAINER_MODEL_PATH=""; HOST_MODEL_PATH=""; PORT=""; TRANSFER_PORT=""; TP=""
GPU_RANGE="0,1,2,3,4,5,6,7"; WORK_DIR=""; STATE=""; VLLM_HOST_IP=""
NETWORK_IFNAME=""; NCCL_IB_HCA=""; QUANTIZATION="slimquant_marlin"; DTYPE="bfloat16"
MOONCAKE_DEST_DEVICE_AFFINITY="1"
MAX_NUM_BATCHED_TOKENS="16384"; MAX_NUM_SEQS=""; GPU_MEMORY_UTILIZATION=""; MAX_MODEL_LEN=""
EXTRA_ARGS=""; SPECULATIVE_CONFIG='{"method": "mtp", "num_speculative_tokens": 2, "quantization": "slimquant_marlin"}'
COMPILATION_CONFIG='{"cudagraph_mode": "PIECEWISE"}'; DRY_RUN=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime_config.sh"
SKILL_USER=""; USER_ABBR=""; HOME_ROOT=""; HOST_HOME_ROOT=""; SKILL_HOST_ROOT=""
OUTPUT_HOST_ROOT="${OUTPUT_HOST_ROOT:-}"; OUTPUT_CONTAINER_ROOT="${OUTPUT_CONTAINER_ROOT:-}"; CONTAINER_PREFIX=""

while [[ $# -gt 0 ]]; do
  if runtime_config_parse_common_arg "$1" "${2-}"; then shift 2; continue; fi
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --server-script) SERVER_SCRIPT_REL="$2"; shift 2 ;;
    --node) NODE="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --model-name) MODEL_NAME="$2"; shift 2 ;;
    --model-short) MODEL_SHORT="$2"; shift 2 ;;
    --container-model-path) CONTAINER_MODEL_PATH="$2"; shift 2 ;;
    --host-model-path) HOST_MODEL_PATH="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --transfer-port) TRANSFER_PORT="$2"; shift 2 ;;
    --tp) TP="$2"; shift 2 ;;
    --gpu-range) GPU_RANGE="$2"; shift 2 ;;
    --work-dir) WORK_DIR="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --vllm-host-ip) VLLM_HOST_IP="$2"; shift 2 ;;
    --network-ifname) NETWORK_IFNAME="$2"; shift 2 ;;
    --nccl-ib-hca) NCCL_IB_HCA="$2"; shift 2 ;;
    --mooncake-dest-device-affinity) MOONCAKE_DEST_DEVICE_AFFINITY="$2"; shift 2 ;;
    --quantization) QUANTIZATION="$2"; shift 2 ;;
    --dtype) DTYPE="$2"; shift 2 ;;
    --max-num-batched-tokens) MAX_NUM_BATCHED_TOKENS="$2"; shift 2 ;;
    --max-num-seqs) MAX_NUM_SEQS="$2"; shift 2 ;;
    --gpu-memory-utilization) GPU_MEMORY_UTILIZATION="$2"; shift 2 ;;
    --max-model-len) MAX_MODEL_LEN="$2"; shift 2 ;;
    --speculative-config) SPECULATIVE_CONFIG="$2"; shift 2 ;;
    --compilation-config) COMPILATION_CONFIG="$2"; shift 2 ;;
    --extra-args) EXTRA_ARGS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "unknown_arg=$1" >&2; usage; exit 2 ;;
  esac
done

for var in ROLE SERVER_SCRIPT_REL NODE CONTAINER MODEL_NAME MODEL_SHORT CONTAINER_MODEL_PATH PORT TP WORK_DIR STATE VLLM_HOST_IP; do
  [[ -n "${!var}" ]] || { echo "missing_arg=$var" >&2; exit 2; }
done
[[ "$ROLE" == "prefill" || "$ROLE" == "decode" ]] || { echo "invalid_role=$ROLE" >&2; exit 2; }
[[ "$ROLE" != "prefill" || -n "$TRANSFER_PORT" ]] || { echo "missing_arg=TRANSFER_PORT" >&2; exit 2; }
[[ "$MOONCAKE_DEST_DEVICE_AFFINITY" == "0" || "$MOONCAKE_DEST_DEVICE_AFFINITY" == "1" ]] || { echo "invalid_mooncake_dest_device_affinity=$MOONCAKE_DEST_DEVICE_AFFINITY" >&2; exit 2; }
resolve_runtime_config

SERVER_SCRIPT="${SKILL_CONTAINER_ROOT%/}/${SERVER_SCRIPT_REL#./}"
KV_ROLE="kv_consumer"; [[ "$ROLE" == "prefill" ]] && KV_ROLE="kv_producer"
LOG="${WORK_DIR}/logs/${MODEL_SHORT}-${ROLE}-vllm-server.log"
PID="${WORK_DIR}/logs/${MODEL_SHORT}-${ROLE}-vllm-server.pid"

remote_script=$(cat <<EOF
set -euo pipefail
ROLE=$(quote_sh "$ROLE"); KV_ROLE=$(quote_sh "$KV_ROLE"); SERVER_SCRIPT=$(quote_sh "$SERVER_SCRIPT"); MODEL_PATH=$(quote_sh "$CONTAINER_MODEL_PATH")
MODEL_NAME=$(quote_sh "$MODEL_NAME"); MODEL_SHORT=$(quote_sh "$MODEL_SHORT"); HOST_MODEL_PATH=$(quote_sh "$HOST_MODEL_PATH")
PORT=$(quote_sh "$PORT"); TRANSFER_PORT=$(quote_sh "$TRANSFER_PORT"); TP=$(quote_sh "$TP"); GPU_RANGE=$(quote_sh "$GPU_RANGE")
WORK_DIR=$(quote_sh "$WORK_DIR"); STATE=$(quote_sh "$STATE"); LOG=$(quote_sh "$LOG"); PID=$(quote_sh "$PID")
VLLM_HOST_IP=$(quote_sh "$VLLM_HOST_IP"); NETWORK_IFNAME=$(quote_sh "$NETWORK_IFNAME"); NCCL_IB_HCA=$(quote_sh "$NCCL_IB_HCA")
MOONCAKE_DEST_DEVICE_AFFINITY=$(quote_sh "$MOONCAKE_DEST_DEVICE_AFFINITY")
QUANTIZATION=$(quote_sh "$QUANTIZATION"); DTYPE=$(quote_sh "$DTYPE"); MAX_NUM_BATCHED_TOKENS=$(quote_sh "$MAX_NUM_BATCHED_TOKENS")
MAX_NUM_SEQS=$(quote_sh "$MAX_NUM_SEQS"); GPU_MEMORY_UTILIZATION=$(quote_sh "$GPU_MEMORY_UTILIZATION"); MAX_MODEL_LEN=$(quote_sh "$MAX_MODEL_LEN")
SPECULATIVE_CONFIG=$(quote_sh "$SPECULATIVE_CONFIG"); COMPILATION_CONFIG=$(quote_sh "$COMPILATION_CONFIG"); EXTRA_ARGS=$(quote_sh "$EXTRA_ARGS")
SKILL_CONTAINER_ROOT=$(quote_sh "$SKILL_CONTAINER_ROOT")

mkdir -p "\$WORK_DIR/logs"
if [[ ! -f "\$SERVER_SCRIPT" ]]; then
  python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" --set "status=SERVICE_FAILED" --set "pd.roles.\$ROLE.status=FAILED" --set "failure.reason=server_script_missing" --set "failure.detail=\$SERVER_SCRIPT"
  echo "SERVER_SCRIPT_MISSING=\$SERVER_SCRIPT" >&2
  exit 1
fi
if [[ ! -d "\$MODEL_PATH" ]]; then
  python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" --set "status=SERVICE_FAILED" --set "pd.roles.\$ROLE.status=FAILED" --set "failure.reason=container_model_path_missing" --set "failure.detail=\$MODEL_PATH"
  echo "CONTAINER_MODEL_PATH_MISSING=\$MODEL_PATH" >&2
  exit 1
fi

rm -f "\$LOG" "\$PID"
START_TS=\$(date +%s)
python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" \
  --set "status=SERVICE_STARTING" --set "pd.roles.\$ROLE.status=SERVICE_STARTING" \
  --set "pd.roles.\$ROLE.node=$(printf '%s' "$NODE")" --set "pd.roles.\$ROLE.container=$(printf '%s' "$CONTAINER")" \
  --set "pd.roles.\$ROLE.port=\$PORT" --set "pd.roles.\$ROLE.kv_role=\$KV_ROLE" --set "pd.roles.\$ROLE.vllm_host_ip=\$VLLM_HOST_IP" \
  --set "pd.roles.\$ROLE.transfer_port=\$TRANSFER_PORT" --set "pd.roles.\$ROLE.network_ifname=\$NETWORK_IFNAME" \
  --set "pd.roles.\$ROLE.nccl_ib_hca=\$NCCL_IB_HCA" --set "pd.roles.\$ROLE.server_script=\$SERVER_SCRIPT" \
  --set "pd.roles.\$ROLE.mooncake_dest_device_affinity=\$MOONCAKE_DEST_DEVICE_AFFINITY" \
  --set "pd.roles.\$ROLE.log_file=\$LOG" --set "pd.roles.\$ROLE.pid_file=\$PID" \
  --set "model.name=\$MODEL_NAME" --set "model.model_short=\$MODEL_SHORT" \
  --set "model.host_model_path=\$HOST_MODEL_PATH" --set "model.container_model_path=\$MODEL_PATH"

cmd=(bash "\$SERVER_SCRIPT" --model-path "\$MODEL_PATH" --port "\$PORT" --vllm-host-ip "\$VLLM_HOST_IP" --gpu-range "\$GPU_RANGE" --tp "\$TP" --network-ifname "\$NETWORK_IFNAME" --nccl-ib-hca "\$NCCL_IB_HCA" --mooncake-dest-device-affinity "\$MOONCAKE_DEST_DEVICE_AFFINITY" --quantization "\$QUANTIZATION" --dtype "\$DTYPE" --max-num-batched-tokens "\$MAX_NUM_BATCHED_TOKENS" --max-num-seqs "\$MAX_NUM_SEQS" --gpu-memory-utilization "\$GPU_MEMORY_UTILIZATION" --max-model-len "\$MAX_MODEL_LEN" --speculative-config "\$SPECULATIVE_CONFIG" --compilation-config "\$COMPILATION_CONFIG" --extra-args "\$EXTRA_ARGS")
if [[ "\$ROLE" == "prefill" ]]; then cmd+=(--transfer-port "\$TRANSFER_PORT"); fi
nohup "\${cmd[@]}" > "\$LOG" 2>&1 &
echo \$! > "\$PID"
python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" --set "pd.roles.\$ROLE.status=SERVICE_STARTED" --set "pd.roles.\$ROLE.pid=\$(cat "\$PID")" --set "pd.roles.\$ROLE.startup_duration_seconds=\$((\$(date +%s) - START_TS))"
sleep 5
echo "ROLE=\$ROLE"; echo "LOG_CONTAINER=\$LOG"; echo "PID_CONTAINER=\$PID"
tail -120 "\$LOG" || true
EOF
)

run_in_container "$remote_script"
