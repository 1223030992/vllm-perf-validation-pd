#!/usr/bin/env bash
set -euo pipefail

MODEL_PATH=/model2/llm-models/GLM-5.1-W4A8-V2_6; PORT=9351; TRANSFER_PORT=""; VLLM_HOST_IP=""; GPU_RANGE=0,1,2,3,4,5,6,7; TP=8
NETWORK_IFNAME=""; NCCL_IB_HCA=""; MOONCAKE_DEST_DEVICE_AFFINITY="1"
QUANTIZATION=''; DTYPE=bfloat16; MAX_NUM_BATCHED_TOKENS=8192
MAX_NUM_SEQS=64; GPU_MEMORY_UTILIZATION=0.92; MAX_MODEL_LEN=''
SPECULATIVE_CONFIG='{ "method":"deepseek_mtp", "num_speculative_tokens":2}'; COMPILATION_CONFIG=''; EXTRA_ARGS=""

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
    *) echo "unknown_arg=$1" >&2; exit 2 ;;
  esac
done

for var in MODEL_PATH PORT VLLM_HOST_IP GPU_RANGE TP TRANSFER_PORT; do
  [[ -n "${!var}" ]] || { echo "missing_arg=$var" >&2; exit 2; }
done
export HIP_VISIBLE_DEVICES="$GPU_RANGE"
export VLLM_HOST_IP
export VLLM_MOONCAKE_BOOTSTRAP_PORT="$TRANSFER_PORT"
export MC_ENABLE_DEST_DEVICE_AFFINITY="$MOONCAKE_DEST_DEVICE_AFFINITY"
[[ -z "$NETWORK_IFNAME" ]] || { export NCCL_SOCKET_IFNAME="$NETWORK_IFNAME"; export GLOO_SOCKET_IFNAME="$NETWORK_IFNAME"; }
[[ -z "$NCCL_IB_HCA" ]] || export NCCL_IB_HCA
export VLLM_USE_MODELSCOPE=1
export VLLM_HCU_USE_FLASHMLA=1
export LMSLIM_USE_GLOBAL_MOE_CACHE=1
export VLLM_ROCM_USE_AITER_MOE=1

cmd=(vllm serve "$MODEL_PATH" --kv-transfer-config '{"kv_connector":"MooncakeConnector","kv_role":"kv_producer"}'
  --enforce-eager
  -tp "$TP" --port "$PORT" --dtype "$DTYPE")
[[ -z "$QUANTIZATION" ]] || cmd+=(-q "$QUANTIZATION")
[[ -z "$MAX_NUM_BATCHED_TOKENS" ]] || cmd+=(--max_num_batched_tokens "$MAX_NUM_BATCHED_TOKENS")
[[ -z "$MAX_NUM_SEQS" ]] || cmd+=(--max-num-seqs "$MAX_NUM_SEQS")
[[ -z "$GPU_MEMORY_UTILIZATION" ]] || cmd+=(--gpu-memory-utilization "$GPU_MEMORY_UTILIZATION")
[[ -z "$MAX_MODEL_LEN" ]] || cmd+=(--max-model-len "$MAX_MODEL_LEN")
[[ -z "$SPECULATIVE_CONFIG" ]] || cmd+=(--speculative_config "$SPECULATIVE_CONFIG")
[[ -z "$COMPILATION_CONFIG" ]] || cmd+=(--compilation-config "$COMPILATION_CONFIG")
cmd+=(--block-size 64 --kv-cache-dtype fp8_ds_mla)
if [[ -n "$EXTRA_ARGS" ]]; then read -r -a extra_argv <<< "$EXTRA_ARGS"; cmd+=("${extra_argv[@]}"); fi
exec "${cmd[@]}"
