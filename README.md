# vllm-perf-validation-single

GitHub: https://github.com/1223030992/vllm-perf-validation-single

这是一个面向 Claude Code / Codex 的 vLLM 单节点性能验证 skill。它把模型性能测试拆成低自由度 ops 脚本：创建容器、启动服务、等待 `/v1/models`、发现 `served_model_id`、运行 benchmark、停止服务、生成 CSV/JSON/Markdown 报告。

当前重点是单模型 single 流程和新模型接入流程。GLM-4.7 single custom 已稳定；Kimi-K2.5-INT4 已完成 single custom 冒烟；pchit、serial、parallel 仍需要继续实测验证。

## 1. 快速使用方式

推荐使用方式不是手写远端命令，而是把标准化任务描述发给 Claude，让 Claude 只调用本项目的 `scripts/ops/*.sh` 入口。

最小流程：

1. 确认路径：替换用户名、skill 安装目录、模型宿主机路径、产物目录。
2. 新模型先注册：标准化 server script，再注册 profile/example。
3. 测试模型：先 dry-run，再经用户确认执行真实 single custom 或 pchit 测试。

必须遵守：

- 正式入口使用绝对路径，例如 `/public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh`。
- 不推荐相对路径入口、变量块入口或把 dry-run 作为命令前缀注入。
- 不手写远端命令、容器命令、benchmark 命令或 API 探测命令绕过 ops 脚本。
- 不自动删除容器。`docker rm` 必须由用户明确点名容器后再处理。

## 2. 路径替换

README 中示例默认使用用户 `liuzhh8`。其他用户使用前必须替换为自己的环境。

| 路径类型 | 示例 | 说明 |
| --- | --- | --- |
| Git 工作区 | `/public/home/<user>/projects/vllm-perf-validation-single` | 代码仓库位置，给人修改代码用 |
| skill 安装目录 | `/public/home/<user>/.claude/skills/vllm-perf-validation-single` | Claude 实际调用的 skill 目录 |
| 产物目录 | `/public/home/<user>/skilltest/vllm-perf-validation-single` | `state.json`、CSV、报告、日志输出位置 |
| 模型宿主机路径 | `/public/opendas/DL_DATA/llm-models/...` | 计算节点上真实模型目录 |
| 容器内模型路径 | `/model/...`、`/model1/...`、`/model2/...` | Docker 挂载后的容器内路径 |
| Claude 权限配置 | `.claude/settings.local.json` | 需要 allow 本项目 ops 入口 |

如果你的 skill 不是安装在 `/public/home/<user>/.claude/skills/`，所有 Claude 指令里的绝对路径都要同步替换。

建议 allow 的 ops 入口：

- `standardize_server_script.sh`
- `register_model.sh`
- `run_single_task.sh`
- `resume_single_task.sh`
- `show_state.sh`
- 必要时再放行分步诊断脚本，如 `wait_vllm_ready.sh`、`stop_service.sh`

## 3. 项目结构

```text
vllm-perf-validation-single/
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
│   │   ├── glm47int8-test-task.yaml
│   │   ├── glm5int8-test-task.yaml
│   │   ├── kimik25int4-test-task.yaml
│   │   ├── minimaxm25int8-test-task.yaml
│   │   └── ...
│   ├── profiles/
│   │   ├── glm47int8.yaml
│   │   ├── glm5int8.yaml
│   │   ├── kimik25int4.yaml
│   │   ├── minimaxm25int8.yaml
│   │   └── ...
│   ├── rules/
│   │   ├── eval-rules.md
│   │   ├── logging-rules.md
│   │   └── single-node-rules.md
│   └── schemas/
│       └── task.schema.json
└── scripts/
    ├── add-model.sh
    ├── client-scripts/
    │   ├── run_perf_test-custom.sh
    │   ├── run_perf_test-pchit-control.sh
    │   └── ...
    ├── ops/
    │   ├── run_single_task.sh
    │   ├── standardize_server_script.sh
    │   ├── register_model.sh
    │   ├── resume_single_task.sh
    │   ├── pchit_warmup.sh
    │   ├── pchit_log_parser.py
    │   ├── run_bench.sh
    │   ├── wait_vllm_ready.sh
    │   ├── stop_service.sh
    │   ├── render_report.py
    │   └── ...
    └── server-scripts/
        ├── run_glm4.7-w8a8-server.sh
        ├── run_glm5-w8a8-server.sh
        ├── run_glm5.1-w8a8-server.sh
        ├── run_kimik2.5-int4-server.sh
        ├── run_minimax2.5-w8a8.sh
        └── ...
```

### 3.1 顶层文件

| 路径 | 作用 |
| --- | --- |
| `SKILL.md` | Claude/Codex 使用该 skill 的主规则入口 |
| `README.md` | GitHub 用户上手入口，强调如何通过 Claude 调用 |
| `task.yaml` | 默认任务样例 |
| `agents/openai.yaml` | agent/skill 元信息 |

### 3.2 references 模块

| 路径 | 作用 |
| --- | --- |
| `references/profiles/` | 每个模型的 profile，记录路径、端口、TP、精度和 vLLM 参数 |
| `references/examples/` | 每个模型的测试任务示例 |
| `references/conventions.md` | 命名规则、容器名规则、MODEL_SHORT 规则 |
| `references/ops-templates.md` | 常用 ops 调用模板 |
| `references/usage-guide.md` | 更详细的历史使用说明，README 只保留核心内容 |
| `references/rules/` | 单节点、日志、评价规则 |
| `references/schemas/` | 任务配置 schema |

### 3.3 scripts 模块

| 路径 | 作用 |
| --- | --- |
| `scripts/ops/` | Claude 应优先调用的稳定入口，负责状态机和闭环执行 |
| `scripts/server-scripts/` | 每个模型的 vLLM 服务启动脚本 |
| `scripts/client-scripts/` | 容器内 benchmark 客户端脚本 |
| `scripts/add-model.sh` | 旧的新增模型底层生成器，推荐优先使用 `register_model.sh` |

关键 ops 入口：

| 脚本 | 作用 |
| --- | --- |
| `standardize_server_script.sh` | 把新增模型 server script 规范化为统一变量风格 |
| `register_model.sh` | 生成 profile/example，并输出测试 dry-run 命令 |
| `run_single_task.sh` | single 测试主入口，内部串联 preflight/create/start/wait/bench/report/stop |
| `resume_single_task.sh` | readiness timeout 或中断后按 state 继续受控恢复 |
| `pchit_warmup.sh` | pchit 正式测试前的 prefix cache 命中率预热闭环 |
| `run_bench.sh` | 只通过 ops 入口执行 benchmark，不直接调用 client 脚本 |
| `render_report.py` | 根据 state 和 CSV 生成 JSON/Markdown 报告 |
| `show_state.sh` | 输出最终路径、状态和核心指标 |

## 4. 功能状态

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| single custom GLM-4.7-W8A8 | stable | 主链路已稳定跑通 |
| single custom Kimi-K2.5-INT4 | smoke passed | 10.16.1.9 冒烟通过 |
| GLM-5-W8A8 | integrated | 已接入脚本和 profile，仍需继续回归 |
| GLM-5.1 | integrated | 脚本已修正为 `slimquant_marlin`，仍需继续回归 |
| MiniMax-M2.5-W8A8 | registered | 已注册，真实冒烟待补充 |
| 新模型标准化注册 | usable | 已支持标准化脚本、注册 profile/example、输出 dry-run |
| pchit | new / needs validation | 已实现预热闭环，需要真实节点验证 |
| serial / parallel | experimental | 有规则和示例，未标记稳定 |

## 5. 现有模型支持

| 模型 | MODEL_SHORT | 端口 | TP | 模型精度 | 状态 |
| --- | --- | ---: | ---: | --- | --- |
| GLM-4.7-W8A8 | `glm47int8` | 9348 | 8 | int8 | stable |
| GLM-5-W8A8 | `glm5int8` | 9349 | 8 | int8 | integrated |
| GLM-5.1-Channel-INT8 | `glm51int8` | 9350 | 8 | int8 | integrated |
| MiniMax-M2.5-W8A8 | `minimaxm25int8` | 9352 | 8 | int8 | registered |
| Kimi-K2.5-INT4 | `kimik25int4` | 9354 | 8 | int4 | smoke passed |

说明：`model.precision` 表示模型/权重量化精度；`service.vllm_params.dtype` 表示计算 dtype；`kv_cache_dtype` 表示 KV cache 精度。Kimi 的模型精度为 `int4`，计算 dtype 为 `bfloat16`，KV cache 为 `fp8_e4m3`。

## 6. 给 Claude 的标准指令

下面模板用于复制给 Claude。模板中 `<user>`、节点、镜像、路径和端口要替换成实际值。

### 6.1 现有模型 profile 模式

如果模型已经在 `references/profiles/` 中注册，优先使用 `--profile <MODEL_SHORT>`。这样 Claude 不需要读取 profile、列目录或手工拼模型路径。

```text
/vllm-perf-validation-single

请只调用一条绝对路径主入口 run_single_task.sh，并使用 --profile <MODEL_SHORT> 自动读取已注册模型信息。

要求：
1. 不要读取 profile 文件。
2. 不要单独执行 preflight。
3. 不要手写远端命令、容器命令、benchmark 命令或 API 探测命令。
4. server script 由 profile 自动解析，必须保持相对路径形式。
5. 先执行 --dry-run；我确认后再执行真实测试。
```

### 6.2 新模型标准化注册

```text
/vllm-perf-validation-single

请为新增模型执行标准化注册流程，不执行真实 SSH/Docker/GPU 测试。

模型信息：
model_name: <MODEL_NAME>
model_short: <MODEL_SHORT>
host_model_path: <HOST_MODEL_PATH>
container_model_path: <CONTAINER_MODEL_PATH>
server_script: /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/server-scripts/<SCRIPT_NAME>
port: <PORT>
tp: <TP>
gpu_range: <GPU_RANGE>
precision: <MODEL_PRECISION>

要求：
1. 只能调用绝对路径入口：
   bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/standardize_server_script.sh ...
   bash /public/home/<user>/.claude/skills/vllm-perf-validation-single/scripts/ops/register_model.sh ...
2. 先执行 standardize_server_script.sh --dry-run，确认 diff。
3. dry-run 无误后正式标准化 server script。
4. 再执行 register_model.sh --dry-run。
5. register_model dry-run 无 WARN 后正式注册。
6. 不手写 profile/example。
7. 输出生成的 profile/example 路径和 run_single_task.sh --dry-run 命令。
```

### 6.3 single custom 冒烟测试

```text
/vllm-perf-validation-single

我授权你执行 single custom 冒烟测试。

节点：<NODE>
镜像：<IMAGE>
model_name: <MODEL_NAME>
model_short: <MODEL_SHORT>
host_model_path: <HOST_MODEL_PATH>
container_model_path: <CONTAINER_MODEL_PATH>
server_script: scripts/server-scripts/<SCRIPT_NAME>
port: <PORT>
tp: <TP>
gpu_range: <GPU_RANGE>

测试参数：
input_lens=512
output_len=32
concurrencies=1
num_prompts_mult=1
percentiles=50,95,99
timeout=2400

要求：
1. 只能调用绝对路径主入口 run_single_task.sh。
2. 不单独 preflight，不绕过 ops 脚本。
3. 服务启动后必须通过 /v1/models 发现 served_model_id。
4. benchmark 必须使用 served_model_id。
5. 结束后停止容器，生成 state.json、CSV、JSON、Markdown 报告并汇总路径。
6. ops 失败则停止并汇报，不手写补救命令。
7. 禁止 docker rm。
```

### 6.4 pchit 90% 目标命中率测试

```text
/vllm-perf-validation-single

我授权你执行 single pchit 测试。

节点：<NODE>
镜像：<IMAGE>
model_name: <MODEL_NAME>
model_short: <MODEL_SHORT>
host_model_path: <HOST_MODEL_PATH>
container_model_path: <CONTAINER_MODEL_PATH>
server_script: scripts/server-scripts/<SCRIPT_NAME>
port: <PORT>
tp: <TP>
gpu_range: <GPU_RANGE>

正式测试：
input_len=32768
output_len=1024
batches=1,2,3,4,5,6,7,8
concurrency_multiplier=1
pc_hit_target=90

预热策略：
warmup_cache_hit_rates=92,95
warmup_concurrency_multiplier=4
pc_hit_tolerance=1
pc_hit_timeout=1800
pc_hit_interval=60

要求：
1. 只能调用绝对路径主入口 run_single_task.sh。
2. test_mode 必须为 pchit。
3. 先预热，解析 server log 的 PC 实时命中率。
4. observed >= pc_hit_target - pc_hit_tolerance 后再执行正式 benchmark。
5. 92% 预热不达标再尝试 95%；仍不达标则失败并汇报。
6. 不手写远端命令、容器命令、benchmark 命令或 API 探测命令。
```

### 6.5 GLM-5.1 pchit 实测模板

下面是 GLM-5.1-Channel-INT8 在 `10.16.1.9` 上测试 pchit 的推荐 prompt。重点是让 Claude 直接调用 `run_single_task.sh --profile glm51int8`，不要再读取 profile 或拼 `/public2` 路径。

```text
/vllm-perf-validation-single

我授权你执行 GLM-5.1-Channel-INT8 single pchit 测试。

要求：
1. 只能调用一条绝对路径主入口：
   bash /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh ...
2. 必须使用 --profile glm51int8 自动读取模型信息。
3. 不要读取 profile 文件，不要 ls/grep，不要单独 preflight。
4. 不要手写远端命令、容器命令、benchmark 命令或 API 探测命令。
5. 服务启动后必须通过 /v1/models 发现 served_model_id，benchmark 必须使用 served_model_id。
6. pchit 必须先预热，解析 server log 的 PC 实时命中率。
7. observed >= pc_hit_target - pc_hit_tolerance 后再执行正式 benchmark。
8. 92% 预热不达标再尝试 95%；仍不达标则失败并汇报。
9. 结束后停止容器，生成 state.json、CSV、JSON、Markdown 报告并汇总路径。
10. 禁止 docker rm。

测试参数：
node: 10.16.1.9
image: 10.16.1.152:5000/jenkins/model_test_env/vllm:0.15.1-ubuntu22.04-dtk26.04-py3.10-20260515-1239
profile: glm51int8
test_mode: pchit
gpu_range: 0,1,2,3,4,5,6,7
input_len: 2048
output_len: 1024
batches: 1,2,3,4,5,6,7,8
concurrency_multiplier: 1
pc_hit_target: 90
warmup_cache_hit_rates: 92,95
warmup_concurrency_multiplier: 4
pc_hit_tolerance: 1
pc_hit_timeout: 1800
pc_hit_interval: 60
timeout: 2400
```

Claude 应执行的唯一命令形态如下，真实执行前可先加 `--dry-run`：

```text
bash /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh \
  --node 10.16.1.9 \
  --image 10.16.1.152:5000/jenkins/model_test_env/vllm:0.15.1-ubuntu22.04-dtk26.04-py3.10-20260515-1239 \
  --profile glm51int8 \
  --gpu-range 0,1,2,3,4,5,6,7 \
  --test-mode pchit \
  --input-len 2048 \
  --output-len 1024 \
  --batches 1,2,3,4,5,6,7,8 \
  --concurrency-multiplier 1 \
  --pc-hit-target 90 \
  --warmup-cache-hit-rates 92,95 \
  --warmup-concurrency-multiplier 4 \
  --pc-hit-tolerance 1 \
  --pc-hit-timeout 1800 \
  --pc-hit-interval 60 \
  --timeout 2400 \
  --assume-yes
```

### 6.6 SERVICE_TIMEOUT 后恢复

```text
/vllm-perf-validation-single

上一次 run_single_task.sh 在 readiness 或后续阶段中断。
请只使用 resume_single_task.sh 按 state 恢复，不创建新容器，不重新启动服务，不手写补救命令。

state: <STATE_JSON_PATH>

要求：
1. 只能调用绝对路径 resume_single_task.sh。
2. 如果是 pchit，必须先继续 pchit warmup，再进入正式 benchmark。
3. 最终停止服务并生成 JSON/Markdown 报告。
```

## 7. pchit 流程说明

pchit 与 custom 最大差异在于正式测试前必须先预热 prefix cache，并从 server log 观测实际 PC 命中率。

推荐策略：

- 正式目标：`pc_hit_target=90`
- 达标条件：`observed >= target - tolerance`，默认 `tolerance=1`，即 89% 及以上可认为达标
- 预热配置：优先 `92%`，不达标再尝试 `95%`
- 正式请求数：`num_prompts = concurrency * 1`
- 预热请求数：`num_prompts = concurrency * 4`

例如正式测试 `32k input / 1024 output / bs 1..8 / 目标 90%`，可以先用同样输入输出和 batch 组合，以 `92,95` 的 cache hit 配置、4 倍请求量预热。达到目标下限后停止预热并进入正式 benchmark。

这里 92/95 是预热配置，不是最终验收目标；最终验收目标仍是 90%。

## 8. 已验证案例

### 8.1 GLM-4.7-W8A8 stable baseline

- 模式：single custom
- input/output：512/32
- 状态：preflight、create、start、wait、bench、stop、report 主链路稳定
- 适合作为新环境验证 baseline

### 8.2 Kimi-K2.5-INT4 single custom 冒烟

- 节点：`10.16.1.9`
- 端口：`9354`
- served_model_id：`/model/Kimi-K2.5`
- 状态：PASS，容器已停止，端口已释放
- ready 耗时：约 1200 秒
- QPS：0.98 req/s
- 输出 token 吞吐：31.33 tok/s
- 总 token 吞吐：532.65 tok/s

示例产物路径：

- `state.json`：`/public/home/liuzhh8/skilltest/vllm-perf-validation-single/work_dirs/Kimi-K2.5-INT4-custom-20260522-lzh-agent-test-0522-kimik25int4-2540/state.json`
- CSV：`/public/home/liuzhh8/skilltest/vllm-perf-validation-single/work_dirs/Kimi-K2.5-INT4-custom-20260522-lzh-agent-test-0522-kimik25int4-2540/csvs/custom/all.csv`
- JSON 报告：`/public/home/liuzhh8/skilltest/vllm-perf-validation-single/reports/kimik25int4-custom-20260522-lzh-agent-test-0522-kimik25int4-2540.json`
- Markdown 报告：`/public/home/liuzhh8/skilltest/vllm-perf-validation-single/reports/kimik25int4-custom-20260522-lzh-agent-test-0522-kimik25int4-2540.md`

补充：`10.16.1.4` 上一次尝试因 GPU 显存已有占用，进程退出 `137`，不视为 Kimi 注册流程失败。

## 9. 常见问题处理

| 问题 | 推荐处理 |
| --- | --- |
| Claude 权限询问过多 | 使用绝对路径入口，并在 `settings.local.json` allow 对应 ops 脚本 |
| server script 端口不对 | 标准化脚本必须使用 `--port ${PORT}`，避免落到默认 8000 |
| benchmark 404 | 必须用 `/v1/models` 返回的 `served_model_id` 作为 bench model |
| readiness 超时 | 使用 `resume_single_task.sh --state <state.json>` 继续，不手写补救命令 |
| 容器名冲突 | 不自动删除容器；由用户确认后处理或换规范容器名 |
| pchit 不达标 | 检查 server log 是否有可解析 PC 命中率；92 不达标再 95；仍不达标则停止 |
| CSV 缺失 | 不生成虚假报告；应让 ops 脚本返回 `bench_csv_missing` |
| 精度记录混淆 | `model.precision` 记录权重量化精度；`dtype` 记录计算精度；`kv_cache_dtype` 单独记录 |

## 10. 开发和验证

本地静态检查建议：

```text
python -m py_compile scripts/ops/register_model.py scripts/ops/standardize_server_script.py scripts/ops/pchit_log_parser.py scripts/ops/render_report.py scripts/ops/show_state.py scripts/ops/update_state.py
```

真实节点测试需要用户单独授权。默认开发和文档修改不执行 SSH/Docker/GPU 操作。
