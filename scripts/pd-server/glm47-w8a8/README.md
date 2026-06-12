# GLM-4.7-W8A8 PD Server

本目录用于存放 GLM-4.7-W8A8 在 `vLLM 0.18.1 + Mooncake + 1P1D PD` 场景下的起服脚本。

当前目录包含 GLM-4.7-W8A8 的正式模型专用入口：

- `p_server.sh`：Prefill `kv_producer`
- `d_server.sh`：Decode `kv_consumer`
- `run_proxy.sh`：Mooncake proxy

脚本约定：

- 不复用旧 `scripts/server-scripts/` 的 vLLM015 single 起服方式。
- 默认不加入 `--profiler-config`。
- prefill 使用 `kv_role=kv_producer` 和 transfer port。
- decode 使用 `kv_role=kv_consumer`。
- 节点、服务 IP、`VLLM_HOST_IP`、端口、网卡和 HCA 应由上层配置或参数传入。
- 正常流程不要直接调用这些脚本；统一通过 `scripts/ops/run_pd_task.sh` 编排。
