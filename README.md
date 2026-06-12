# vllm-perf-validation-pd

[GitHub](https://github.com/1223030992/vllm-perf-validation-pd)

用于在 DCU 环境自动完成 `vLLM 0.18.1 + Mooncake + PD` 的容器创建、P/D 起服、runtime 检查、Proxy readiness、benchmark、停止服务和报告生成。

当前稳定基线是 `GLM-4.7-W8A8 + Mooncake + 1P1D`。正式测试只调用 `scripts/ops/run_pd_task.sh`，不手写 SSH、Docker、`vllm serve`、Proxy、benchmark、curl 或 stop 命令。

## 快速导航

- [1. 新用户配置](#1-新用户配置)
- [2. 快速使用](#2-快速使用)
- [3. 项目结构](#3-项目结构)
- [4. 状态和产物](#4-状态和产物)
- [5. 支持矩阵](#5-支持矩阵)
- [6. Claude 标准指令](#6-claude-标准指令)
- [7. 新模型接入](#7-新模型接入)
- [8. 已验证案例](#8-已验证案例)
- [9. 常见问题](#9-常见问题)
- [10. 开发验证](#10-开发验证)

## 1. 新用户配置

新用户无需全仓替换用户名。每次调用显式传入：

```text
--user <Linux 用户名> --abbr <姓名缩写>
```

`abbr` 是用户姓名缩写，只用于容器和工作目录命名，不是模型名或任务名。例如用户 `liuzhh8` 的姓名缩写为 `lzh`：

```bash
--user liuzhh8 --abbr lzh
```

运行时默认推导：

```text
skill:   /public/home/<user>/.claude/skills/vllm-perf-validation-pd
output:  /public/home/<user>/skilltest/vllm-perf-validation-pd
prefix:  <abbr>-agent-test
```

README 中的 `<user>`、`<abbr>`、节点和镜像都是占位符。历史实测路径只用于结果追溯，不参与新用户配置。

## 2. 快速使用

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

### 2.3 32k/1k/bs1

```bash
--config references/examples/glm47-vllm018-mooncake-1p1d-custom-32k1k-bs1.yaml
```

也可以在普通 custom example 上覆盖：

```bash
--input-lens 32768 --output-len 1024 \
--concurrencies 1 --num-prompts-mult 1
```

该 case 当前仍是待重新验证状态，不应标记为稳定。

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
│   └── usage-guide.md
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
| GLM-4.7-W8A8 | Mooncake/vLLM018 | 1P1D | 已通过基础 smoke |
| 新模型 | Mooncake/vLLM018 | 1P1D | 可通过标准化和注册工具扩展 |
| 任意模型 | xpyd | xpyd | 规划中，尚未实现 |

### 功能状态

| 能力 | 状态 |
|---|---|
| GLM4.7 Mooncake 1P1D 起服 | 已通过 |
| runtime wheel 受控安装 | 已通过 |
| Proxy listener/upstream/bootstrap/smoke readiness | 已通过 |
| custom 512/32/bs1 | 已通过 |
| custom 32768/1024/bs1 | 待重新验证 |
| pchit | 未实测 |
| benchmark heartbeat/RDMA watchdog | 已实现，待更多实测 |
| xpyd | 规划中 |

## 6. Claude 标准指令

### 6.1 正式 GLM4.7 smoke

```text
/vllm-perf-validation-pd

执行一次 GLM-4.7-W8A8、vLLM 0.18.1、Mooncake 1P1D custom 真实冒烟测试。

只能直接调用一次 run_pd_task.sh。不要先执行 dry-run，不要执行 ls、cat、--help、usage-guide 读取、额外报告扫描，不要追加 tail、tee、2>&1、后台符号或外部 timeout。失败后才允许调用 show_state.sh。

custom 参数：输入 512，输出 32，并发 1，请求数 1。
用户：<user>，姓名缩写：<abbr>。
Prefill：<P_NODE> / <P_SERVICE_IP>:9348。
Decode：<D_NODE> / <D_SERVICE_IP>:9349。
Transfer port：8998，Proxy port：8000，网卡：<IFNAME>，HCA：<HCA_LIST>。
Host 模型：<HOST_MODEL_PATH>，Container 模型：<CONTAINER_MODEL_PATH>。
镜像：<IMAGE>。镜像未预装 Mooncake 时使用 --mooncake-wheel <WHEEL>。
使用 --assume-yes。完成后只根据主入口摘要汇报 PD_SCRIPT_VERSION、SELECTED_IMAGE、P/D/runtime/transfer/proxy、state、CSV 和报告路径。
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

### GLM-4.7-W8A8 Mooncake 1P1D custom

- 日期：2026-06-12
- 镜像：`10.16.1.152:5000/jenkins/model_test_env/vllm:0.18.1-ubuntu22.04-dtk26.04-py3.10-20260608-1434`
- Prefill：`10.16.1.1 / 13.13.1.1:9348`
- Decode：`10.16.1.42 / 13.13.1.42:9349`
- Transfer/Proxy：`8998 / 8000`，网卡 `ens61f0np0`
- 测试：`input=512, output=32, concurrency=1, num_prompts=1`
- 结果：`PASS`，P/D、runtime、RDMA transfer、Proxy 和 stop 均成功
- Prefill readiness：约 210 秒
- Decode readiness：约 271 秒

| 指标 | 结果 |
|---|---:|
| QPS | 0.54 |
| Output throughput | 17.33 tok/s |
| Total throughput | 294.56 tok/s |
| Mean TTFT | 266.02 ms |
| Mean TPOT | 50.97 ms |
| ITL P99 | 558.69 ms |

历史成功产物使用了旧 `abbr=glm47pd-smoke`，路径保持不变，不迁移文件。后续测试统一使用姓名缩写 `--abbr lzh`。

此前 `32768/1024/bs1` 曾触发 Mooncake RDMA transfer timeout，因此仍需使用当前 watchdog 版本重新验证。

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
