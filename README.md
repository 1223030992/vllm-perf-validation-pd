# vllm-perf-validation-pd

面向 DCU 环境的 vLLM PD 分离性能验证 Skill。当前正式支持 `vLLM 0.18.1 + Mooncake + 1P1D`，由 Claude 通过受控主入口完成 P/D 起服、runtime 检查、Proxy readiness、benchmark、停止容器和报告生成。

## 新用户先看

使用前准备以下信息：

1. 远端用户名，例如 `<user>`。
2. 姓名缩写，例如 `<abbr>`。`abbr` 用于资源命名，不是模型名或任务名。
3. 模型 profile，例如 `glm47-vllm018-mooncake`。
4. vLLM 镜像完整名称。
5. Mooncake wheel URL 或容器内绝对路径；镜像已预装时可不传。
6. Prefill/Decode 登录节点与 service IP。
7. 网卡和可选 HCA 列表。
8. 测试类型：smoke、32k custom 或 pchit。

真实节点和网络配置属于个人环境，保存在 `~/.config/vllm-perf-validation-pd/`，不会提交到仓库。

## 第一步：配置部署

首次使用时执行一次：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/configure_pd_deployment.sh \
  --deployment-id <deployment-id> \
  --prefill-node <P_NODE> --prefill-service-ip <P_SERVICE_IP> \
  --decode-node <D_NODE> --decode-service-ip <D_SERVICE_IP> \
  --host-model-path <HOST_MODEL_PATH> \
  --network-ifname <IFNAME> --nccl-ib-hca <HCA_LIST> \
  --user <user> --abbr <abbr>
```

默认端口为 Prefill `9348`、Decode `9349`、transfer `8998`、Proxy `8000`。如需调整，可追加对应端口参数。

Host 模型目录属于部署环境，不属于共享模型 profile。路径变化时使用受控更新，不要直接编辑 profile：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/configure_pd_deployment.sh \
  --deployment-id <deployment-id> \
  --host-model-path <NEW_HOST_MODEL_PATH> \
  --user <user> --abbr <abbr> --update-existing
```

生成文件：

```text
/public/home/<user>/.config/vllm-perf-validation-pd/deployments/<deployment-id>.yaml
```

## 第二步：交给 Claude 执行

推荐直接给 Claude 以下提示词，并替换占位符。命令块是唯一授权命令，Claude 必须原样执行一次：

```text
/vllm-perf-validation-pd

本次明确授权执行一次 Mooncake 1P1D 真实性能测试。
只能原样执行下方命令一次。不得增加、删除、改名或根据文字说明补充任何参数；不得先执行 dry-run、configure、--help、ls、cat、SSH、Docker 或其他命令。

bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --profile <PROFILE_ID> \
  --deployment /public/home/<user>/.config/vllm-perf-validation-pd/deployments/<deployment-id>.yaml \
  --test-preset <TEST_PRESET> \
  --image <IMAGE> \
  --mooncake-wheel <WHEEL> \
  --user <user> --abbr <abbr> --assume-yes

以下节点、网络、模型和测试信息仅用于核对主入口输出，不得转换成额外 CLI 参数：

Prefill：<P_NODE> / <P_SERVICE_IP>:<P_PORT>
Decode：<D_NODE> / <D_SERVICE_IP>:<D_PORT>
Transfer：<TRANSFER_PORT>
Proxy：<PROXY_PORT>
网卡：<IFNAME>
HCA：<HCA_LIST>
Host 模型：<HOST_MODEL_PATH>
Container 模型：<CONTAINER_MODEL_PATH>
测试：<EXPECTED_TEST_CASE>

若出现 PD_INVOCATION_REJECTED=1 或没有 STATE_HOST，立即汇报并停止，不得重试，不得调用 show_state.sh。
若运行期失败并输出 STATE_HOST，只允许调用一次 show_state.sh --state <STATE_HOST>。
成功后只根据主入口摘要汇报执行状态、benchmark 状态、SLA 状态、P/D/Proxy 状态和产物路径。
```

镜像已预装 Mooncake 时删除 `--mooncake-wheel`。正式测试不需要自动先跑 dry-run。

需要临时切换节点、IP、端口或服务参数时，覆盖项必须直接写入上述唯一授权命令。例如临时切换 Decode：

```text
--decode-node <NEW_D_NODE>
--decode-service-ip <NEW_D_SERVICE_IP>
--decode-vllm-host-ip <NEW_D_SERVICE_IP>
```

只写在“用于核对”的说明区不会生效。主入口会在任何 SSH 前输出 `EFFECTIVE_CONFIG_READY=1` 到 `EFFECTIVE_CONFIG_END=1`，dry-run 和真实运行使用同一份 effective config 摘要。

## 标准测试预设

| preset | 测试内容 | 用途 |
|---|---|---|
| `custom-smoke` | `512/32/c1` | 首次起服验证 |
| `custom-32k1k-c4` | `32768/1024/c4` | 长上下文 custom |
| `pchit-fixed` | `32768/1024/bs1..8/90%` | Prefix Cache Hit 与 SLA |

pchit 也支持 CLI 覆盖：`--pchit-input-len`、`--pchit-output-len`、`--pchit-batches`、`--pc-hit-target`、`--pchit-mode`、`--ttft-sla-ms`、`--tpot-sla-ms`、`--sla-stat`。

服务内存参数可显式覆盖：`--max-model-len <N>`、`--gpu-memory-utilization <0..1>`。主入口会在 SSH 前检查测试输入长度加输出长度不超过 `max_model_len`。

## 可选 Dry-run

仅在明确需要检查生成命令时使用：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --profile <PROFILE_ID> --deployment <DEPLOYMENT_YAML> \
  --test-preset custom-smoke --image <IMAGE> \
  --user <user> --abbr <abbr> --image-prefix TEST --dry-run
```

默认 dry-run 只输出 effective config、阶段摘要和关键命令。开发排查时才使用 `--verbose-dry-run`。

## 结果判断

主入口会直接输出紧凑摘要和产物路径：

```text
EXECUTION_STATUS=PASS|FAIL
BENCHMARK_STATUS=PASS|FAIL|NOT_RUN
SLA_STATUS=PASS|PARTIAL|FAIL|NOT_APPLICABLE
STATE_HOST=...
CSV_HOST=...
REPORT_JSON_HOST=...
REPORT_MD_HOST=...
PD_TASK_DONE=1
```

- `execution_status`：任务链路是否完整执行。
- `benchmark_status`：请求是否成功完成；起服前失败时为 `NOT_RUN`。
- `sla_status`：SLA 达标情况。pchit 部分并发未达 SLA 时可为 `PARTIAL`，不代表任务执行失败。
- 成功后容器执行 `docker stop`，不会删除或销毁。

每次运行都会生成唯一 invocation id，work dir、state、报告和容器名不会与上一次运行复用。

## 失败处理

参数拼写或参数值缺失会在任务启动前输出：

```text
PD_INVOCATION_REJECTED=1
TASK_STARTED=0
FAILURE_STAGE=parse_arguments
ARGUMENT_ERROR=...
ARGUMENT_HINT=...
```

这类失败不会创建 state、不会连接节点，也不得自动修正参数后重试。

默认失败会尝试停止已创建的 P/D 容器并生成失败报告。需要保留现场时添加：

```text
--keep-containers-on-failure
```

失败后查看状态：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/show_state.sh \
  --state <STATE_HOST>
```

受控清理保留容器：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --cleanup-state <STATE_HOST> --user <user> --abbr <abbr>
```

常见错误分类和处理方式见 [references/troubleshooting.md](references/troubleshooting.md)。

## 当前支持状态

| 能力 | 状态 |
|---|---|
| GLM-4.7-W8A8 Mooncake 1P1D 起服 | 已通过 |
| GLM-5.1-W4A8-V2_6 Mooncake 1P1D 起服 | 已通过 |
| Mooncake wheel 受控安装 | 已通过 |
| Proxy listener/upstream/bootstrap/smoke | 已通过 |
| GLM-4.7 custom `512/32/c1` | 已通过 |
| GLM-4.7 custom `32768/1024/c4` | 已通过 |
| GLM-4.7 pchit fixed `bs1..8` | 已通过，最佳 SLA 并发 5 |
| GLM-5.1 custom `512/32/c1` | 已通过 |
| GLM-5.1 pchit fixed `32768/1024/bs1..8` | 已通过，36 请求零失败，最佳 SLA 并发 2 |
| GLM-5.1 custom `32768/1024/c4` | 未实测 |
| GLM-4.7 历史 custom `32768/1024/c1` | 曾发生 RDMA timeout，未宣称已修复 |
| 新模型一键接入与完整验证流程 | 已通过 GLM-5.1 实测 |
| xpyd | 规划中 |

详细实测记录见 [references/verified-runs.md](references/verified-runs.md)。

## 扩展新模型

新模型按照以下顺序接入：

```text
准备 P/D 原始脚本
  -> onboarding dry-run
  -> 正式注册
  -> 配置 deployment
  -> custom smoke
  -> 可选 32k custom
  -> pchit fixed
```

GLM-5.1-W4A8-V2_6 已使用该流程完成真实 onboarding、smoke 和 pchit，证明新模型注册、起服、测试和报告闭环可用。

完整参数说明、每阶段命令、可直接发送给 Claude 的 Prompt、验收标准和 GLM5.1 案例见 [新模型接入与完整测试流程](references/new-model-workflow.md)。底层 onboarding 规则见 [references/model-onboarding.md](references/model-onboarding.md)。

## 更多文档

- [完整使用说明](references/usage-guide.md)
- [已验证案例](references/verified-runs.md)
- [故障排查](references/troubleshooting.md)
- [新模型接入与完整测试流程](references/new-model-workflow.md)
- [模型接入工具规则](references/model-onboarding.md)
- [开发与检查](references/development.md)
