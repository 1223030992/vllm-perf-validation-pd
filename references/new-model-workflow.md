# 新模型接入与完整测试流程

本文面向第一次使用 `vllm-perf-validation-pd` 扩展新模型的测试人员，覆盖：

```text
准备 P/D 原始脚本
  -> 模型接入 dry-run
  -> 正式注册
  -> 配置 deployment
  -> custom smoke
  -> 32k custom（可选）
  -> pchit fixed
  -> 判断状态与保存产物
```

当前正式范围是 `vLLM 0.18.1 + Mooncake + 1P1D`。本文中的 `<...>` 都必须在发送给 Claude 前替换为真实值。

## 1. 准备信息

开始前准备：

| 信息 | 示例形式 | 说明 |
|---|---|---|
| 用户名 | `<user>` | 远端用户名 |
| 姓名缩写 | `<abbr>` | 用于资源命名，不是模型名 |
| 模型名称 | `<MODEL_NAME>` | 模型目录对应的完整名称 |
| 模型短名 | `<model-short>` | 小写字母、数字和短横线 |
| Container 模型路径 | `/model/<MODEL_NAME>` | 容器中的挂载路径 |
| Host 模型路径 | `<HOST_MODEL_PATH>` | 计算节点上的真实目录 |
| P/D 原始脚本 | `<P_SERVER_SCRIPT>`、`<D_SERVER_SCRIPT>` | 必须已经能独立启动该模型 |
| 镜像 | `<IMAGE>` | P/D 节点必须解析到同一镜像 ID |
| Mooncake wheel | `<WHEEL>` | 镜像未预装 Mooncake 时必填 |
| P/D 节点和网络 | `<P_NODE>`、`<D_NODE>` 等 | 写入个人 deployment |
| 内存参数 | `<MAX_MODEL_LEN>`、`<GPU_MEMORY_UTILIZATION>` | 按模型和显存确定 |

原始 Prefill/Decode 脚本至少应满足：

- 都包含 `vllm serve`。
- Prefill 使用 `kv_role=kv_producer`，Decode 使用 `kv_role=kv_consumer`。
- P/D 的模型路径、TP、quantization 和 dtype 一致。
- 模型专属环境变量已经写入脚本。
- 默认不包含 `--profiler-config`。

## 2. 同步原始脚本

将脚本同步到远端 Skill 的临时目录，例如：

```text
/public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/tmp/<model-short>/p_server.sh
/public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/tmp/<model-short>/d_server.sh
```

同步动作由用户现有文件分发流程完成。不要让 Claude 为此手写 SSH、SCP 或远端 Docker 命令。

## 3. 模型接入 Dry-run

dry-run 会真实执行 staging 写入、标准脚本解析和 YAML 校验，但不会提交正式文件，也不会连接计算节点。

### Claude Prompt

```text
/vllm-perf-validation-pd

为 <MODEL_NAME> 接入 Mooncake 1P1D。本阶段只允许原样执行一次 onboard_pd_model.sh dry-run；不得执行 SSH、Docker、run_pd_task.sh、ls、cat、--help 或其他命令。

bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/onboard_pd_model.sh \
  --model-name <MODEL_NAME> \
  --model-short <model-short> \
  --profile-id <profile-id> \
  --container-model-path <CONTAINER_MODEL_PATH> \
  --prefill-source /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/tmp/<model-short>/p_server.sh \
  --decode-source /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/tmp/<model-short>/d_server.sh \
  --dry-run

成功必须出现 STAGING_VALIDATED=1 和 PD_MODEL_ONBOARD_DRY_RUN_DONE=1。汇报推导出的 TP、GPU、precision、quantization、dtype、speculative config、extra args 和目标路径。失败时只汇报结构化错误，不得自动修改脚本或重试。
```

### 验收重点

确认输出中的：

```text
PREFILL_KV_ROLE=kv_producer
DECODE_KV_ROLE=kv_consumer
INFERRED_TP=<EXPECTED_TP>
INFERRED_GPU_RANGE=<EXPECTED_GPU_RANGE>
STAGING_VALIDATED=1
PD_MODEL_ONBOARD_DRY_RUN_DONE=1
```

还需人工核对 profile 内容没有丢失模型专属环境变量、quantization、KV cache、speculative 或 compilation 参数。

## 4. 正式注册模型

只有接入 dry-run 的推导结果正确时，才执行正式注册。命令与 dry-run 完全相同，仅删除 `--dry-run`。

### Claude Prompt

```text
/vllm-perf-validation-pd

正式注册 <MODEL_NAME> Mooncake 1P1D。本阶段只允许原样执行一次 onboard_pd_model.sh；不得增加参数，不得执行 dry-run、SSH、Docker、run_pd_task.sh、ls、cat 或其他命令。

bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/onboard_pd_model.sh \
  --model-name <MODEL_NAME> \
  --model-short <model-short> \
  --profile-id <profile-id> \
  --container-model-path <CONTAINER_MODEL_PATH> \
  --prefill-source /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/tmp/<model-short>/p_server.sh \
  --decode-source /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/tmp/<model-short>/d_server.sh

成功必须出现 PD_MODEL_ONBOARD_DONE=1。汇报 SERVER_DIR、PROFILE_PATH、TEST_PRESET_PATH 及对应 SHA256。失败时确认 ROLLBACK_COMPLETED=1，不得自动重试。
```

正式注册会生成：

```text
scripts/pd-server/<model-short>/
references/pd-profiles/<profile-id>.yaml
references/test-presets/<model-short>-smoke.yaml
```

`raw/` 保存原始 P/D 脚本，标准目录保存参数化后的 P/D/Proxy 脚本。

## 5. 配置 Deployment

deployment 保存个人环境中的 Host 模型路径、节点、service IP、端口、网卡和 HCA，不提交到仓库。

### 新建 Deployment Prompt

```text
/vllm-perf-validation-pd

为 <MODEL_NAME> 创建 Mooncake 1P1D deployment。本阶段只允许原样执行一次 configure_pd_deployment.sh；不得执行 run_pd_task.sh、SSH、Docker、ls、cat 或其他命令。

bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/configure_pd_deployment.sh \
  --deployment-id <deployment-id> \
  --prefill-node <P_NODE> \
  --prefill-service-ip <P_SERVICE_IP> \
  --prefill-vllm-host-ip <P_VLLM_HOST_IP> \
  --decode-node <D_NODE> \
  --decode-service-ip <D_SERVICE_IP> \
  --decode-vllm-host-ip <D_VLLM_HOST_IP> \
  --prefill-port <P_PORT> \
  --decode-port <D_PORT> \
  --prefill-transfer-port <TRANSFER_PORT> \
  --proxy-port <PROXY_PORT> \
  --host-model-path <HOST_MODEL_PATH> \
  --network-ifname <IFNAME> \
  --nccl-ib-hca <HCA_LIST> \
  --user <user> --abbr <abbr>

成功必须出现 DEPLOYMENT_CONFIGURED=1，并汇报 DEPLOYMENT_PATH。若目标已存在，立即停止，不得自行覆盖。
```

生成路径：

```text
/public/home/<user>/.config/vllm-perf-validation-pd/deployments/<deployment-id>.yaml
```

### 更新 Host 模型路径

节点配置不变、只有 Host 模型路径变化时使用：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/configure_pd_deployment.sh \
  --deployment-id <deployment-id> \
  --host-model-path <NEW_HOST_MODEL_PATH> \
  --user <user> --abbr <abbr> --update-existing
```

`--update-existing` 只修改显式传入的字段，不会清空已有节点和网络配置。

### 临时覆盖规则

后续测试默认读取 deployment。若某次测试需要临时切换节点、service IP、端口或服务参数，覆盖值必须直接写进该次 `run_pd_task.sh` 命令块，不能只写在说明文字中。例如临时切换 Decode 必须同时加入：

```text
--decode-node <NEW_D_NODE>
--decode-service-ip <NEW_D_SERVICE_IP>
--decode-vllm-host-ip <NEW_D_VLLM_HOST_IP>
```

测试长度、并发、`max_model_len` 和 `gpu_memory_utilization` 同理。主入口在 SSH 前输出的 `EFFECTIVE_CONFIG_READY=1` 到 `EFFECTIVE_CONFIG_END=1` 是最终生效配置。

## 6. Custom Smoke

首次真实测试固定从 `512/32/c1` 开始。它验证 P/D 起服、Mooncake runtime、RDMA、Proxy 和 benchmark 闭环，不用于评价正式性能。

### Claude Prompt

```text
/vllm-perf-validation-pd

执行一次 <MODEL_NAME> Mooncake 1P1D custom smoke。只能原样执行下方命令一次。不得增加、删除或重命名参数；不得先执行 dry-run、configure、--help、ls、cat、SSH、Docker 或其他命令。

bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --profile <profile-id> \
  --deployment /public/home/<user>/.config/vllm-perf-validation-pd/deployments/<deployment-id>.yaml \
  --test-preset <model-short>-smoke \
  --input-lens 512 \
  --output-len 32 \
  --concurrencies 1 \
  --num-prompts-mult 1 \
  --max-model-len <MAX_MODEL_LEN> \
  --gpu-memory-utilization <GPU_MEMORY_UTILIZATION> \
  --image <IMAGE> \
  --mooncake-wheel <WHEEL> \
  --user <user> --abbr <abbr> --assume-yes

命令块是唯一授权配置。必须确认 TEST_MODE=custom、CUSTOM_INPUT_LENS=512、CUSTOM_OUTPUT_LEN=32、CUSTOM_CONCURRENCIES=1。

若出现 PD_INVOCATION_REJECTED=1 或没有 STATE_HOST，立即汇报并停止，不得重试。若运行期失败并输出 STATE_HOST，只允许调用一次：

bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/show_state.sh --state <STATE_HOST>

成功必须满足 EXECUTION_STATUS=PASS、BENCHMARK_STATUS=PASS、SLA_STATUS=NOT_APPLICABLE、PD_TASK_DONE=1。汇报 P/D/runtime/RDMA/Proxy 状态以及 state、CSV、JSON 和 Markdown 报告路径。
```

镜像已经预装 Mooncake 时，发送 Prompt 前删除 `--mooncake-wheel <WHEEL>` 这一行。

## 7. 32k Custom（可选）

smoke 通过后，可使用标准 preset 验证长上下文与并发。默认 case 是 `32768/1024/c4`。

### Claude Prompt

```text
/vllm-perf-validation-pd

执行一次 <MODEL_NAME> Mooncake 1P1D 32k custom 测试。只能原样执行下方命令一次，不得补充或改写参数，不得执行其他命令。

bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --profile <profile-id> \
  --deployment /public/home/<user>/.config/vllm-perf-validation-pd/deployments/<deployment-id>.yaml \
  --test-preset custom-32k1k-c4 \
  --input-lens 32768 \
  --output-len 1024 \
  --concurrencies 4 \
  --num-prompts-mult 1 \
  --max-model-len <MAX_MODEL_LEN> \
  --gpu-memory-utilization <GPU_MEMORY_UTILIZATION> \
  --image <IMAGE> \
  --mooncake-wheel <WHEEL> \
  --user <user> --abbr <abbr> --assume-yes

必须确认 REQUIRED_SEQUENCE_LENGTH=33792，且不超过 MAX_MODEL_LEN。失败处理与 smoke 相同。成功必须满足 EXECUTION_STATUS=PASS、BENCHMARK_STATUS=PASS、PD_TASK_DONE=1。
```

该步骤是可选项。某一并发 case 成功不能证明其他并发 case 已通过，结果必须按实际参数分别记录。

## 8. PCHIT Fixed

pchit 使用固定并发 `bs1..8`、输入 `32768`、输出 `1024` 和目标 PC Hit `90%`。默认 SLA 为 mean TTFT `<5000 ms`、mean TPOT `<50 ms`。

### Claude Prompt

```text
/vllm-perf-validation-pd

执行一次 <MODEL_NAME> Mooncake 1P1D pchit fixed 测试。只能原样执行下方命令一次。不得增加、删除或重命名参数；不得先执行 dry-run、configure、--help、ls、cat、SSH、Docker 或其他命令。

bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --profile <profile-id> \
  --deployment /public/home/<user>/.config/vllm-perf-validation-pd/deployments/<deployment-id>.yaml \
  --test-preset pchit-fixed \
  --pchit-input-len 32768 \
  --pchit-output-len 1024 \
  --pchit-batches "1 2 3 4 5 6 7 8" \
  --pc-hit-target 90 \
  --pchit-mode fixed \
  --ttft-sla-ms 5000 \
  --tpot-sla-ms 50 \
  --sla-stat mean \
  --max-model-len <MAX_MODEL_LEN> \
  --gpu-memory-utilization <GPU_MEMORY_UTILIZATION> \
  --image <IMAGE> \
  --mooncake-wheel <WHEEL> \
  --user <user> --abbr <abbr> --assume-yes

必须确认 TEST_MODE=pchit、PCHIT_INPUT_LEN=32768、PCHIT_OUTPUT_LEN=1024、PCHIT_BATCHES=1 2 3 4 5 6 7 8。

若出现 PD_INVOCATION_REJECTED=1 或没有 STATE_HOST，立即汇报并停止，不得重试。若运行期失败并输出 STATE_HOST，只允许调用一次：

bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/show_state.sh --state <STATE_HOST>

测试完成后汇报各并发请求成功/失败数量、TTFT、TPOT、PC Hit、最佳 SLA 并发以及全部产物路径。流程成功判据是 EXECUTION_STATUS=PASS、BENCHMARK_STATUS=PASS、PD_TASK_DONE=1；SLA_STATUS=PARTIAL 或 FAIL 只表示性能未达到 SLA，不等同于流程失败。
```

## 9. 结果判断

### 任务成功

```text
EXECUTION_STATUS=PASS
BENCHMARK_STATUS=PASS
PD_TASK_DONE=1
```

custom 的 `SLA_STATUS` 通常为 `NOT_APPLICABLE`。pchit 的 SLA 独立判断：

| SLA 状态 | 含义 |
|---|---|
| `PASS` | 所有目标并发满足 SLA |
| `PARTIAL` | 请求全部完成，但只有部分并发满足 SLA |
| `FAIL` | 请求执行完成，但没有目标并发满足 SLA |

### 参数调用失败

```text
PD_INVOCATION_REJECTED=1
TASK_STARTED=0
FAILURE_STAGE=parse_arguments
```

这种情况没有启动任务，不调用 `show_state.sh`，也不在同一次授权中自动重试。

### 运行期失败

运行期失败且输出 `STATE_HOST` 时，只调用一次：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/show_state.sh \
  --state <STATE_HOST>
```

默认失败会尝试停止已创建容器。需要保留 Proxy 或 benchmark 失败现场时，必须在最初的唯一授权命令中显式加入 `--keep-containers-on-failure`。

## 10. 产物

每次运行使用唯一 run id，主要产物为：

```text
work_dirs/<run-id>/state.json
work_dirs/<run-id>/logs/
work_dirs/<run-id>/csvs/<mode>/all.csv
work_dirs/<run-id>/csvs/pchit/prefix_cache_benchmark.json
reports/<run-id>.json
reports/<run-id>.md
```

成功后直接使用主入口摘要，不需要再次扫描目录或读取报告。

## 11. GLM-5.1-W4A8-V2_6 已验证案例

GLM5.1 是本流程第一个完整完成 onboarding、smoke 和 pchit 的新模型案例：

```text
profile: glm51-w4a8-vllm018-mooncake
smoke preset: glm51-w4a8-smoke
pchit preset: pchit-fixed
max_model_len: 67000
gpu_memory_utilization: 0.92
```

已验证结果：

- custom `512/32/c1`：1 个请求成功，0 失败。
- pchit `32768/1024/bs1..8`：36 个请求成功，0 失败。
- pchit 有效 PC Hit：约 `89.99%`。
- pchit 最佳 SLA 并发：`2`。
- pchit 状态：`EXECUTION_STATUS=PASS`、`BENCHMARK_STATUS=PASS`、`SLA_STATUS=PARTIAL`。

具体节点、Host 模型目录、镜像仓库和 wheel URL 属于部署环境，不应复制为其他用户的默认值。完整实测版本记录见 [verified-runs.md](verified-runs.md)。

## 12. 新模型接入检查清单

- [ ] P/D 原始脚本已同步，且 role 分别为 producer/consumer。
- [ ] onboarding dry-run 输出 `STAGING_VALIDATED=1`。
- [ ] 正式注册输出 `PD_MODEL_ONBOARD_DONE=1`。
- [ ] profile、标准 P/D/Proxy 和 smoke preset 均已生成。
- [ ] deployment 保存了正确的 Host 模型路径、节点、IP、端口和网卡。
- [ ] 镜像支持该模型，并且 P/D 节点镜像 ID 一致。
- [ ] `max_model_len` 能覆盖测试输入加输出长度。
- [ ] custom smoke 完成且 `PD_TASK_DONE=1`。
- [ ] 可选 32k custom 按实际 case 单独记录。
- [ ] pchit 全部请求完成，执行状态与 SLA 状态分别记录。
- [ ] README 支持矩阵和 [verified-runs.md](verified-runs.md) 只写入实际验证通过的能力。
