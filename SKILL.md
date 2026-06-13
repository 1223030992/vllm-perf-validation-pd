---
name: vllm-perf-validation-pd
description: 在 DCU 环境通过受控入口执行 vLLM 0.18.1 + Mooncake 1P1D PD 起服、custom/pchit 性能测试、报告、失败保留和清理；也可从已验证的 P/D 起服脚本一键接入新模型。
---

# vllm-perf-validation-pd

## 正式测试规则

- 正式流程只调用一次 `scripts/ops/run_pd_task.sh`。
- 用户要求真实运行时，不自动先执行 dry-run。
- 不执行 `ls`、`cat`、`--help`、额外报告扫描或自行推导配置。
- 不手写 SSH、Docker、`vllm serve`、Proxy、benchmark、curl、pip install 或 stop 命令。
- 不追加 `tail`、`tee`、管道、`2>&1`、`&` 或外部 timeout。
- 执行环境转为后台任务时，只等待原任务，不重复启动。
- 真实运行必须显式传入 `--image`、`--user` 和 `--abbr`；`abbr` 是姓名缩写。
- 使用 `--profile`、`--deployment`、`--test-preset` 分层调用。旧 `--config` 只用于兼容。
- 用户提供完整命令块时，该命令块是唯一授权命令，必须原样执行，不得增加、删除或重命名参数。
- profile、deployment 和 test preset 已提供时，文字中的节点、IP、端口、模型与测试信息只用于验收，不得转换为 CLI 覆盖参数。
- 用户要求临时覆盖节点、IP、端口或服务参数时，覆盖项必须已出现在唯一授权命令块中；只出现在验收说明中的值不得视为生效配置。
- 主入口在 SSH 前输出的 `EFFECTIVE_CONFIG_READY=1` 到 `EFFECTIVE_CONFIG_END=1` 是最终配置依据；dry-run 与真实运行按同一规则核对。
- 镜像未预装 Mooncake 时，只通过 `--mooncake-wheel` 受控安装。
- `--max-model-len` 和 `--gpu-memory-utilization` 是受控服务覆盖参数；不得用未定义别名替代。
- 成功以主入口摘要和 `PD_TASK_DONE=1` 为准，不再调用 `show_state.sh`。
- 参数解析失败也算本次调用。出现 `PD_INVOCATION_REJECTED=1` 时立即停止，不得根据 usage 修正后重试。
- 只有运行期失败且主入口输出 `STATE_HOST` 时，才调用一次 `show_state.sh --state <STATE_HOST>`；没有 `STATE_HOST` 时不得调用。
- 保留容器只通过 `--cleanup-state` 清理。

## Dry-run

仅在用户明确要求时传 `--dry-run --image-prefix TEST`。默认使用简洁 dry-run；只有开发排查才传 `--verbose-dry-run`。不得执行任何补充 SSH、Docker、curl 或 API 探测。

`--image-prefix TEST` 仅属于 `run_pd_task.sh` 的测试 dry-run，不得传给 `onboard_pd_model.sh`。

## 状态语义

- `execution_status` 表示编排是否完整执行。
- `benchmark_status` 表示请求是否完成。
- `sla_status` 表示 SLA 达标情况。
- pchit 请求零失败但部分并发不满足 SLA 时，execution/benchmark 为 `PASS`，SLA 为 `PARTIAL`。

## 新模型接入

新模型只使用 `scripts/ops/onboard_pd_model.sh`。先 `--dry-run`，确认后正式生成；不得连接远端节点。Host 模型目录属于用户部署环境，优先通过 `configure_pd_deployment.sh --host-model-path` 保存，不要直接编辑共享 profile。现有 standardize/register 工具是内部低级入口，不作为用户主流程。

当前只支持 `mooncake_vllm018 + 1p1d`。不要实现或模拟 xpyd。
