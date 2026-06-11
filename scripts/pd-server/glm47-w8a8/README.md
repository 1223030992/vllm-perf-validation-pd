# GLM-4.7-W8A8 PD Server

本目录用于存放 GLM-4.7-W8A8 在 `vLLM 0.18.1 + Mooncake + 1P1D PD` 场景下的起服脚本。

当前目录只保留占位文件。后续可放入：

- 原始实测起服脚本
- 参数化后的 prefill/decode/proxy 脚本
- 标准化说明或对比记录

脚本约定：

- 不复用旧 `scripts/server-scripts/` 的 vLLM015 single 起服方式。
- 默认不加入 `--profiler-config`。
- prefill 使用 `kv_role=kv_producer` 和 transfer port。
- decode 使用 `kv_role=kv_consumer`。
- 节点、服务 IP、`VLLM_HOST_IP`、端口、网卡和 HCA 应由上层配置或参数传入。
