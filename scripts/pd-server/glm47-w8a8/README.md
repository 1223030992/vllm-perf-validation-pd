# GLM-4.7-W8A8 PD Server

本目录保存 `GLM-4.7-W8A8 + vLLM 0.18.1 + Mooncake + 1P1D` 的模型专用 P/D/Proxy 脚本。

这些脚本由 `scripts/ops/run_pd_task.sh` 统一调用，不作为用户直接入口。模型路径、GPU、TP、quantization、dtype、服务 IP、端口、网卡和 HCA 均由上层参数注入，默认不启用 profiler。

| 文件 | 角色 |
|---|---|
| `p_server.sh` | Prefill `kv_producer`，设置 bootstrap transfer port |
| `d_server.sh` | Decode `kv_consumer` |
| `run_proxy.sh` | 参数化 Mooncake proxy |

已验证案例和当前版本状态见仓库根目录 README 与 `references/verified-runs.md`。
