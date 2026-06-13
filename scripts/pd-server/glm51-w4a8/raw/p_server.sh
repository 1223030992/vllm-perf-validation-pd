
export VLLM_USE_MODELSCOPE=1
export VLLM_HCU_USE_FLASHMLA=1
export LMSLIM_USE_GLOBAL_MOE_CACHE=1
export VLLM_ROCM_USE_AITER_MOE=1

export MC_ENABLE_DEST_DEVICE_AFFINITY=1
export VLLM_HOST_IP=13.13.1.1
export NCCL_IB_HCA=mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_8,mlx5_9
export NCCL_SOCKET_IFNAME=ens19f0
export GLOO_SOCKET_IFNAME=ens19f0

vllm serve /model2/llm-models/GLM-5.1-W4A8-V2_6 \
    --port 9351\
    --enforce-eager \
    --dtype bfloat16 \
    --max-num-batched-tokens 8192 \
    -tp 8 \
    --gpu-memory-utilization 0.92 \
    --max-num-seqs 64 \
    --block-size 64 \
    --speculative_config '{
        "method":"deepseek_mtp",
        "num_speculative_tokens":2}' \
    --kv-cache-dtype fp8_ds_mla \
    --kv-transfer-config '{"kv_connector":"MooncakeConnector","kv_role":"kv_producer"}'
