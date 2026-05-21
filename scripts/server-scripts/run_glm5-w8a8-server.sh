# GLM-5-W8A8 服务启动脚本
# 支持环境变量: MODEL_PATH, TP, GPU_RANGE, PORT, LOG_DIR

export GPU_RANGE=${GPU_RANGE:-0,1,2,3,4,5,6,7}
export TP_SIZE=${TP:-8}
export MODEL_PATH=${MODEL_PATH:-/model/vllm-w8a8-models/GLM-5-W8A8}
export PORT=${PORT:-9349}
export LOG_DIR=${LOG_DIR:-./logs}

model=${MODEL_PATH##*/}
date=$(date "+%m%d")
mkdir -p "${LOG_DIR}"

export VLLM_USE_MODELSCOPE=1
export HIP_VISIBLE_DEVICES=${GPU_RANGE}
export ALLREDUCE_STREAM_WITH_COMPUTE=1
export NCCL_MIN_NCHANNELS=16
export NCCL_MAX_NCHANNELS=16
export Allgather_Base_STREAM_WITH_COMPUTE=1
export SENDRECV_STREAM_WITH_COMPUTE=1
export HIP_KERNEL_EVENT_SYSTENFENCE=1
export VLLM_RPC_TIMEOUT=1800000
export VLLM_REJECT_SAMPLE_OPT=0

export USE_FUSED_RMS_QUANT=1
export USE_FUSED_SILU_MUL_QUANT=1

export VLLM_USE_GLOBAL_CACHE13=1
export VLLM_FUSED_MOE_CHUNK_SIZE=16384
export VLLM_CUSTOM_CACHE=1
export VLLM_USE_OPT_CAT=1
export VLLM_USE_FUSED_FILL_RMS_CAT=1
export VLLM_USE_LIGHTOP_MOE_SUM_MUL_ADD=1
export VLLM_USE_LIGHTOP_RMS_ROPE_CONCAT=0
export VLLM_USE_V32_ENCODE=1
export USE_LIGHTOP_TOPK=1
export USE_LIGHTOP_PER_TOKEN_GROUP_QUANT_FP8=1
export USE_LIGHTOP_CONVERT_REQ_INDEX_TO_GLOBAL_INDEX=1

vllm serve "${MODEL_PATH}" \
    -q slimquant_marlin \
    --host 0.0.0.0 \
    --port "${PORT}" \
    --trust-remote-code \
    --dtype bfloat16 \
    -tp "${TP_SIZE}" \
    --max-model-len 72000 \
    --gpu-memory-utilization 0.92 \
    --disable-log-requests \
    --enable-chunked-prefill \
    --max-num-batched-tokens 16384 \
    --enable-prefix-caching \
    --kv-cache-dtype fp8_ds_mla \
    -cc '{"pass_config": {"fuse_act_quant": false}}' \
    --speculative_config '{"method": "mtp", "num_speculative_tokens": 2, "quantization": "slimquant_marlin"}'
