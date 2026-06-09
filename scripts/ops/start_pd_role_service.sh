#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  start_pd_role_service.sh --role prefill|decode --node NODE --container NAME \
    --model-name NAME --model-short SHORT --container-model-path PATH --host-model-path PATH \
    --port PORT --tp TP --gpu-range RANGE --work-dir WORK_DIR --state STATE \
    [--vllm-host-ip IP] [--network-ifname IFNAME] [--nccl-ib-hca HCA] [--dry-run]
USAGE
}
quote_sh() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
run_in_container() {
  local script="$1" docker_cmd
  docker_cmd="docker exec -i -w $(quote_sh "$SKILL_CONTAINER_ROOT") $(quote_sh "$CONTAINER") bash -ic 'tmp=/tmp/vllm_pd_role_\$\$.sh; cat > \"\$tmp\"; bash \"\$tmp\"; rc=\$?; rm -f \"\$tmp\"; exit \$rc'"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "即将在容器内启动 PD ${ROLE} 服务:"
    printf 'ssh %q %q\n' "$NODE" "$docker_cmd"
    echo "--- container script ---"
    printf '%s\n' "$script"
  else
    printf '%s\n' "$script" | ssh "$NODE" "$docker_cmd"
  fi
}
ROLE=""; NODE=""; CONTAINER=""; MODEL_NAME=""; MODEL_SHORT=""; CONTAINER_MODEL_PATH=""; HOST_MODEL_PATH=""
PORT=""; TP=""; GPU_RANGE="0,1,2,3,4,5,6,7"; WORK_DIR=""; STATE=""; VLLM_HOST_IP=""; NETWORK_IFNAME=""; NCCL_IB_HCA=""
QUANTIZATION="slimquant_marlin"; DTYPE="bfloat16"; MAX_NUM_BATCHED_TOKENS="16384"; MAX_NUM_SEQS="256"; GPU_MEMORY_UTILIZATION="0.9"; MAX_MODEL_LEN="40960"
SPECULATIVE_CONFIG='{"method": "mtp", "num_speculative_tokens": 2, "quantization": "slimquant_marlin"}'
COMPILATION_CONFIG='{"cudagraph_mode": "PIECEWISE"}'
DRY_RUN=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime_config.sh"
SKILL_USER=""; USER_ABBR=""; HOME_ROOT=""; HOST_HOME_ROOT=""; SKILL_HOST_ROOT=""; OUTPUT_HOST_ROOT="${OUTPUT_HOST_ROOT:-}"; OUTPUT_CONTAINER_ROOT="${OUTPUT_CONTAINER_ROOT:-}"; CONTAINER_PREFIX=""
while [[ $# -gt 0 ]]; do
  if runtime_config_parse_common_arg "$1" "${2-}"; then shift 2; continue; fi
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --node) NODE="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --model-name) MODEL_NAME="$2"; shift 2 ;;
    --model-short) MODEL_SHORT="$2"; shift 2 ;;
    --container-model-path) CONTAINER_MODEL_PATH="$2"; shift 2 ;;
    --host-model-path) HOST_MODEL_PATH="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --tp) TP="$2"; shift 2 ;;
    --gpu-range) GPU_RANGE="$2"; shift 2 ;;
    --work-dir) WORK_DIR="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --vllm-host-ip) VLLM_HOST_IP="$2"; shift 2 ;;
    --network-ifname) NETWORK_IFNAME="$2"; shift 2 ;;
    --nccl-ib-hca) NCCL_IB_HCA="$2"; shift 2 ;;
    --quantization) QUANTIZATION="$2"; shift 2 ;;
    --dtype) DTYPE="$2"; shift 2 ;;
    --max-num-batched-tokens) MAX_NUM_BATCHED_TOKENS="$2"; shift 2 ;;
    --max-num-seqs) MAX_NUM_SEQS="$2"; shift 2 ;;
    --gpu-memory-utilization) GPU_MEMORY_UTILIZATION="$2"; shift 2 ;;
    --max-model-len) MAX_MODEL_LEN="$2"; shift 2 ;;
    --speculative-config) SPECULATIVE_CONFIG="$2"; shift 2 ;;
    --compilation-config) COMPILATION_CONFIG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
for var in ROLE NODE CONTAINER MODEL_NAME MODEL_SHORT CONTAINER_MODEL_PATH PORT TP WORK_DIR STATE; do
  [[ -n "${!var}" ]] || { echo "missing argument: $var" >&2; exit 2; }
done
[[ "$ROLE" == "prefill" || "$ROLE" == "decode" ]] || { echo "--role must be prefill or decode" >&2; exit 2; }
resolve_runtime_config
KV_ROLE="kv_consumer"; ENFORCE_EAGER=0
if [[ "$ROLE" == "prefill" ]]; then KV_ROLE="kv_producer"; ENFORCE_EAGER=1; fi
LOG="${WORK_DIR}/logs/${MODEL_SHORT}-${ROLE}-vllm-server.log"
PID="${WORK_DIR}/logs/${MODEL_SHORT}-${ROLE}-vllm-server.pid"
remote_script=$(cat <<EOF
set -euo pipefail
ROLE=$(quote_sh "$ROLE"); KV_ROLE=$(quote_sh "$KV_ROLE"); MODEL_PATH=$(quote_sh "$CONTAINER_MODEL_PATH")
MODEL_NAME=$(quote_sh "$MODEL_NAME"); MODEL_SHORT=$(quote_sh "$MODEL_SHORT"); HOST_MODEL_PATH=$(quote_sh "$HOST_MODEL_PATH")
PORT=$(quote_sh "$PORT"); TP=$(quote_sh "$TP"); GPU_RANGE=$(quote_sh "$GPU_RANGE"); WORK_DIR=$(quote_sh "$WORK_DIR"); STATE=$(quote_sh "$STATE")
LOG=$(quote_sh "$LOG"); PID=$(quote_sh "$PID"); VLLM_HOST_IP=$(quote_sh "$VLLM_HOST_IP"); NETWORK_IFNAME=$(quote_sh "$NETWORK_IFNAME"); NCCL_IB_HCA=$(quote_sh "$NCCL_IB_HCA")
QUANTIZATION=$(quote_sh "$QUANTIZATION"); DTYPE=$(quote_sh "$DTYPE"); MAX_NUM_BATCHED_TOKENS=$(quote_sh "$MAX_NUM_BATCHED_TOKENS"); MAX_NUM_SEQS=$(quote_sh "$MAX_NUM_SEQS")
GPU_MEMORY_UTILIZATION=$(quote_sh "$GPU_MEMORY_UTILIZATION"); MAX_MODEL_LEN=$(quote_sh "$MAX_MODEL_LEN"); SPECULATIVE_CONFIG=$(quote_sh "$SPECULATIVE_CONFIG"); COMPILATION_CONFIG=$(quote_sh "$COMPILATION_CONFIG")
ENFORCE_EAGER=$(quote_sh "$ENFORCE_EAGER"); SKILL_CONTAINER_ROOT=$(quote_sh "$SKILL_CONTAINER_ROOT")
mkdir -p "\$WORK_DIR/logs"; rm -f "\$LOG" "\$PID"; START_TS=\$(date +%s)
python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" \
  --set "pd.roles.\$ROLE.status=SERVICE_STARTING" --set "pd.roles.\$ROLE.node=$(printf '%s' "$NODE")" --set "pd.roles.\$ROLE.container=$(printf '%s' "$CONTAINER")" \
  --set "pd.roles.\$ROLE.port=\$PORT" --set "pd.roles.\$ROLE.kv_role=\$KV_ROLE" --set "pd.roles.\$ROLE.vllm_host_ip=\$VLLM_HOST_IP" \
  --set "pd.roles.\$ROLE.network_ifname=\$NETWORK_IFNAME" --set "pd.roles.\$ROLE.nccl_ib_hca=\$NCCL_IB_HCA" --set "pd.roles.\$ROLE.log_file=\$LOG" --set "pd.roles.\$ROLE.pid_file=\$PID" \
  --set "model.name=\$MODEL_NAME" --set "model.model_short=\$MODEL_SHORT" --set "model.host_model_path=\$HOST_MODEL_PATH" --set "model.container_model_path=\$MODEL_PATH" \
  --set "paths.work_dir=\$WORK_DIR" --set "paths.work_dir_container=\$WORK_DIR" --set "paths.state_file=\$STATE" --set "paths.state_file_container=\$STATE"
export KV_ROLE="\$KV_ROLE"
export VLLM_TORCH_PROFILER_DIR=./prof-0509
export HIP_VISIBLE_DEVICES="\$GPU_RANGE"
export NCCL_MIN_NCHANNELS=16
export NCCL_MAX_NCHANNELS=16
export NCCL_P2P_NVL_CHUNKSIZE=131072
export VLLM_RPC_TIMEOUT=1800000
export VLLM_USE_AITER_MOE_W8A8=0
export MC_ENABLE_DEST_DEVICE_AFFINITY=1
export VLLM_HCU_USE_FUSED_RMS_QUANT=1
export VLLM_HCU_USE_FUSED_SILU_MUL_QUANT=1
export VLLM_HCU_USE_FUSED_QKV_SPLIT_RMS_ROPE_KVSTORE=1
export VLLM_HCU_USE_CUSTOM_FLASH_ATTN=1
export VLLM_HOST_IP="\$VLLM_HOST_IP"
export NCCL_IB_HCA="\$NCCL_IB_HCA"
export NCCL_SOCKET_IFNAME="\$NETWORK_IFNAME"
export GLOO_SOCKET_IFNAME="\$NETWORK_IFNAME"
KV_TRANSFER_CONFIG=\$(python3 - <<PY
import json, os
print(json.dumps({"kv_connector": "MooncakeConnector", "kv_role": os.environ["KV_ROLE"]}))
PY
)
cmd=(vllm serve "\$MODEL_PATH" --kv-transfer-config "\$KV_TRANSFER_CONFIG" -tp "\$TP" -q "\$QUANTIZATION" --disable-cascade-attn --port "\$PORT" --dtype "\$DTYPE" --speculative_config "\$SPECULATIVE_CONFIG" --compilation-config "\$COMPILATION_CONFIG" --max_num_batched_tokens "\$MAX_NUM_BATCHED_TOKENS" --max-num-seqs "\$MAX_NUM_SEQS" --max-model-len "\$MAX_MODEL_LEN" --gpu-memory-utilization "\$GPU_MEMORY_UTILIZATION" --trust-remote-code --disable-log-requests)
if [[ "\$ENFORCE_EAGER" == "1" ]]; then cmd+=(--enforce-eager); fi
nohup "\${cmd[@]}" > "\$LOG" 2>&1 &
echo \$! > "\$PID"
python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" --set "pd.roles.\$ROLE.status=SERVICE_STARTED" --set "pd.roles.\$ROLE.pid=\$(cat "\$PID")" --set "pd.roles.\$ROLE.startup_duration_seconds=\$((\$(date +%s) - START_TS))"
sleep 5
echo "ROLE=\$ROLE"; echo "LOG_CONTAINER=\$LOG"; echo "PID_CONTAINER=\$PID"; echo "STATE_CONTAINER=\$STATE"; echo "WORK_DIR_CONTAINER=\$WORK_DIR"
tail -120 "\$LOG" || true
EOF
)
run_in_container "$remote_script"
