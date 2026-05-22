# MiniMax-M2.5-W8A8 service startup script
# Supported environment variables: MODEL_PATH, TP, GPU_RANGE, PORT, LOG_DIR

# Defaults
export GPU_RANGE=${GPU_RANGE:-0,1,2,3,4,5,6,7}
export TP_SIZE=${TP:-8}
export MODEL_PATH=${MODEL_PATH:-/model2/llm-models/MiniMax-M2.5-W8A8}
export PORT=${PORT:-9352}
export LOG_DIR=${LOG_DIR:-./logs}

model=${MODEL_PATH##*/}
date=$(date "+%m%d")
mkdir -p "${LOG_DIR}"

if [[ "${CLEAR_COMPILE_CACHE:-0}" == "1" ]]; then
    rm -rf "${HOME}/.cache" "${HOME}/.triton"
fi

export HIP_VISIBLE_DEVICES=${GPU_RANGE}
export NCCL_MIN_NCHANNELS=16
export NCCL_MAX_NCHANNELS=16
export ALLREDUCE_STREAM_WITH_COMPUTE=1
export HSA_FORCE_FINE_GRAIN_PCIE=1
export NCCL_P2P_LEVEL=SYS
export NCCL_LAUNCH_MODE=GROUP
export NCCL_NET_GDR_READ=1
export VLLM_RPC_TIMEOUT=1800000
export NCCL_NET_GDR_LEVEL=7
export NCCL_SDMA_COPY_ENABLE=0
export VLLM_USE_OPT_ZEROS=1
export VLLM_USE_PD_SPLIT=1
export VLLM_V1_USE_FUSED_QKV_SPLIT_RMS_ROPE_KVSTORE=1
export VLLM_USE_LIGHTOP=1
export LMSLIM_USE_LIGHTOP=1
export USE_FUSED_SILU_MUL_QUANT=1
export USE_FUSED_RMS_QUANT=1
export VLLM_USE_LIGHTOP_MOE_SUM_MUL_ADD=1
export VLLM_USE_LIGHTOP_MOE_ALIGN=1
export VLLM_USE_LIGHTOP_FILL_MOE_ALIGN=1
export VLLM_USE_OPT_RESHAPE_AND_CACHE=1
export VLLM_USE_GLOBAL_CACHE13=1
export VLLM_FUSED_MOE_CHUNK_SIZE=16384
export VLLM_USE_PIECEWISE=1
export VLLM_USE_LIGHTOP_FUSED_TOPP_TOPK=1
export VLLM_USE_OPT_OP=1
export VLLM_USE_AITER_MOE_W8A8=0

vllm serve "${MODEL_PATH}" \
    --host 0.0.0.0 \
    --port ${PORT} \
    -tp ${TP_SIZE} \
    --trust-remote-code \
    --gpu-memory-utilization 0.92 \
    --disable-log-requests \
    --max-model-len 73216 \
    --max-num-batched-tokens 16384 \
    -cc '{"pass_config": {"fuse_act_quant": false}, "cudagraph_mode": "full", "custom_ops": ["all"]}' \
    -q slimquant_marlin \
    --enable-prefix-caching \
    --disable-cascade-attn
