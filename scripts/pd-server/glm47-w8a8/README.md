# GLM-4.7-W8A8 PD Server

> 本目录下的脚本是 `vLLM 0.18.1 + Mooncake + 1P1D PD` 场景下 GLM-4.7-W8A8 的模型专用 P/D/proxy 入口，统一由 `scripts/ops/run_pd_task.sh` 编排，**不要直接调用**。节点、服务 IP、`VLLM_HOST_IP`、端口、网卡和 HCA 全部由上层 `run_pd_task.sh` 通过参数注入。

## 脚本清单

| 脚本 | 角色 | 关键 vLLM / Mooncake 参数 |
|---|---|---|
| `p_server.sh` | Prefill（`kv_producer`） | `--kv-role kv_producer` + transfer port；导出 `VLLM_MOONCAKE_BOOTSTRAP_PORT=$TRANSFER_PORT` |
| `d_server.sh` | Decode（`kv_consumer`） | `--kv-role kv_consumer`；无 transfer port 导出 |
| `run_proxy.sh` | Mooncake proxy | `python3 -u mooncake_connector_proxy.py --prefill <PREFILL_URL> <PREFILL_TRANSFER_PORT> --decode <DECODE_URL> --port <PORT>` |

## 约定

- 不复用旧 `scripts/server-scripts/` 的 vLLM015 single 起服方式。
- 默认不加入 `--profiler-config`。
- Prefill 使用 `kv_role=kv_producer` 并开启 transfer port；Decode 使用 `kv_role=kv_consumer`。
- 节点、服务 IP、`VLLM_HOST_IP`、端口、网卡、HCA 全部由上层 `run_pd_task.sh` 注入；脚本里不写死。
- 节点 / 网络 / 端口字段在 example YAML 里硬编码时要被 CLI flag 覆盖，否则会触发 SSH 预检失败并被误归类为镜像问题（参见根 README §9.6 的复盘）。
- 正常流程不要直接调用这些脚本；统一通过 `scripts/ops/run_pd_task.sh` 编排。

## 最近一次验证

- **日期**：2026-06-12
- **case**：32k / 1k / conc=4 custom smoke（CSV `PASS`，`failed=0`）
- **PD_SCRIPT_VERSION**：`2026.06.12-rdma-watchdog-v5`
- 详细指标（TTFT / TPOT / ITL 分位、吞吐、ready 时长等）见根 README §8。
