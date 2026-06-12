#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  p_server.sh --model-path PATH --port PORT --transfer-port PORT \
    --vllm-host-ip IP --gpu-range RANGE --tp TP \
    [--network-ifname IFNAME] [--nccl-ib-hca HCA] \
    [--mooncake-dest-device-affinity 0|1] \
    [--quantization NAME] [--dtype DTYPE] \
    [--max-num-batched-tokens N] [--max-num-seqs N] \
    [--gpu-memory-utilization VALUE] [--max-model-len N] \
    [--speculative-config JSON] [--compilation-config JSON] \
    [--extra-args "ARGS"]
USAGE
}

MODEL_PATH=""; PORT=""; TRANSFER_PORT=""; VLLM_HOST_IP=""; GPU_RANGE=""; TP=""
NETWORK_IFNAME=""; NCCL_IB_HCA=""; QUANTIZATION="slimquant_marlin"; DTYPE="bfloat16"
MOONCAKE_DEST_DEVICE_AFFINITY="1"
MAX_NUM_BATCHED_TOKENS="16384"; MAX_NUM_SEQS=""; GPU_MEMORY_UTILIZATION=""; MAX_MODEL_LEN=""
SPECULATIVE_CONFIG='{"method": "mtp", "num_speculative_tokens": 2, "quantization": "slimquant_marlin"}'
COMPILATION_CONFIG='{"cudagraph_mode": "PIECEWISE"}'
EXTRA_ARGS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model-path) MODEL_PATH="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --transfer-port) TRANSFER_PORT="$2"; shift 2 ;;
    --vllm-host-ip) VLLM_HOST_IP="$2"; shift 2 ;;
    --gpu-range) GPU_RANGE="$2"; shift 2 ;;
    --tp) TP="$2"; shift 2 ;;
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
    --help) usage; exit 0 ;;
    *) echo "unknown_arg=$1" >&2; usage; exit 2 ;;
  esac
done

[[ "$MOONCAKE_DEST_DEVICE_AFFINITY" == "0" || "$MOONCAKE_DEST_DEVICE_AFFINITY" == "1" ]] || {
  echo "invalid_mooncake_dest_device_affinity=$MOONCAKE_DEST_DEVICE_AFFINITY" >&2
  exit 2
}

for var in MODEL_PATH PORT TRANSFER_PORT VLLM_HOST_IP GPU_RANGE TP; do
  [[ -n "${!var}" ]] || { echo "missing_arg=$var" >&2; exit 2; }
done

export HIP_VISIBLE_DEVICES="$GPU_RANGE"
export VLLM_HOST_IP
export VLLM_MOONCAKE_BOOTSTRAP_PORT="$TRANSFER_PORT"
export VLLM_USE_MODELSCOPE=1
export VLLM_HCU_USE_CUSTOM_FLASH_ATTN=1
export MC_ENABLE_DEST_DEVICE_AFFINITY="$MOONCAKE_DEST_DEVICE_AFFINITY"
if [[ -n "$NETWORK_IFNAME" ]]; then
  export NCCL_SOCKET_IFNAME="$NETWORK_IFNAME"
  export GLOO_SOCKET_IFNAME="$NETWORK_IFNAME"
fi
if [[ -n "$NCCL_IB_HCA" ]]; then
  export NCCL_IB_HCA
fi

cmd=(
  vllm serve "$MODEL_PATH"
  --kv-transfer-config '{"kv_connector":"MooncakeConnector","kv_role":"kv_producer"}'
  --enforce-eager
  -tp "$TP"
  -q "$QUANTIZATION"
  --disable-cascade-attn
  --port "$PORT"
  --speculative_config "$SPECULATIVE_CONFIG"
  --dtype "$DTYPE"
  --compilation-config "$COMPILATION_CONFIG"
  --max_num_batched_tokens "$MAX_NUM_BATCHED_TOKENS"
)
[[ -n "$MAX_NUM_SEQS" ]] && cmd+=(--max-num-seqs "$MAX_NUM_SEQS")
[[ -n "$GPU_MEMORY_UTILIZATION" ]] && cmd+=(--gpu-memory-utilization "$GPU_MEMORY_UTILIZATION")
[[ -n "$MAX_MODEL_LEN" ]] && cmd+=(--max-model-len "$MAX_MODEL_LEN")
if [[ -n "$EXTRA_ARGS" ]]; then
  read -r -a extra_argv <<< "$EXTRA_ARGS"
  cmd+=("${extra_argv[@]}")
fi

exec "${cmd[@]}"
