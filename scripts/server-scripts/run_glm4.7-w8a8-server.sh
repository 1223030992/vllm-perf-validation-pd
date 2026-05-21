# GLM-4.7-W8A8 服务启动脚本
# 支持环境变量: MODEL_PATH, TP, GPU_RANGE, PORT, LOG_DIR

# 默认值
export GPU_RANGE=${GPU_RANGE:-0,1,2,3,4,5,6,7}
export TP_SIZE=${TP:-8}
export MODEL_PATH=${MODEL_PATH:-/model/GLM-4.7-W8A8}
export PORT=${PORT:-9348}
export LOG_DIR=${LOG_DIR:-./logs}

model=${MODEL_PATH##*/}
date=$(date "+%m%d")
mkdir -p "${LOG_DIR}"

export VLLM_TORCH_PROFILER_DIR=./prof-0310
export HIP_VISIBLE_DEVICES=${GPU_RANGE}
export NCCL_MIN_NCHANNELS=16
export NCCL_MAX_NCHANNELS=16
export NCCL_P2P_NVL_CHUNKSIZE=131072
export VLLM_RPC_TIMEOUT=1800000
export VLLM_NUMA_BIND=1
export VLLM_RANK0_NUMA=0
export VLLM_RANK1_NUMA=0
export VLLM_RANK2_NUMA=0
export VLLM_RANK3_NUMA=0
export VLLM_RANK4_NUMA=1
export VLLM_RANK5_NUMA=1
export VLLM_RANK6_NUMA=1
export VLLM_RANK7_NUMA=1
export VLLM_USE_GLOBAL_CACHE13=1
export VLLM_FUSED_MOE_CHUNK_SIZE=8192
export VLLM_ZERO_OVERHEAD=1
export VLLM_USE_PD_SPLIT=1
export HIP_USE_GRAPH_QUEUE_POOL=1
export VLLM_USE_LIGHTOP=1
export VLLM_USE_PIECEWISE=1

export SENDRECV_STREAM_WITH_COMPUTE=1
export ALLREDUCE_STREAM_WITH_COMPUTE=1
export GATHER_STREAM_WITH_COMPUTE=1
export Allgather_Base_STREAM_WITH_COMPUTE=1

export USE_FUSED_SILU_MUL_QUANT=1
export USE_FUSED_RMS_QUANT=1
export VLLM_V1_USE_FUSED_QKV_SPLIT_RMS_ROPE_KVSTORE=1

export VLLM_USE_AITER_MOE_W8A8=0
export VLLM_REJECT_SAMPLE_OPT=0

vllm serve "${MODEL_PATH}" \
    --disable-cascade-attn \
    --host 0.0.0.0 \
    --port ${PORT} \
    -q slimquant_marlin \
    --trust-remote-code \
    --disable-log-requests \
    -tp ${TP_SIZE} \
    --max-num-seqs 256 \
    --max-model-len 40960 \
    --gpu-memory-utilization 0.9 \
    --max_num_batched_tokens 40960 \
    --enable-chunked-prefill \
    --enable-prefix-caching \
    --dtype bfloat16 \
    -cc '{"inductor_compile_config":{"combo_kernels": false}}' \
    --speculative_config '{"method": "mtp", "num_speculative_tokens": 2, "quantization": "slimquant_marlin"}'