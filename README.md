# vLLM Perf Validation Single

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

单节点 vLLM 推理性能验证工具。支持在 DCU/GPU 节点上执行可审计、可复现的 vLLM 性能测试，覆盖冒烟测试、回归测试、Prefix Cache 命中率测试、Prefill 测试等场景。

## 功能特性

- **多模式执行**：支持 Single（单模型独占）、Serial（串行多模型）、Parallel（双模型并行）三种模式
- **状态机驱动**：Preflight → 创建容器 → 启动服务 → 等待就绪 → 性能测试 → 停止服务 → 生成报告，全流程自动化
- **模型配置管理**：内置 `register_model.sh` 一键注册新模型，自动生成 profile、示例任务和命名映射
- **灵活测试参数**：支持自定义输入长度、输出长度、并发数、百分位数等参数
- **服务健康检查**：自动通过 `/v1/models` 发现模型 ID，确保测试准确性
- **产物隔离**：Skill 文件与运行产物分目录存放，避免污染

## 目录结构

```text
vllm-perf-validation-single/
├── SKILL.md                      # Skill 入口文件（流程规则与引用导航）
├── task.yaml                     # 默认任务配置
├── README.md                     # 本文件
│
├── references/                   # 领域规则与参考文档
│   ├── conventions.md            # 命名、端口、MODEL_SHORT 映射约定
│   ├── usage-guide.md            # 用户使用技术文档
│   ├── ops-templates.md          # Docker、服务启动与排障模板
│   ├── profiles/                 # 模型默认配置（YAML）
│   ├── rules/                    # 执行、评测、日志规则
│   ├── schemas/                  # task/report 配置结构说明
│   └── examples/                 # single/serial/parallel/custom 示例
│
├── scripts/                      # 可执行脚本
│   ├── ops/                      # 核心状态机脚本
│   │   ├── run_single_task.sh    # 单任务自动化入口（推荐）
│   │   ├── preflight_node.sh     # 节点环境检查
│   │   ├── create_container.sh   # 创建 Docker 容器
│   │   ├── start_vllm_service.sh # 启动 vLLM 服务
│   │   ├── wait_vllm_ready.sh    # 等待服务就绪
│   │   ├── run_bench.sh          # 执行性能测试
│   │   ├── stop_service.sh       # 停止服务
│   │   ├── render_report.py      # 生成测试报告
│   │   ├── register_model.sh     # 注册新模型（推荐入口）
│   │   ├── show_state.sh         # 查看当前状态
│   │   └── version.sh            # 版本信息
│   ├── client-scripts/           # 性能测试客户端脚本
│   │   ├── run_perf_test-full.sh         # 全量测试
│   │   ├── run_perf_test-pchit-control.sh # Prefix Cache 命中率测试
│   │   ├── run_perf_test-engin.sh        # 引擎测试
│   │   └── run_perf_test-custom.sh       # 自定义参数测试
│   └── server-scripts/           # 模型服务启动脚本
│       ├── run_glm47int8-server.sh   # GLM-4.7-W8A8
│       ├── run_glm4.7-w8a8-server.sh
│       ├── run_glm5-w8a8-server.sh   # GLM-5-W8A8
│       └── run_glm5.1-w8a8-server.sh # GLM-5.1-W8A8
│
└── agents/
    └── openai.yaml               # Codex UI 触发配置
```

## 快速开始

### 1. 前置条件

- DCU/GPU 节点（BW1000 或其他兼容设备）
- Docker 环境
- 模型文件已部署到节点

### 2. 配置任务

编辑 `task.yaml`，设置目标节点 IP、模型路径、测试参数：

```yaml
task:
  name: vllm_perf_single_glm47_smoke
  owner: your_name
  description: "GLM-4.7-W8A8 单节点冒烟测试"

mode: single

node:
  ip: 10.16.1.9
  dcu_type: BW1000
  gpu_count: 8

models:
  - name: GLM-4.7-W8A8
    model_short: glm47int8
    host_model_path: /path/to/model
    container_model_path: /model/GLM-4.7-W8A8
    tp: 8
    port: 9348

test:
  mode: custom
  params:
    input_lens: [512]
    output_len: 32
    concurrencies: [1]
```

### 3. 执行测试

```bash
bash scripts/ops/run_single_task.sh
```

该脚本会自动完成：环境检查 → 创建容器 → 启动 vLLM 服务 → 等待就绪 → 执行性能测试 → 停止服务 → 生成报告。

### 4. 查看结果

测试报告和 CSV 数据将输出到配置的产物目录：

```text
<output_host_root>/
├── work_dirs/    # 工作目录
├── reports/      # 测试报告
└── csvs/         # 性能数据 CSV
```

## 执行模式

| 模式 | 说明 |
|------|------|
| `single` | 一个模型独占全部 GPU/DCU，适用于冒烟测试和回归测试 |
| `serial` | 多个模型按顺序依次执行，每次只运行一个服务 |
| `parallel` | 两个 4 卡服务同时运行，需使用互不重叠的 `GPU_RANGE` |

## 新增模型

使用 `register_model.sh` 一键注册新模型：

```bash
bash scripts/ops/register_model.sh \
  --model-name "MyModel" \
  --model-short "mymodel" \
  --host-path /path/to/model \
  --container-path /model/MyModel \
  --tp 8 \
  --port 9349
```

该命令会自动生成：
- `references/profiles/<MODEL_SHORT>.yaml` — 模型配置
- `references/examples/<MODEL_SHORT>-test-task.yaml` — 示例任务
- 更新 `references/conventions.md` — 命名映射

## 路径约定

| 用途 | 宿主机路径 | 容器内路径 |
|------|-----------|-----------|
| Skill 文件 | `/public/home/liuzhh8/.claude/skills/vllm-perf-validation-single` | `/mnt/.claude/skills/vllm-perf-validation-single` |
| 运行产物 | `/public/home/liuzhh8/skilltest/vllm-perf-validation-single` | `/mnt/skilltest/vllm-perf-validation-single` |
| 主模型目录 | `/public/opendas/DL_DATA/llm-models` | `/model` |

## 已支持模型

- GLM-4.7-W8A8（量化）
- GLM-5-W8A8（量化）
- GLM-5.1-W8A8（量化）

## 安全规则

- 高风险操作（SSH、创建/删除容器、占用 GPU/端口、拉取镜像）需先确认
- 不得在未授权情况下执行 `docker rm`
- 只能使用用户或 `task.yaml` 指定的镜像
- 服务启动后必须以 `/v1/models` 返回的模型 ID 为准进行测试
