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
  --network-ifname <IFNAME> --nccl-ib-hca <HCA_LIST> \
  --user <user> --abbr <abbr>
```

默认端口为 Prefill `9348`、Decode `9349`、transfer `8998`、Proxy `8000`。如需调整，可追加对应端口参数。

生成文件：

```text
/public/home/<user>/.config/vllm-perf-validation-pd/deployments/<deployment-id>.yaml
```

## 第二步：交给 Claude 执行

推荐直接给 Claude 以下提示词，并替换占位符：

```text
/vllm-perf-validation-pd

执行一次 Mooncake 1P1D 真实性能测试。
只能调用 run_pd_task.sh；失败后只能调用 show_state.sh。
禁止手写 SSH、Docker、curl、vllm serve、Mooncake proxy、pip install、stop 命令，禁止追加 tail、tee、管道、后台符号或外部 timeout。

profile：<PROFILE_ID>
deployment：/public/home/<user>/.config/vllm-perf-validation-pd/deployments/<deployment-id>.yaml
test preset：<TEST_PRESET>
镜像：<IMAGE>
Mooncake wheel：<WHEEL_OR_OMIT>
用户：<user>
姓名缩写：<abbr>

使用 --assume-yes。完成后只根据主入口摘要汇报执行状态、benchmark 状态、SLA 状态、P/D/Proxy 状态和产物路径。
```

Claude 对应执行的标准命令为：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --profile <PROFILE_ID> \
  --deployment /public/home/<user>/.config/vllm-perf-validation-pd/deployments/<deployment-id>.yaml \
  --test-preset <TEST_PRESET> \
  --image <IMAGE> \
  --mooncake-wheel <WHEEL> \
  --user <user> --abbr <abbr> --assume-yes
```

镜像已预装 Mooncake 时删除 `--mooncake-wheel`。正式测试不需要自动先跑 dry-run。

## 标准测试预设

| preset | 测试内容 | 用途 |
|---|---|---|
| `custom-smoke` | `512/32/c1` | 首次起服验证 |
| `custom-32k1k-c4` | `32768/1024/c4` | 长上下文 custom |
| `pchit-fixed` | `32768/1024/bs1..8/90%` | Prefix Cache Hit 与 SLA |

pchit 也支持 CLI 覆盖：`--pchit-input-len`、`--pchit-output-len`、`--pchit-batches`、`--pc-hit-target`、`--pchit-mode`、`--ttft-sla-ms`、`--tpot-sla-ms`、`--sla-stat`。

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
BENCHMARK_STATUS=PASS|FAIL
SLA_STATUS=PASS|PARTIAL|FAIL|NOT_APPLICABLE
STATE_HOST=...
CSV_HOST=...
REPORT_JSON_HOST=...
REPORT_MD_HOST=...
PD_TASK_DONE=1
```

- `execution_status`：任务链路是否完整执行。
- `benchmark_status`：请求是否成功完成。
- `sla_status`：SLA 达标情况。pchit 部分并发未达 SLA 时可为 `PARTIAL`，不代表任务执行失败。
- 成功后容器执行 `docker stop`，不会删除或销毁。

每次运行都会生成唯一 invocation id，work dir、state、报告和容器名不会与上一次运行复用。

## 失败处理

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
| Mooncake wheel 受控安装 | 已通过 |
| Proxy listener/upstream/bootstrap/smoke | 已通过 |
| custom `512/32/c1` | 已通过 |
| custom `32768/1024/c4` | 已通过 |
| pchit fixed `bs1..8` | 已执行通过，SLA 最佳并发 5 |
| 历史 custom `32768/1024/c1` | 曾发生 RDMA timeout，未宣称已修复 |
| 新模型一键接入 | 已提供 |
| xpyd | 规划中 |

详细实测记录见 [references/verified-runs.md](references/verified-runs.md)。

## 新模型一键接入

准备已实测的 Prefill/Decode 原始起服脚本后执行：

```bash
bash scripts/ops/onboard_pd_model.sh \
  --model-name <MODEL_NAME> \
  --model-short <MODEL_SHORT> \
  --host-model-path <HOST_MODEL_PATH> \
  --prefill-source <P_SERVER_SCRIPT> \
  --decode-source <D_SERVER_SCRIPT> \
  --dry-run
```

确认推导结果后删除 `--dry-run`。工具会一次生成标准 P/D/Proxy 脚本、独立 model profile 和默认 smoke preset，不继承 GLM 专属参数，并输出首次 smoke 命令。

完整规则见 [references/model-onboarding.md](references/model-onboarding.md)。

## 更多文档

- [完整使用说明](references/usage-guide.md)
- [已验证案例](references/verified-runs.md)
- [故障排查](references/troubleshooting.md)
- [新模型接入](references/model-onboarding.md)
- [开发与检查](references/development.md)
