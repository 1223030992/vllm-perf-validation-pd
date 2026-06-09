# 约定

本文件定义 vLLM 性能验证 Skill 的命名规范和约定。

---

## MODEL_SHORT 映射表

| 模型全名 | MODEL_SHORT | 说明 |
|----------|-------------|------|
| GLM-4.7-W8A8 | glm47int8 | GLM-4.7 W8A8 量化 |
| GLM-4.7-Channel-INT8 | glm47int8 | GLM-4.7 Channel INT8（等同于 W8A8） |
| GLM-5.1-Channel-INT8 | glm51int8 | GLM-5.1 Channel INT8 |
| GLM-5-W8A8 | glm5int8 | GLM-5 W8A8 量化 |
| GLM-4.7-W8A16 | glm47fp8 | GLM-4.7 W8A16 FP8 |
| GLM-4.7-Channel-FP8 | glm47fp8 | GLM-4.7 Channel FP8（等同于 W8A16） |
| GLM-5.1-Channel-FP8 | glm51fp8 | GLM-5.1 Channel FP8 |
| GLM-4.7（未标精度，默认 bf16） | glm47 | GLM-4.7 bf16 |
| GLM-5.1（未标精度，默认 bf16） | glm51 | GLM-5.1 bf16 |
| MiniMax-M2.5-W8A8 | minimaxm25int8 | int8 |
| Kimi-K2.5-INT4 | kimik25int4 | int4 |

---

## 容器命名格式

```
<container_prefix>-<MMDD>-<MODEL_SHORT>-<IMAGE_PREFIX>

示例：
<container_prefix>-0428-glm47int8-2540

说明：
- lzh: 固定前缀
- agent-test: 固定标识（表示这是 agent skill 测试环境）
- MMDD: 月日，如 0428
- MODEL_SHORT: 模型名简写（见上表）
- IMAGE_PREFIX: 镜像 tag 的前 4 位，如 2540（来自 25401bd053af）
```

---

## 工作路径命名格式

```
<MODEL>-<TEST_MODE>-<DATE>-<CONTAINER_NAME>/

示例：
GLM-4.7-W8A8-serial-full-20260515-<container_prefix>-0428-glm47int8-2540/

说明：
- MODEL: GLM-4.7-W8A8（模型全名）
- TEST_MODE: <执行模式>-<测试模式>，如 serial-full、parallel-custom、single-engin
- DATE: 20260515（月日年）
- CONTAINER_NAME: <container_prefix>-0428-glm47int8-2540
```

---

## 精度类型识别规则

1. **W8A8 / INT8** → `int8` 后缀
2. **W8A16 / FP8** → `fp8` 后缀
3. **未标精度** → 无后缀（默认 bf16）

---

## 端口分配约定

| 模型 | 默认端口 |
|------|----------|
| GLM-4.7 系列 | 9348 |
| GLM-5.1 系列 | 9350 |
| GLM-5 系列 | 9349 |
| MiniMax-M2.5 系列 | 9352 |
| Kimi-K2.5-INT4 系列 | 9354 |

---

## 环境变量标准

server 启动脚本应支持以下标准环境变量：

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| MODEL_PATH | 模型路径 | /model/... |
| TP / TP_SIZE | Tensor Parallel 大小 | 8 |
| GPU_RANGE | GPU 范围 | 0,1,2,3,4,5,6,7 |
| PORT | 服务端口 | 9348 |
| LOG_DIR | 日志目录 | ./logs |

---

## 通用 MODEL_SHORT 推导规则

新增模型优先通过 `scripts/ops/register_model.sh` 注册，不要手写 profile/example。

`MODEL_SHORT` 只允许小写字母和数字，格式为：

```text
<family><version><size><precision>
```

- `version` 去掉点号：`3.5` -> `35`
- `size` 写成 `b<size>`：`35B` -> `b35`
- `precision`：`W8A8` / `INT8` -> `int8`，`FP8` / `W8A16` -> `fp8`，bf16 不加后缀

| 模型名 | 推导 MODEL_SHORT |
|---|---|
| GLM-5-W8A8 | glm5int8 |
| GLM-5.1-Channel-INT8 | glm51int8 |
| GLM-4.7-W8A8 | glm47int8 |
| Qwen3.5-35B | qwen35b35 |
| Qwen3.5-35B-W8A8 | qwen35b35int8 |
| Qwen3-32B | qwen3b32 |
| Qwen2.5-72B-Instruct-W8A8 | qwen25b72int8 |
| DeepSeek-R1-Distill-Qwen-32B | dsr1distillqwenb32 |
| DeepSeek-R1-Distill-Qwen-32B-W8A8 | dsr1distillqwenb32int8 |
| DeepSeek-R1-Distill-Llama-70B | dsr1distillllamab70 |

端口默认值：

- GLM-4.7 系列：`9348`
- GLM-5 系列：`9349`
- GLM-5.1 系列：`9350`
- Qwen、DeepSeek 等非 GLM 模型：推荐显式传 `--port`；未传时按已注册端口最大值 + 1 自动分配

### 非 GLM TP/GPU 推导

- 非 GLM 模型不再默认 `TP=8`。
- 注册时必须显式传 `--tp`，或让 `register_model.sh` 从 server script 中推导：
  - `-tp 2`
  - `--tensor-parallel-size 2`
  - `export TP_SIZE=2`
  - `export TP=2`
- 若推导或传入 `TP=2` 且未传 `--gpu-range`，默认 `GPU_RANGE=0,1`。
- 若无法推导 TP 且用户未传 `--tp`，注册 dry-run 和正式注册都应失败。
- Qwen3.5-35B-W8A8 的 TP2 脚本预期输出：`MODEL_SHORT=qwen35b35int8`、`TP=2`、`GPU_RANGE=0,1`。

宿主机路径到容器路径的默认映射：

- `/public/opendas/DL_DATA/llm-models/...` -> `/model/...`
- `/public4/share/...` -> `/model1/...`
- `/public4/opendas/DL_DATA/...` -> `/model2/...`
