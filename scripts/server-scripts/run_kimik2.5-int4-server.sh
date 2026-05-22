# Kimi-K2.5-INT4 service startup script
# Supported environment variables: MODEL_PATH, TP, GPU_RANGE, PORT, LOG_DIR

# Defaults
export GPU_RANGE=${GPU_RANGE:-0,1,2,3,4,5,6,7}
export TP_SIZE=${TP:-8}
export MODEL_PATH=${MODEL_PATH:-/model/Kimi-K2.5}
export PORT=${PORT:-9354}
export LOG_DIR=${LOG_DIR:-./logs}

model=${MODEL_PATH##*/}
date=$(date "+%m%d")
mkdir -p "${LOG_DIR}"

if [[ "${CLEAR_COMPILE_CACHE:-0}" == "1" ]]; then
    rm -rf "${HOME}/.cache" "${HOME}/.triton"
fi

export HIP_VISIBLE_DEVICES=${GPU_RANGE}
export VLLM_USE_MODELSCOPE=1
export VLLM_USE_LIGHTOP=1
export VLLM_USE_PIECEWISE=1
export VLLM_1D_MROPE=1
export USE_FUSED_RMS_QUANT=0
export VLLM_USE_LIGHTOP_FUSED_TOPP_TOPK=1
export VLLM_W8A8_BACKEND=3
export VLLM_USE_FLASH_ATTN_FP8=1
export VLLM_USE_CAT_MLA=1
export VLLM_USE_LIGHTOP_RMS_ROPE_CONCAT=0
export VLLM_ROCM_USE_AITER_MOE=1

vllm serve "${MODEL_PATH}" \
    --host 0.0.0.0 \
    --port ${PORT} \
    -tp ${TP_SIZE} \
    --trust-remote-code   \
    --dtype bfloat16  \
    --max-model-len 65536  \
    --disable-log-requests  \
    --enable-prefix-caching \
    --gpu-memory-utilization 0.90 \
    --max-num-batched-tokens 16384 \
    --kv-cache-dtype fp8_e4m3
