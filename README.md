# vLLM Perf Validation Single

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

一个 **Claude Code Skill**，赋予 Claude 在单节点 DCU/GPU 上执行 vLLM 推理性能验证的能力。你只需用自然语言描述测试需求，Claude 会自动调用内置的状态机脚本，完成从环境检查到报告生成的全流程。

> 💡 这是一个 Claude Skill 项目 —— 脚本由 Claude 自动调度执行，你无需手动拼接长命令。

## 使用方式

安装本 Skill 后，在对话中直接告诉 Claude 你的意图，例如：

- "帮我跑一下 GLM-4.7-W8A8 的冒烟测试"
- "检查 10.16.1.9 节点环境，然后启动 GLM-5-W8A8 服务做 full benchmark"
- "依次测试这三个模型，每个模型结束后释放资源再启动下一个"
- "新增一个模型配置，模型路径在 /public/opendas/DL_DATA/llm-models/xxx"

Claude 会读取 `SKILL.md` 中的规则和 `task.yaml` 的配置，严格按照状态机流程（Preflight → 创建容器 → 启动服务 → 等待就绪 → 性能测试 → 停止服务 → 生成报告）执行，并在高风险操作前向你确认。

## 功能特性

- **多模式执行**：支持 Single（单模型独占）、Serial（串行多模型）、Parallel（双模型并行）
- **状态机驱动**：Claude 按固定状态流转，确保每一步都可审计、可恢复
- **模型配置管理**：通过对话即可注册新模型，Claude 自动生成 profile、示例任务和命名映射
- **灵活测试参数**：支持自定义输入长度、输出长度、并发数、百分位数等
- **服务健康检查**：Claude 自动通过 `/v1/models` 发现模型 ID，确保测试准确性
- **产物隔离**：Skill 文件与运行产物分目录存放，避免互相污染

## 目录结构

```text
vllm-perf-validation-single/
├── SKILL.md                      # Skill 核心规则（Claude 的行为指南）
├── task.yaml                     # 默认任务配置（Claude 读取的测试参数）
├── README.md                     # 本文件
│
├── references/                   # 领域知识（Claude 按需加载）
│   ├── conventions.md            # 命名、端口、MODEL_SHORT 映射约定
│   ├── usage-guide.md            # 面向用户的完整使用文档
│   ├── ops-templates.md          # Docker、服务启动与排障模板
│   ├── profiles/                 # 各模型的默认资源配置（YAML）
│   ├── rules/                    # 执行规则、评测规则、日志分类
│   ├── schemas/                  # task/report 配置结构说明
│   └── examples/                 # single/serial/parallel/custom 示例任务
│
├── scripts/                      # 可执行脚本（Claude 通过绝对路径调用）
│   ├── ops/                      # 核心状态机脚本
│   │   ├── run_single_task.sh    # 单任务自动化入口（Claude 优先调用）
│   │   ├── preflight_node.sh     # 节点环境检查
│   │   ├── create_container.sh   # 创建 Docker 容器
│   │   ├── start_vllm_service.sh # 启动 vLLM 服务
│   │   ├── wait_vllm_ready.sh    # 等待服务就绪
│   │   ├── run_bench.sh          # 执行性能测试
│   │   ├── stop_service.sh       # 停止服务
│   │   ├── render_report.py      # 生成测试报告
│   │   ├── register_model.sh     # 注册新模型（Claude 优先调用）
│   │   ├── show_state.sh         # 查看当前任务状态
│   │   └── version.sh            # 版本信息
│   ├── client-scripts/           # 性能测试客户端脚本
│   │   ├── run_perf_test-full.sh         # 全量测试
│   │   ├── run_perf_test-pchit-control.sh # Prefix Cache 命中率测试
│   │   ├── run_perf_test-engin.sh        # 引擎测试
│   │   └── run_perf_test-custom.sh       # 自定义参数测试
│   └── server-scripts/           # 各模型 vLLM 服务启动脚本
│       ├── run_glm47int8-server.sh   # GLM-4.7-W8A8
│       ├── run_glm4.7-w8a8-server.sh
│       ├── run_glm5-w8a8-server.sh   # GLM-5-W8A8
│       └── run_glm5.1-w8a8-server.sh # GLM-5.1-W8A8
│
└── agents/
    └── openai.yaml               # Codex UI 展示信息与触发策略
```

## 快速开始

### 1. 安装 Skill

将本 Skill 安装到 Claude Code 的 skills 目录中。

### 2. 配置任务

编辑 `task.yaml`，设置目标节点 IP、模型路径、测试参数。Claude 在执行时会读取此配置：

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

### 3. 用自然语言发起测试

在对话中告诉 Claude 你要做什么，例如：

> "帮我跑一下 task.yaml 里配置的冒烟测试"

Claude 会自动调用 `run_single_task.sh`，按状态机逐步完成：环境检查 → 创建容器 → 启动 vLLM 服务 → 等待就绪 → 执行性能测试 → 停止服务 → 生成报告。每一步高风险操作（SSH、创建容器、占用 GPU 等）都会先向你确认。

### 4. 查看结果

测试结束后，报告和 CSV 数据输出到配置的产物目录：

```text
<output_host_root>/
├── work_dirs/    # 工作目录
├── reports/      # 测试报告（Markdown）
└── csvs/         # 性能数据 CSV
```

## 执行模式

在对话中用自然语言指定模式，Claude 会按对应规则执行：

| 模式 | 适用场景 | 对话示例 |
|------|---------|---------|
| `single` | 单模型独占全部 GPU/DCU，冒烟或回归测试 | "帮我跑 GLM-4.7-W8A8 冒烟" |
| `serial` | 多个模型依次执行，每次只跑一个服务 | "依次测试这三个模型：GLM-4.7、GLM-5、GLM-5.1" |
| `parallel` | 两个 4 卡服务同时跑，GPU 不重叠 | "在 0-3 卡跑 GLM-4.7，4-7 卡跑 GLM-5" |

## 新增模型

在对话中告诉 Claude 新模型的信息，Claude 会自动调用 `register_model.sh` 完成注册：

> "新增一个模型：名称 MyModel，简称 mymodel，宿主机路径 /public/opendas/DL_DATA/llm-models/MyModel，容器内路径 /model/MyModel，TP=8，端口 9349"

Claude 会自动生成：
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
