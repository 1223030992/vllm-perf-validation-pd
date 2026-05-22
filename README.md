# vllm-perf-validation-single

GitHub: [1223030992/vllm-perf-validation-single](https://github.com/1223030992/vllm-perf-validation-single)

这是一个用于单节点 vLLM 性能验证的 Claude Code/Codex skill。当前最成熟的路径是 single custom 单模型测试闭环：preflight、创建容器、启动服务、通过 `/v1/models` 发现 `served_model_id`、benchmark、停止容器、生成 `state.json`、CSV、JSON 报告和 Markdown 报告。

项目后续重点是新模型扩展、serial 串行模式、parallel 并行模式和更多测试模式的深度验证。本文档是 GitHub 用户的主入口；`references/usage-guide.md` 保留为更长的历史/补充说明。

## 1. 功能状态

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| GLM-4.7-W8A8 single custom | 稳定 | 已能稳定完成主链路，适合作为回归基线。 |
| Kimi-K2.5-INT4 single custom | 已冒烟通过 | 2026-05-22 在 `10.16.1.9` 通过最小冒烟。 |
| GLM-5-W8A8 | 已接入，待继续验证 | 已有标准化脚本、profile/example；首次 ready 可能较慢，建议 `--timeout 3600`。 |
| GLM-5.1-Channel-INT8 | 已接入，待继续回归 | 脚本已按 `slimquant_marlin` 修正，已有执行经验，仍需继续回归。 |
| MiniMax-M2.5-W8A8 | 已注册，待真实冒烟 | 已支持标准化和注册，真实 single custom 仍需补测。 |
| 新模型注册 | 基本可用 | 支持标准化 server script、注册 profile/example、生成 smoke dry-run 命令。 |
| 非 GLM 模型正式执行 | 待扩展验证 | Kimi 已通过；Qwen、DeepSeek、MiniMax 等仍需更多实测。 |
| serial / parallel | 实验性 | 已有规则和示例，但未作为稳定功能承诺。 |
| pchit / full / engin | 实验性 | client 脚本存在，仍需系统验证。 |

## 2. 现有模型支持

| 模型 | MODEL_SHORT | 精度 | 默认端口 | TP | 宿主机模型路径 | 容器模型路径 | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| GLM-4.7-W8A8 | `glm47int8` | int8 | 9348 | 8 | `/public/opendas/DL_DATA/llm-models/glm4.7/GLM-4.7-W8A8` | `/model/GLM-4.7-W8A8` | single custom 稳定 |
| GLM-5-W8A8 | `glm5int8` | int8 | 9349 | 8 | `/public/opendas/DL_DATA/llm-models/vllm-w8a8-models/GLM-5-W8A8` | `/model/vllm-w8a8-models/GLM-5-W8A8` | 已接入，待继续验证 |
| GLM-5.1-Channel-INT8 | `glm51int8` | int8 | 9350 | 8 | `/public4/share/GLM-5.1-Channel-INT8` | `/model1/GLM-5.1-Channel-INT8` | 已接入，待继续回归 |
| MiniMax-M2.5-W8A8 | `minimaxm25int8` | int8 | 9352 | 8 | `/public4/opendas/DL_DATA/llm-models/MiniMax-M2.5-W8A8` | `/model2/llm-models/MiniMax-M2.5-W8A8` | 已注册，待真实冒烟 |
| Kimi-K2.5-INT4 | `kimik25int4` | int4 | 9354 | 8 | `/public/opendas/DL_DATA/llm-models/Kimi-K2.5` | `/model/Kimi-K2.5` | single custom 冒烟通过 |

精度字段含义：

- `model.precision`：模型/权重量化精度，例如 `int4`、`int8`、`fp8`、`bf16`。
- `service.vllm_params.dtype`：计算 dtype，例如 Kimi 使用 `bfloat16`。
- `service.vllm_params.kv_cache_dtype`：KV cache dtype，例如 Kimi 使用 `fp8_e4m3`。

Kimi 的模型目录名没有包含 `INT4`，但 server script 文件名为 `run_kimik2.5-int4-server.sh`，注册器应据此推导 `model.precision: "int4"`。如模型名和脚本名都无法表达精度，注册时应显式传 `--precision`。

## 3. 目录结构

下面展示源码和手工维护文件，忽略 `.git/`、`tmp/`、`__pycache__/`、日志、报告、work_dirs 等生成物。

```text
vllm-perf-validation-single/
├── .gitignore
├── README.md
├── SKILL.md
├── task.yaml
├── agents/
│   └── openai.yaml
├── references/
│   ├── conventions.md
│   ├── ops-templates.md
│   ├── usage-guide.md
│   ├── examples/
│   │   ├── custom-test-task.yaml
│   │   ├── engin-test-task.yaml
│   │   ├── glm47int8-test-task.yaml
│   │   ├── glm5int8-test-task.yaml
│   │   ├── kimik25int4-test-task.yaml
│   │   ├── minimaxm25int8-test-task.yaml
│   │   ├── parallel-test-task.yaml
│   │   ├── pchit-test-task.yaml
│   │   └── serial-test-task.yaml
│   ├── profiles/
│   │   ├── glm47int8.yaml
│   │   ├── glm51int8.yaml
│   │   ├── glm5int8.yaml
│   │   ├── kimik25int4.yaml
│   │   └── minimaxm25int8.yaml
│   ├── rules/
│   │   ├── deployment-rules.md
│   │   ├── evaluation-rules.md
│   │   ├── log-classification.md
│   │   └── single-node-rules.md
│   └── schemas/
│       ├── report-schema.md
│       └── task-config-schema.md
└── scripts/
    ├── add-model.sh
    ├── client-scripts/
    │   ├── run_perf_test-custom.sh
    │   ├── run_perf_test-engin.sh
    │   ├── run_perf_test-full.sh
    │   └── run_perf_test-pchit-control.sh
    ├── ops/
    │   ├── create_container.sh
    │   ├── preflight_node.sh
    │   ├── recover_single_task.sh
    │   ├── register_model.py
    │   ├── register_model.sh
    │   ├── render_report.py
    │   ├── resume_single_task.sh
    │   ├── run_bench.sh
    │   ├── run_single_task.sh
    │   ├── show_state.py
    │   ├── show_state.sh
    │   ├── standardize_server_script.py
    │   ├── standardize_server_script.sh
    │   ├── start_vllm_service.sh
    │   ├── stop_service.sh
    │   ├── update_state.py
    │   ├── version.sh
    │   └── wait_vllm_ready.sh
    └── server-scripts/
        ├── run_glm4.7-w8a8-server.sh
        ├── run_glm47int8-server.sh
        ├── run_glm5-w8a8-server.sh
        ├── run_glm5.1-w8a8-server.sh
        ├── run_kimik2.5-int4-server.sh
        └── run_minimax2.5-w8a8.sh
```

## 4. 权限配置

建议在 Claude Code/Codex 的 `settings.local.json` 中允许只读访问 skill，并允许固定 ops 入口。这样可以减少 dry-run 或正式入口的重复询问。

```json
{
  "permissions": {
    "allow": [
      "Read(/public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/**)",
      "Read(/public2/home/liuzhh8/.claude/skills/vllm-perf-validation-single/**)",
      "Bash(bash /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/ops/standardize_server_script.sh *)",
      "Bash(bash /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/ops/register_model.sh *)",
      "Bash(bash /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh *)",
      "Bash(bash /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/ops/resume_single_task.sh *)",
      "Bash(bash /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/ops/recover_single_task.sh *)",
      "Bash(bash /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/ops/show_state.sh *)"
    ],
    "deny": [
      "Bash(*docker rm*)",
      "Bash(*docker system prune*)",
      "Bash(*docker image prune*)",
      "Bash(*rm -rf*)"
    ]
  }
}
```

执行原则：

- 正式流程优先只调用绝对路径入口。
- 不使用变量块入口。
- 不使用 `cd` 后再调用相对路径。
- 不通过环境变量前缀控制 dry-run，统一使用脚本参数 `--dry-run`。
- 不手写 SSH、Docker、vLLM benchmark、API 探测命令绕过 ops。
- ops 脚本失败时停止并汇报，不临时绕过。
- 默认不执行镜像拉取；镜像不存在时先向用户确认。
- 默认不删除容器；需要删除时必须由用户明确点名容器并授权。

## 5. 新模型注册最小流程

新增模型固定四步：

1. `standardize_server_script.sh --dry-run` 看标准化 diff。
2. 去掉 `--dry-run` 正式标准化 server script。
3. `register_model.sh --dry-run` 看推导结果和 smoke dry-run 命令。
4. 去掉 `--dry-run` 正式注册 profile/example/conventions。

### 5.1 标准化 server script dry-run

以 Kimi 为例：

```bash
bash /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/ops/standardize_server_script.sh \
  --model-name Kimi-K2.5-INT4 \
  --model-short kimik25int4 \
  --server-script /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/server-scripts/run_kimik2.5-int4-server.sh \
  --container-model-path /model/Kimi-K2.5 \
  --port 9354 \
  --tp 8 \
  --gpu-range 0,1,2,3,4,5,6,7 \
  --dry-run
```

标准化后的 server script 应满足：

- 有 `MODEL_PATH`、`TP_SIZE`、`GPU_RANGE`、`PORT`、`LOG_DIR` 默认值块。
- `HIP_VISIBLE_DEVICES` 使用 `${GPU_RANGE}`。
- `vllm serve` 使用 `"${MODEL_PATH}"`。
- `--port` 使用 `${PORT}`。
- `-tp` 使用 `${TP_SIZE}`。
- 无条件清理编译缓存改为 `CLEAR_COMPILE_CACHE=1` 时才清理。
- 保留模型专属性能环境变量和 vLLM 参数。

### 5.2 正式标准化

dry-run diff 无误后执行：

```bash
bash /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/ops/standardize_server_script.sh \
  --model-name Kimi-K2.5-INT4 \
  --model-short kimik25int4 \
  --server-script /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/server-scripts/run_kimik2.5-int4-server.sh \
  --container-model-path /model/Kimi-K2.5 \
  --port 9354 \
  --tp 8 \
  --gpu-range 0,1,2,3,4,5,6,7
```

### 5.3 注册模型 dry-run

```bash
bash /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/ops/register_model.sh \
  --model-name Kimi-K2.5-INT4 \
  --model-short kimik25int4 \
  --host-model-path /public/opendas/DL_DATA/llm-models/Kimi-K2.5 \
  --container-model-path /model/Kimi-K2.5 \
  --server-script scripts/server-scripts/run_kimik2.5-int4-server.sh \
  --port 9354 \
  --tp 8 \
  --gpu-range 0,1,2,3,4,5,6,7 \
  --precision int4 \
  --dry-run
```

期望输出至少包含：

```text
MODEL_NAME=Kimi-K2.5-INT4
MODEL_SHORT=kimik25int4
MODEL_PRECISION=int4
PRECISION=int4
COMPUTE_DTYPE=bfloat16
KV_CACHE_DTYPE=fp8_e4m3
PORT=9354
TP=8
GPU_RANGE=0,1,2,3,4,5,6,7
DRY_RUN=1, no files written.
```

### 5.4 正式注册

```bash
bash /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/ops/register_model.sh \
  --model-name Kimi-K2.5-INT4 \
  --model-short kimik25int4 \
  --host-model-path /public/opendas/DL_DATA/llm-models/Kimi-K2.5 \
  --container-model-path /model/Kimi-K2.5 \
  --server-script scripts/server-scripts/run_kimik2.5-int4-server.sh \
  --port 9354 \
  --tp 8 \
  --gpu-range 0,1,2,3,4,5,6,7 \
  --precision int4
```

正式注册生成：

- `references/profiles/<MODEL_SHORT>.yaml`
- `references/examples/<MODEL_SHORT>-test-task.yaml`
- 更新 `references/conventions.md`

不要手写 profile/example。

## 6. 模型测试最小流程

测试固定两步：

1. 先执行 `run_single_task.sh --dry-run`。
2. 用户确认后去掉 `--dry-run`，真实执行。

### 6.1 single custom dry-run

```bash
bash /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh \
  --node 10.16.1.9 \
  --image 10.16.1.254:5000/jenkins/model_test_env/vllm:daily-20260428-1927 \
  --model-name Kimi-K2.5-INT4 \
  --model-short kimik25int4 \
  --host-model-path /public/opendas/DL_DATA/llm-models/Kimi-K2.5 \
  --container-model-path /model/Kimi-K2.5 \
  --server-script scripts/server-scripts/run_kimik2.5-int4-server.sh \
  --port 9354 \
  --tp 8 \
  --gpu-range 0,1,2,3,4,5,6,7 \
  --test-mode custom \
  --input-lens 512 \
  --output-len 32 \
  --concurrencies 1 \
  --num-prompts-mult 1 \
  --percentiles 50,95,99 \
  --timeout 2400 \
  --dry-run
```

### 6.2 用户确认后真实执行

```bash
bash /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh \
  --node 10.16.1.9 \
  --image 10.16.1.254:5000/jenkins/model_test_env/vllm:daily-20260428-1927 \
  --model-name Kimi-K2.5-INT4 \
  --model-short kimik25int4 \
  --host-model-path /public/opendas/DL_DATA/llm-models/Kimi-K2.5 \
  --container-model-path /model/Kimi-K2.5 \
  --server-script scripts/server-scripts/run_kimik2.5-int4-server.sh \
  --port 9354 \
  --tp 8 \
  --gpu-range 0,1,2,3,4,5,6,7 \
  --test-mode custom \
  --input-lens 512 \
  --output-len 32 \
  --concurrencies 1 \
  --num-prompts-mult 1 \
  --percentiles 50,95,99 \
  --timeout 2400 \
  --assume-yes
```

真实执行完成后应输出或生成：

- `state.json`
- `csvs/custom/all.csv`
- JSON 报告
- Markdown 报告
- 服务日志
- `STOPPED` 状态和端口释放结果

## 7. 已验证案例

### 7.1 GLM-4.7-W8A8 稳定基线

GLM-4.7-W8A8 single custom 是当前最稳定路径。建议用它验证环境、镜像和 skill 主流程是否正常。

```bash
bash /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh \
  --node 10.16.1.9 \
  --image 10.16.1.254:5000/jenkins/model_test_env/vllm:daily-20260428-1927 \
  --model-name GLM-4.7-W8A8 \
  --model-short glm47int8 \
  --host-model-path /public/opendas/DL_DATA/llm-models/glm4.7/GLM-4.7-W8A8 \
  --container-model-path /model/GLM-4.7-W8A8 \
  --server-script scripts/server-scripts/run_glm47int8-server.sh \
  --port 9348 \
  --tp 8 \
  --gpu-range 0,1,2,3,4,5,6,7 \
  --test-mode custom \
  --input-lens 512 \
  --output-len 32 \
  --concurrencies 1 \
  --num-prompts-mult 1 \
  --percentiles 50,95,99 \
  --assume-yes
```

### 7.2 Kimi-K2.5-INT4 冒烟结果

2026-05-22，Kimi-K2.5-INT4 在 `10.16.1.9` 冒烟通过。

| 项 | 值 |
| --- | --- |
| 状态 | PASS，最终 STOPPED |
| 端口 | 9354 |
| served_model_id | `/model/Kimi-K2.5` |
| QPS | 0.98 req/s |
| 输出 token 吞吐 | 31.33 tok/s |
| 总 token 吞吐 | 532.65 tok/s |
| ready 耗时 | 约 1200s |

产物路径示例：

| 类型 | 路径 |
| --- | --- |
| state.json | `/public/home/liuzhh8/skilltest/vllm-perf-validation-single/work_dirs/Kimi-K2.5-INT4-custom-20260522-lzh-agent-test-0522-kimik25int4-2540/state.json` |
| CSV | `/public/home/liuzhh8/skilltest/vllm-perf-validation-single/work_dirs/Kimi-K2.5-INT4-custom-20260522-lzh-agent-test-0522-kimik25int4-2540/csvs/custom/all.csv` |
| JSON 报告 | `/public/home/liuzhh8/skilltest/vllm-perf-validation-single/reports/kimik25int4-custom-20260522-lzh-agent-test-0522-kimik25int4-2540.json` |
| Markdown 报告 | `/public/home/liuzhh8/skilltest/vllm-perf-validation-single/reports/kimik25int4-custom-20260522-lzh-agent-test-0522-kimik25int4-2540.md` |

同一次测试前，`10.16.1.4` 上的尝试退出 `137`，当时 GPU 显存已被占用，不视为模型注册流程失败。稳定结论以 `10.16.1.9` 结果为准。

## 8. 新模型命名规则

`MODEL_SHORT` 只使用小写字母和数字，避免破坏容器命名。

通用格式：

```text
<family><version><size><precision>
```

规则：

- version 去掉点号：`2.5` -> `25`。
- size 写成 `b<size>`：`35B` -> `b35`。
- `W8A8` / `INT8` -> `int8`。
- `INT4` / `W4A8` / `W4A16` -> `int4`。
- `FP8` / `W8A16` -> `fp8`。
- bf16 不加后缀，除非需要显式区分。

示例：

| 模型名 | MODEL_SHORT |
| --- | --- |
| `GLM-4.7-W8A8` | `glm47int8` |
| `GLM-5-W8A8` | `glm5int8` |
| `GLM-5.1-Channel-INT8` | `glm51int8` |
| `MiniMax-M2.5-W8A8` | `minimaxm25int8` |
| `Kimi-K2.5-INT4` | `kimik25int4` |
| `Qwen3.5-35B` | `qwen35b35` |
| `Qwen3.5-35B-W8A8` | `qwen35b35int8` |
| `DeepSeek-R1-Distill-Qwen-32B-W8A8` | `dsr1distillqwenb32int8` |

非 GLM 模型不默认 TP8。注册器优先从 server script 推导 TP；推导失败时必须显式传 `--tp`。如果推导或传入 `TP=2` 且未传 `--gpu-range`，默认 GPU 范围应为 `0,1`。

## 9. 故障处理

| 问题 | 处理方式 |
| --- | --- |
| 权限询问反复出现 | 使用绝对路径 ops 入口，并在 `settings.local.json` 加 allow 规则。 |
| `standardize_server_script.sh` 参数缺失 | 该脚本必须传 `--model-name`、`--server-script`、`--container-model-path`、`--port`、`--tp`、`--gpu-range`。 |
| profile 精度错误 | 区分模型精度和计算 dtype；必要时注册时显式传 `--precision`。 |
| 非 GLM 缺少端口 | 显式传 `--port`，注册器不会自动分配。 |
| Qwen TP 被误设为 8 | 非 GLM 不默认 TP8；从脚本推导失败时显式传 `--tp`。 |
| `SERVICE_PORT_MISMATCH` | server script 的实际监听端口与期望端口不同，先标准化脚本。 |
| `SERVICE_TIMEOUT` | 使用 `resume_single_task.sh --state <STATE>` 继续受控恢复，不绕过 ops。 |
| 容器名冲突 | 不自动删除容器；由用户明确确认处理方式。 |
| benchmark 404 | 必须使用 `/v1/models` 返回的 `served_model_id`，不要用猜测的模型名。 |
| 退出 137 | 通常是资源不足或进程被杀；先检查节点 GPU 显存占用，再换节点或清理占用。 |

恢复入口示例：

```bash
bash /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/ops/resume_single_task.sh \
  --state /public/home/liuzhh8/skilltest/vllm-perf-validation-single/work_dirs/<WORK_DIR>/state.json \
  --dry-run
```

## 10. 给 Claude/Codex 的最小化提示模板

### 10.1 新模型注册

```text
/vllm-perf-validation-single

请为新增模型 <MODEL_NAME> 执行标准化注册流程，不执行 SSH/Docker/GPU 操作。

模型信息：
model_name: <MODEL_NAME>
model_short: <MODEL_SHORT>
host_model_path: <HOST_MODEL_PATH>
container_model_path: <CONTAINER_MODEL_PATH>
server_script: /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/server-scripts/<SCRIPT_NAME>
port: <PORT>
tp: <TP>
gpu_range: <GPU_RANGE>
precision: <MODEL_PRECISION>

要求：
1. 只能调用绝对路径入口 standardize_server_script.sh 和 register_model.sh。
2. 先 standardize_server_script.sh --dry-run，再正式标准化。
3. 再 register_model.sh --dry-run，无 WARN 后正式注册。
4. 不手写 profile/example。
5. 不执行真实 SSH/Docker/GPU 测试。
6. 输出 profile/example 路径和 run_single_task.sh --dry-run 命令。
```

### 10.2 single custom 冒烟测试

```text
/vllm-perf-validation-single

我授权你使用 vllm-perf-validation-single skill，在 <NODE> 节点测试 <MODEL_NAME> 模型。

镜像：<IMAGE>
模式：single
测试模式：custom
host_model_path: <HOST_MODEL_PATH>
container_model_path: <CONTAINER_MODEL_PATH>
service_script: <SERVICE_SCRIPT>
端口：<PORT>
TP：<TP>
GPU_RANGE: <GPU_RANGE>
测试组合：
input_lens=512
output_len=32
concurrencies=1
num_prompts_mult=1
percentiles=50,95,99

要求：
1. 只能调用绝对路径主入口 run_single_task.sh。
2. 不单独 preflight，不绕过 ops。
3. 服务启动后必须通过 /v1/models 发现 served_model_id。
4. benchmark 必须使用 served_model_id。
5. 测试结束后停止容器，生成 state.json、CSV、JSON 报告和 Markdown 报告。
6. 如果 ops 脚本失败，停止并汇报。
7. 禁止 docker rm。
```

## 11. 开发与本地检查

本地修改后至少执行：

```bash
python -m py_compile scripts/ops/register_model.py scripts/ops/standardize_server_script.py
```

建议回归：

```bash
python scripts/ops/register_model.py \
  --model-name Kimi-K2.5-INT4 \
  --model-short kimik25int4 \
  --host-model-path /public/opendas/DL_DATA/llm-models/Kimi-K2.5 \
  --container-model-path /model/Kimi-K2.5 \
  --server-script scripts/server-scripts/run_kimik2.5-int4-server.sh \
  --port 9354 \
  --tp 8 \
  --gpu-range 0,1,2,3,4,5,6,7 \
  --dry-run
```

期望：`MODEL_PRECISION=int4`，`COMPUTE_DTYPE=bfloat16`，`KV_CACHE_DTYPE=fp8_e4m3`。
