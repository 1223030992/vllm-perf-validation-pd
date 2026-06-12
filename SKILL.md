---
name: vllm-perf-validation-pd
description: 在 DCU 环境通过受控脚本执行 vLLM 0.18.1 + Mooncake 1P1D PD 分离的 dry-run、起服、性能测试、诊断、报告、失败保留和清理，并支持本地标准化与注册新模型。用于用户要求验证 GLM-4.7-W8A8 或其他 Mooncake PD 模型、分析 state/report、执行 custom/pchit，或接入新模型脚本时。
---

# vllm-perf-validation-pd

## 正式测试

- 只直接调用一次 `scripts/ops/run_pd_task.sh`。
- 用户要求真实运行时，不要自动先执行 dry-run。
- 不执行 `ls`、`cat`、`--help`、额外文档读取或报告扫描。
- 不手写 SSH、Docker、`vllm serve`、Proxy、benchmark、curl、pip install 或 stop 命令。
- 不追加 `tail`、`tee`、`2>&1`、`&` 或外部 `timeout`。
- 执行环境转为后台任务时，只等待原任务，不重复启动。
- 要求显式传入 `--image`、`--user` 和 `--abbr`；`abbr` 必须是用户姓名缩写。
- 镜像未预装 Mooncake 时，只通过 `--mooncake-wheel` 受控安装。
- 成功以主入口自动摘要和 `PD_TASK_DONE=1` 为准，不再调用 `show_state.sh`。
- 失败后才调用 `show_state.sh --state <STATE_HOST>`；保留容器只通过 `--cleanup-state` 清理。

## Dry-run

仅在用户明确要求时传 `--dry-run --image-prefix TEST`。使用隔离地址，不执行任何补充 SSH、Docker、curl 或 API 探测。

## 测试参数

- 默认 custom smoke：`512/32/bs1`。
- 32k case 使用正式 example，或传 `--input-lens 32768 --output-len 1024 --concurrencies 1 --num-prompts-mult 1`。
- `32768/1024/bs1` 当前仍待重新验证，不得报告为稳定。
- `--nccl-ib-hca` 不是 Mooncake HCA 白名单。

## 新模型接入

新模型只执行本地两阶段流程：

1. 调用 `standardize_pd_server_scripts.sh --dry-run` 检查 P/D/proxy 标准化 diff，再正式生成 `scripts/pd-server/<model-short>/`。
2. 调用 `register_pd_model.sh --dry-run` 检查 profile/example，再正式注册。

这两个入口不得连接远端节点。当前只注册 `mooncake_vllm018 + 1p1d`；不要实现或模拟 xpyd。

详细命令、状态和故障分类见 `references/usage-guide.md`。
