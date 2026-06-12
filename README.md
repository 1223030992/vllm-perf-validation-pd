# vllm-perf-validation-pd

[GitHub](https://github.com/1223030992/vllm-perf-validation-pd)

用于在 DCU 环境自动完成 `vLLM 0.18.1 + Mooncake + PD` 的容器创建、P/D 起服、runtime 检查、Proxy readiness、benchmark、停止服务和报告生成。

当前稳定基线是 `GLM-4.7-W8A8 + Mooncake + 1P1D`。正式测试只调用 `scripts/ops/run_pd_task.sh`，不手写 SSH、Docker、`vllm serve`、Proxy、benchmark、curl 或 stop 命令。

> **TL;DR**
>
> - **用途**：在 DCU 上一键跑通 vLLM 0.18.1 + Mooncake 1P1D PD 的端到端冒烟（容器 → P/D 起服 → runtime → proxy → benchmark → 报告）。
> - **唯一入口**：`scripts/ops/run_pd_task.sh`（dry-run 和正式 run 都用同一个脚本）。
> - **最近一次主 case（2026-06-12）**：GLM-4.7-W8A8，32k/1k/conc=4，CSV `PASS`，0 failed，TTFT Mean 17.07 s / P99 23.72 s，TPOT P99 39.93 ms，ITL P99 46.82 ms（详见 §8）。
> - **每次必传**：`--user` / `--abbr` / `--prefill-node` / `--decode-node` / `--network-ifname` / `--nccl-ib-hca` / `--image`（缺一会 `preflight_pd` 失败）。
> - **本 README 已脱敏**：所有具体 IP、用户、缩写、镜像、模型路径都用 `<占位符>` 表示；复制命令后请替换为本地值。

## 快速导航

- [1. 新用户配置](#1-新用户配置)
- [2. 快速使用](#2-快速使用)
- [3. 项目结构](#3-项目结构)
- [4. 状态和产物](#4-状态和产物)
- [5. 支持矩阵](#5-支持矩阵)
- [6. Claude 标准指令](#6-claude-标准指令)
- [7. 新模型接入](#7-新模型接入)
- [8. 已验证案例](#8-已验证案例)
  - [8.0 关键指标](#80-关键指标)
  - [8.1 性能观察](#81-性能观察)
  - [8.2 历史案例](#82-历史案例)
- [9. 常见问题](#9-常见问题)
  - [9.6 example YAML 中硬编码的 IP 覆盖了真实节点](#96-example-yaml-中硬编码的-ip-覆盖了真实节点)
- [10. 开发验证](#10-开发验证)

## 1. 新用户配置

新用户无需全仓替换用户名。每次调用显式传入：

```text
--user <Linux 用户名> --abbr <姓名缩写>
```

`abbr` 是用户姓名缩写，只用于容器和工作目录命名，不是模型名或任务名。例如用户 `<user>` 的姓名缩写为 `<abbr>`：

```bash
--user <user> --abbr <abbr>
```

运行时默认推导：

```text
skill:   /public/home/<user>/.claude/skills/vllm-perf-validation-pd
output:  /public/home/<user>/skilltest/vllm-perf-validation-pd
prefix:  <abbr>-agent-test
```

本 README 中所有 IP、`<user>`、`<abbr>`、镜像、模型路径、网卡、HCA 均为占位符（与示例的脱敏值）。历史实测路径只用于结果追溯，不参与新用户配置，复制命令前请替换为本地实际值。

## 2. 快速使用

> 主入口统一推进以下五个阶段，每一步都会更新 `state.json`；任何一步失败会落入受控 cleanup（见 §4 / §2.4）：
>
> ```text
> ┌──────────────┐    ┌────────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
> │ ensure_      │ →  │ create_        │ →  │ start_       │ →  │ run_         │ →  │ stop_* /     │
> │ workspace +  │    │ prefill/       │    │ prefill/     │    │ bench        │    │ finalize /   │
> │ preflight_pd │    │ decode_        │    │ decode +     │    │ (custom or   │    │ render_      │
> │              │    │ container      │    │ wait_ +      │    │ pchit)       │    │ report       │
> │              │    │                │    │ proxy        │    │              │    │              │
> └──────────────┘    └────────────────┘    └──────────────┘    └──────────────┘    └──────────────┘
>        ↘                    ↘                     ↘                  ↘                  ↘
>                     ┌─────────────────────────────────────────────────────────┐
>                     │  state.json   (pd.roles.* / pd.proxy / pd.transfer /    │
>                     │                test.* / failure.*  / paths.*)            │
>                     └─────────────────────────────────────────────────────────┘
> ```

### 2.1 隔离 dry-run

只有用户明确要求 dry-run 时才执行。dry-run 必须使用隔离地址和 `--image-prefix TEST`，不会连接 SSH、Docker 或 GPU：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --config references/examples/glm47-vllm018-mooncake-1p1d-custom.yaml \
  --image <repository:tag> \
  --prefill-node 192.0.2.10 --prefill-service-ip 198.51.100.10 --prefill-vllm-host-ip 198.51.100.10 \
  --decode-node 192.0.2.20 --decode-service-ip 198.51.100.20 --decode-vllm-host-ip 198.51.100.20 \
  --network-ifname test0 --nccl-ib-hca test_hca0 \
  --user <user> --abbr <abbr> --image-prefix TEST --dry-run
```

成功标记：`PD_DRY_RUN_DONE=1`。

### 2.2 正式 custom smoke

正式测试直接执行一次主入口，不自动先跑 dry-run，也不追加 `tail`、`tee`、`2>&1`、`&` 或外部 `timeout`：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --config references/examples/glm47-vllm018-mooncake-1p1d-custom.yaml \
  --image <repository:tag> \
  --mooncake-wheel <wheel-url-or-container-path> \
  --prefill-node <P_NODE> --prefill-service-ip <P_SERVICE_IP> --prefill-vllm-host-ip <P_SERVICE_IP> \
  --decode-node <D_NODE> --decode-service-ip <D_SERVICE_IP> --decode-vllm-host-ip <D_SERVICE_IP> \
  --prefill-port 9348 --decode-port 9349 --prefill-transfer-port 8998 --proxy-port 8000 \
  --network-ifname <IFNAME> --nccl-ib-hca <HCA_LIST> \
  --user <user> --abbr <abbr> --assume-yes
```

预装 Mooncake 的镜像不需要 `--mooncake-wheel`。只有输出 `PD_TASK_DONE=1` 才算成功。

> 提示：example YAML 中的 IP/端口如与本机不符，CLI flag 优先；详见 §9.6 的复盘。

### 2.3 32k/1k/conc=4（推荐主 case）

```bash
--config references/examples/glm47-vllm018-mooncake-1p1d-custom-32k1k-bs1.yaml
```

也可以在普通 custom example 上覆盖：

```bash
--input-lens 32768 --output-len 1024 \
--concurrencies 4 --num-prompts-mult 1 \
--mooncake-dest-device-affinity 1 --bench-timeout 3600
```

最近一次 2026-06-12 验证通过，详细数据见 §8。原 `32k/1k/bs1` 已被本节取代。

### 2.4 失败保留和清理

需要保留 Proxy 或 benchmark 失败现场时增加：

```bash
--keep-containers-on-failure
```

随后只能通过受控入口清理：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --cleanup-state <STATE_HOST> --user <user> --abbr <abbr>
```

## 3. 项目结构

```text
vllm-perf-validation-pd/
├── SKILL.md
├── task.yaml
├── agents/openai.yaml
├── references/
│   ├── examples/             # 节点、网络、端口和测试参数
│   ├── pd-profiles/          # 模型、server scripts、runtime 和服务默认值
│   ├── schemas/
│   └── usage-guide.md        # 字段定义、失败分类、日志样例
└── scripts/
    ├── client-scripts/       # custom/pchit benchmark 实现
    ├── ops/                  # 唯一正式编排入口和受控辅助工具
    ├── pd-server/<model>/    # 每个模型的 P/D/proxy 标准脚本
    └── tests/
```

配置分层：

| 层 | 内容 |
|---|---|
| model profile | 模型路径、精度、TP/GPU、P/D/proxy 脚本和 runtime 默认值 |
| deployment example | P/D 节点、service IP、端口、网卡和 HCA |
| CLI | 当前用户、镜像、wheel 和本次运行覆盖值 |

`run_pd_task.sh` 不再提供 GLM4.7 server script 兜底。profile 缺少 P/D/proxy 任一脚本时会在 SSH 前失败。

## 4. 状态和产物

主入口围绕同一份 `state.json` 更新状态，并在成功或失败结束前自动打印紧凑摘要。正常成功后不需要再调用 `show_state.sh`。

| 状态/标记 | 含义 |
|---|---|
| `INITIALIZED` | state 已建立 |
| `RUNTIME_READY` | Mooncake runtime 已验证 |
| `READY` | P/D 或 Proxy 分阶段就绪 |
| `BENCH_RUNNING` | benchmark 正在运行并更新 heartbeat |
| `COMPLETED` / `PD_TASK_DONE=1` | benchmark、stop 和报告全部成功 |
| `PD_TASK_FAILED=1` | 任一阶段失败，原始失败原因已写入 state |

标准产物：

```text
<output>/work_dirs/<run>/state.json
<output>/work_dirs/<run>/logs/
<output>/work_dirs/<run>/csvs/<mode>/all.csv
<output>/reports/<run-id>.json
<output>/reports/<run-id>.md
```

失败后可读取绝对 state 路径，通常无需再次传 `--user`：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/show_state.sh \
  --state /public/home/<user>/skilltest/vllm-perf-validation-pd/work_dirs/<run>/state.json
```

## 5. 支持矩阵

### 模型与拓扑

| 模型 | Backend | 拓扑 | 状态 |
|---|---|---|---|
| GLM-4.7-W8A8 | Mooncake/vLLM018 | 1P1D | 已通过 32k/1k/conc=4 smoke（2026-06-12） |
| 新模型 | Mooncake/vLLM018 | 1P1D | 可通过标准化和注册工具扩展 |
| 任意模型 | xpyd | xpyd | 规划中，尚未实现 |

### 功能状态

| 能力 | 状态 |
|---|---|
| GLM4.7 Mooncake 1P1D 起服 | 已通过 |
| runtime wheel 受控安装 | 已通过 |
| Proxy listener/upstream/bootstrap/smoke readiness | 已通过 |
| custom 512/32/bs1 | 历史通过 |
| custom 32768/1024/conc=4 | 已通过（2026-06-12） |
| `--mooncake-dest-device-affinity=1` | 已通过（2026-06-12） |
| RDMA watchdog v5（transport retry / timeout watch） | 已通过（2026-06-12） |
| pchit | 未实测 |
| xpyd | 规划中 |

## 6. Claude 标准指令

### 6.1 正式 GLM4.7 smoke

```text
/vllm-perf-validation-pd

执行一次 GLM-4.7-W8A8、vLLM 0.18.1、Mooncake 1P1D 真实冒烟测试。

执行约束：
- 只能直接调用一次 run_pd_task.sh。
- 不要先执行 dry-run，不要执行 ls、cat、--help、usage-guide 读取、额外报告扫描。
- 不要在命令后追加 tail、tee、管道、& 或外部 timeout。
- 如果执行环境自动把命令转为后台任务，只等待原任务完成，禁止重复启动。
- 失败后只能调用 show_state.sh。
- 禁止手写 SSH、Docker、curl、vllm serve、Mooncake proxy、pip install 或 stop 命令。

运行前确认：
- PD_SCRIPT_VERSION 必须为 2026.06.12-rdma-watchdog-v5。
- 使用 custom 模式。
- 输入长度 32768，输出长度 1024，并发 4，num_prompts_mult 1。
- benchmark 单 case 超时 3600 秒。
- Mooncake destination device affinity 设置为 1。
- 使用 --keep-containers-on-failure 和 --assume-yes。
- 镜像未预装 Mooncake 时使用 --mooncake-wheel <WHEEL> 受控安装。

用户：<user>，姓名缩写：<abbr>。
Prefill：<PREFILL_NODE_IP> / <PREFILL_SERVICE_IP>:9348。
Decode：<DECODE_NODE_IP> / <DECODE_SERVICE_IP>:9349。
Transfer port：8998，Proxy port：8000，网卡：<IFNAME>，HCA：<HCA_LIST>。
Host 模型：<HOST_MODEL_PATH>，Container 模型：<CONTAINER_MODEL_PATH>。
镜像：<IMAGE>。

测试完还要输出性能报告（附简分析），要有 vllm bench serve 的关键指标。

完成后只根据主入口摘要汇报 PD_SCRIPT_VERSION、SELECTED_IMAGE、P/D runtime 与 readiness、Proxy listener/upstream/bootstrap/smoke、Mooncake transfer protocol、P/D detected HCA、GID、benchmark current case、heartbeat、elapsed、最终状态、failure reason、transfer error summary、cleanup policy、containers preserved、state/CSV/JSON/Markdown 路径。
```

### 6.2 隔离 dry-run

```text
/vllm-perf-validation-pd

只执行一次隔离 custom dry-run。只能调用 run_pd_task.sh，不允许任何补充命令。使用 192.0.2.10/20 节点、198.51.100.10/20 service IP、test0 网卡、test_hca0 HCA，并显式传 --dry-run --image-prefix TEST。完成后只分析主入口生成的命令和 PD_DRY_RUN_DONE 标记。
```

## 7. 新模型接入

新模型使用“标准化脚本，再注册 profile”的两阶段流程。两个工具都只修改本地 skill 文件，不连接 SSH、Docker 或 GPU。

### 7.1 标准化原始 P/D/proxy 脚本

先看 diff：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/standardize_pd_server_scripts.sh \
  --model-short <model-short> \
  --prefill-source <p_server.sh> \
  --decode-source <d_server.sh> \
  --proxy-source <run_proxy.sh> \
  --dry-run
```

确认后去掉 `--dry-run`。目标目录固定为：

```text
scripts/pd-server/<model-short>/p_server.sh
scripts/pd-server/<model-short>/d_server.sh
scripts/pd-server/<model-short>/run_proxy.sh
```

如需保存原始脚本，增加 `--preserve-raw`。覆盖已有标准脚本必须显式增加 `--overwrite`。

### 7.2 注册模型

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/register_pd_model.sh \
  --profile-id <model-vllm018-mooncake> \
  --model-name <MODEL_NAME> --model-short <model-short> \
  --host-model-path <HOST_MODEL_PATH> \
  --container-model-path <CONTAINER_MODEL_PATH> \
  --precision <precision> --tp <tp> --gpu-range <gpu-range> \
  --quantization <quantization> --dtype <dtype> \
  --base-config references/examples/glm47-vllm018-mooncake-1p1d-custom.yaml \
  --user <user> --abbr <abbr> --dry-run
```

dry-run 无错误后去掉 `--dry-run`。注册器生成：

```text
references/pd-profiles/<profile-id>.yaml
references/examples/<profile-id>-1p1d-custom.yaml
```

模型 profile 不保存节点和网络；新 example 从 `--base-config` 复制 deployment 层，并生成默认 `512/32/bs1 custom` case。profile id、model short 或输出文件冲突时默认拒绝覆盖。

## 8. 已验证案例

### 8. GLM-4.7-W8A8 Mooncake 1P1D custom（32k/1k/conc=4）— 最近一次验证

- **日期**：2026-06-12
- **PD_SCRIPT_VERSION**：`2026.06.12-rdma-watchdog-v5`
- **vLLM**：0.18.1
- **Mooncake**：`0.3.10.post1+das.opt1.dtk2604.2605131137.gd34f6f`（通过 `--mooncake-wheel` 在容器内受控安装）
- **镜像**：`<REGISTRY>/vllm:<TAG>`（vLLM 0.18.1 + DCU DTK 26.04 + Python 3.10 基底）
- **Prefill**：`<PREFILL_NODE_IP> / <PREFILL_SERVICE_IP>:9348`
- **Decode**：`<DECODE_NODE_IP> / <DECODE_SERVICE_IP>:9349`
- **Transfer / Proxy**：`8998 / 8000`
- **网卡**：`<IFNAME>`（实际使用 `ens61f0np0`，仅作示例；HCA 白名单不同时 Mooncake 会自动发现）
- **HCA**：`<HCA_LIST>`（`--nccl-ib-hca` 仅约束 NCCL，不是 Mooncake 限制）
- **测试**：`input=32768, output=1024, concurrency=4, num_prompts_mult=1`，`--mooncake-dest-device-affinity=1`，`--bench-timeout=3600`
- **结果**：CSV `status=PASS`，`failed=0`，`duration=64.70s`；P/D、runtime、RDMA transfer、Proxy readiness、stop 与 report 全部成功
- **Cleanup policy**：`--keep-containers-on-failure` 已生效（容器在失败时保留以供诊断；本次成功路径下 P/D 容器在 stop_* 阶段被销毁）

#### 8.0 关键指标

下表来自 `vllm bench serve` 输出（`vllm bench serve` 默认报告的字段，已对照 `csvs/custom/all.csv` 校核）：

| 类别 | 指标 | 数值 |
|---|---|---:|
| 规模 | Total input tokens | 131,072 |
| 规模 | Total generated tokens | 4,096 |
| 规模 | Max request concurrency | 4.00 |
| 时长 | Benchmark duration | 64.70 s |
| 吞吐 | Request throughput | 0.06 req/s |
| 吞吐 | Output token throughput | 63.31 tok/s |
| 吞吐 | Peak output token throughput | 88.00 tok/s |
| 吞吐 | Peak concurrent requests | 4.00 |
| 吞吐 | Total token throughput | 2,089.10 tok/s |
| TTFT (ms) | Mean | 17,068.56 |
| TTFT (ms) | P50 | 17,920.10 |
| TTFT (ms) | P95 | 23,299.74 |
| TTFT (ms) | P99 | 23,718.86 |
| TPOT (ms) | Mean | 37.59 |
| TPOT (ms) | P50 | 37.38 |
| TPOT (ms) | P95 | 39.82 |
| TPOT (ms) | P99 | 39.93 |
| ITL (ms) | Mean | 43.49 |
| ITL (ms) | P50 | 45.76 |
| ITL (ms) | P95 | 46.63 |
| ITL (ms) | P99 | 46.82 |
| 失败 | Failed requests | 0 |
| 结论 | CSV status | PASS |

#### 8.1 性能观察

- **TTFT 由 prefill 主导**：Mean ~17.07 s、P95 ~23.30 s、P99 ~23.72 s。4 路并发 32k prefill 的计算量在当前硬件上就是这个量级；Mooncake transfer 不占大头。
- **TPOT 健康**：Mean 37.59 ms / P99 39.93 ms，说明 Mooncake KV transfer 在 4 路并发下仍稳定；本轮未触发 §9.4 的 watchdog 异常信号（无 `transport retry counter exceeded` / `Sync batch data transfer timeout` / `pulling kv_caches ... failed`）。
- **Output / Total 比例健康**：Total 2,089.10 tok/s 中 Output 仅 63.31 tok/s（≈3%），P/D 配比由 input token 量主导，prefill 计算 / KV transfer 路径是吞吐主轴。
- **资源饱和**：Peak concurrent 4.00 = 配置上限，未出现把并发堆到 4 之后系统被打挂的情况。

#### 8.2 历史案例

| case | 关键参数 | 结果 | 备注 |
|---|---|---|---|
| 32k/1k/bs1（旧 watchdog） | input=32768, output=1024, conc=1 | 早期 RDMA transfer timeout | watchdog v5 修复后以 conc=4 复测通过，见 §8 主 case |
| 512/32/bs1（更早） | input=512, output=32, conc=1 | PASS，Mean TTFT 266.02 ms，Mean TPOT 50.97 ms | 保留记录；指标见支持矩阵 §5 |

旧 `--abbr=glm47pd-smoke` 的成功产物路径保持不变、不迁移；后续测试统一使用姓名缩写 `--abbr <abbr>`。

## 9. 常见问题

### Proxy 日志出现 `/metrics 404`

`vllm bench serve` 可能探测 `/metrics`。只要 `/v1/completions` 返回 200、CSV case 为 `PASS`，单独的 `/metrics 404` 不代表 benchmark 失败。

### vLLM 输出模型类重复注册或 speculative warning

HCU 插件覆盖模型类、speculative decoding 参数提示等 warning 不直接判定失败。以进程、fatal 日志、readiness API 和 benchmark 结果为准。

### 配置 HCA 与 Mooncake 检测 HCA 不一致

成功案例中 Mooncake 实际发现 `mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_8,mlx5_9`。`--nccl-ib-hca` 只约束 NCCL，不是 Mooncake Transfer Engine 的 HCA 白名单。

### 什么日志属于传输失败

以下信号会由 watchdog 分类并提前终止 benchmark：

```text
transport retry counter exceeded
Sync batch data transfer timeout
Mooncake transfer engine returned -1
pulling kv_caches ... failed
```

### `show_state.sh` 报缺少 user

优先传 Host 侧绝对 state 路径。标准 `/public/home/<user>/...` 路径会自动推导用户；远程读取或非标准路径仍需显式传 `--user`。

### 9.6 example YAML 中硬编码的 IP 覆盖了真实节点

**现象**：第一次正式 smoke 在 `preflight_pd` 阶段报 `DOCKER_IMAGE_NOT_FOUND` / `state.failure.reason=docker_image_not_found`，看起来是镜像没拉到。

**根因**：实际上是 `references/examples/glm47-vllm018-mooncake-1p1d-custom.yaml` 中 `pd.roles.decode.node / service_ip / vllm_host_ip` 还指向更早一次测试用的旧 IP（被复用了同一份 example 而没有覆盖）。脚本走到 decode 节点做镜像预检时 SSH 不通，被归类成"镜像问题"。

**教训**：

- CLI flag 永远覆盖 YAML（`--prefill-node` / `--decode-node` / `--prefill-service-ip` / `--decode-service-ip` / `--prefill-vllm-host-ip` / `--decode-vllm-host-ip`），但 example YAML 中的节点字段会作为 SSH 默认目标；**每次新 run 都应显式传节点 IP**，不要依赖 example 里的旧值。
- 修改 example YAML 时同步更新 `pd.roles.{prefill,decode}.{node,service_ip,vllm_host_ip}` 全套字段，或复制一份改名再做改动。
- preflight 阶段的 `DOCKER_IMAGE_NOT_FOUND` 不一定真的是镜像问题——先打开 `<output>/work_dirs/<run>/state.json` 的 `preflight_pd` 段确认是 SSH 失败还是镜像缺失，再下结论。

## 10. 开发验证

Windows 本地不要求运行 bash。提交前执行：

```bash
python -m compileall -q scripts
python -m unittest discover -s scripts/tests -p "test_*.py" -v
python scripts/ops/pd_config.py --config references/examples/glm47-vllm018-mooncake-1p1d-custom.yaml --json
python scripts/ops/pd_config.py --config references/examples/glm47-vllm018-mooncake-1p1d-pchit.yaml --json
python scripts/ops/pd_config.py --config references/examples/glm47-vllm018-mooncake-1p1d-custom-32k1k-bs1.yaml --json
git diff --check
```

Linux/远端再执行：

```bash
bash -n scripts/ops/*.sh scripts/pd-server/*/*.sh
```

详细字段和失败分类见 [references/usage-guide.md](references/usage-guide.md)。
