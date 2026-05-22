# vllm-perf-validation-single

GitHub: [1223030992/vllm-perf-validation-single](https://github.com/1223030992/vllm-perf-validation-single)

这是一个面向 Claude Code/Codex 的 vLLM 单节点性能验证 skill。用户用自然语言说明模型、节点、镜像和测试目标，Claude 只调用 `scripts/ops/*.sh` 的固定入口完成 preflight、容器创建、服务启动、`/v1/models` 发现、benchmark、停止容器和报告生成。

当前重点：

- 已稳定：GLM-4.7-W8A8 single custom 主链路。
- 已冒烟：Kimi-K2.5-INT4 single custom。
- 本轮新增：pchit 目标命中率预热闭环(待测试)。
- 待深测：serial、parallel、full、engin、更多非 GLM 模型。

## 1. 快速理解路径

这个项目使用时通常涉及四类路径，不要混在一起：

| 路径类型 | 示例 | 说明 |
| --- | --- | --- |
| Git 工作区 | `/path/to/vllm-perf-validation-single` | 你 clone 或编辑代码的目录。 |
| skill 安装目录 | `/public/home/liuzhh8/.claude/skills/vllm-perf-validation-single` | Claude 实际调用的 skill 目录。README 中的 `liuzhh8` 需要替换成你的用户名。 |
| 运行产物目录 | `/public/home/liuzhh8/skilltest/vllm-perf-validation-single` | `state.json`、CSV、报告、服务日志输出目录。 |
| 模型宿主机目录 | `/public/opendas/DL_DATA/llm-models/...` | 目标计算节点上真实存在的模型目录。 |

迁移给其他用户时，至少替换：

- `settings.local.json` 中的 `Read(...)` 和 `Bash(...)` allow 路径。
- task/profile 中的 `skill_host_root`、`output_host_root`。
- 每个模型的 `host_model_path`。
- 如果容器挂载不是 `/public/home/<user>:/mnt`，还要同步调整容器内 skill 和产物路径。

## 2. 功能状态

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| GLM-4.7-W8A8 single custom | 稳定 | 适合作为环境和主链路基线。 |
| Kimi-K2.5-INT4 single custom | 已冒烟通过 | 2026-05-22 在 `10.16.1.9` 通过。 |
| pchit 90% 目标命中率 | 新增验证中 | 已规划为“预热达标后正式测试”的受控流程。 |
| GLM-5-W8A8 | 已接入，待继续验证 | 首次 ready 可能较慢，建议更长 timeout。 |
| GLM-5.1-Channel-INT8 | 已接入，待继续回归 | 使用 `slimquant_marlin`。 |
| MiniMax-M2.5-W8A8 | 已注册，待真实冒烟 | 已有标准化脚本和 profile/example。 |
| serial / parallel | 实验性 | 有示例和规则，尚未标为稳定。 |

## 3. 已支持模型

| 模型 | MODEL_SHORT | 精度 | 端口 | TP | 状态 |
| --- | --- | --- | --- | --- | --- |
| GLM-4.7-W8A8 | `glm47int8` | int8 | 9348 | 8 | stable |
| GLM-5-W8A8 | `glm5int8` | int8 | 9349 | 8 | 已接入，继续验证 |
| GLM-5.1-Channel-INT8 | `glm51int8` | int8 | 9350 | 8 | 已接入，继续回归 |
| MiniMax-M2.5-W8A8 | `minimaxm25int8` | int8 | 9352 | 8 | 已注册，待冒烟 |
| Kimi-K2.5-INT4 | `kimik25int4` | int4 | 9354 | 8 | single custom 已冒烟 |

精度字段约定：

- `model.precision` 是模型/权重量化精度，例如 `int4`、`int8`。
- `service.vllm_params.dtype` 是计算 dtype，例如 `bfloat16`。
- `service.vllm_params.kv_cache_dtype` 是 KV cache dtype，例如 `fp8_e4m3`。

Kimi 的模型目录名没有写 `INT4`，但 server script 文件名包含 `int4`，注册器应推导为 `model.precision: int4`。遇到类似情况，新增模型时建议显式告诉 Claude：模型精度、计算 dtype、KV cache dtype、TP 和 GPU 范围。

## 4. 推荐权限配置

在 Claude Code/Codex 的 `settings.local.json` 中允许固定入口，避免 dry-run 和正式流程反复询问。把 `liuzhh8` 替换为你的用户名。

```json
{
  "permissions": {
    "allow": [
      "Read(/public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/**)",
      "Bash(bash /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/ops/standardize_server_script.sh *)",
      "Bash(bash /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/ops/register_model.sh *)",
      "Bash(bash /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/ops/run_single_task.sh *)",
      "Bash(bash /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/scripts/ops/resume_single_task.sh *)",
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

## 5. 给 Claude 的标准指令

### 5.1 新模型标准化注册

把下面文本发给 Claude。Claude 应先 dry-run 标准化，再正式标准化，再 dry-run 注册，最后正式注册；不要手写 profile/example。

```text
/vllm-perf-validation-single

请为新增模型 <MODEL_NAME> 执行标准化注册流程，不执行 SSH/Docker/GPU 操作。

模型信息：
model_name: <MODEL_NAME>
model_short: <MODEL_SHORT>
host_model_path: <HOST_MODEL_PATH>
container_model_path: <CONTAINER_MODEL_PATH>
server_script: /public/home/<USER>/.claude/skills/vllm-perf-validation-single/scripts/server-scripts/<SCRIPT_NAME>
port: <PORT>
tp: <TP>
gpu_range: <GPU_RANGE>
precision: <MODEL_PRECISION>
compute_dtype: <DTYPE>
kv_cache_dtype: <KV_CACHE_DTYPE>

要求：
1. 只能调用 standardize_server_script.sh 和 register_model.sh 的绝对路径入口。
2. 先 standardize_server_script.sh --dry-run，再正式标准化。
3. 再 register_model.sh --dry-run，无 WARN 后正式注册。
4. 不手写 profile/example。
5. 不执行真实 SSH/Docker/GPU 测试。
6. 输出 profile/example 路径和 run_single_task.sh --dry-run 冒烟命令。
```

### 5.2 single custom 冒烟测试

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
2. 不单独 preflight，不手写 ssh/docker/vllm bench/curl。
3. 服务启动后必须通过 /v1/models 发现 served_model_id。
4. benchmark 必须使用 served_model_id。
5. 结束后停止容器，生成 state.json、CSV、JSON 报告和 Markdown 报告。
6. ops 脚本失败则停止并汇报。
7. 禁止 docker rm。
```

### 5.3 pchit 90% 目标命中率测试

这个流程的关键点：正式目标是 PC 实际命中率达到 90%；92/95% 是预热配置，不是正式目标。

```text
/vllm-perf-validation-single

请使用 vllm-perf-validation-single skill，在 <NODE> 节点对 <MODEL_NAME> 执行 single pchit 测试。

模型和资源：
镜像：<IMAGE>
host_model_path: <HOST_MODEL_PATH>
container_model_path: <CONTAINER_MODEL_PATH>
service_script: <SERVICE_SCRIPT>
端口：<PORT>
TP：<TP>
GPU_RANGE: <GPU_RANGE>

正式测试：
input_len=32768
output_len=1024
pc_hit_target=90
batches=1,2,3,4,5,6,7,8
concurrency_multiplier=1

预热：
warmup_cache_hit_rates=92,95
warmup_concurrency_multiplier=4
pc_hit_tolerance=1
pc_hit_timeout=1800
pc_hit_interval=30

要求：
1. 只能调用绝对路径主入口 run_single_task.sh。
2. 不单独 preflight，不手写 ssh/docker/vllm bench/curl。
3. 服务启动后必须通过 /v1/models 发现 served_model_id。
4. 先用 92% 预热；server log 实际 PC 命中率达到 90% 目标容差后停止预热。
5. 若 92% 预热不达标，再使用 95% 预热。
6. 达标后执行正式 pchit benchmark，正式请求数为 1*并发数。
7. benchmark 必须使用 served_model_id。
8. 测试结束后停止容器，生成 state.json、CSV、JSON 报告和 Markdown 报告。
9. 如果 ops 脚本失败，停止并汇报，不允许绕过。
10. 禁止 docker rm。
```

### 5.4 SERVICE_TIMEOUT 后恢复

```text
/vllm-perf-validation-single

上一次 run_single_task.sh 在 SERVICE_TIMEOUT / WAITING_READY 后停止。请只使用 resume_single_task.sh 继续恢复。

state: <STATE_JSON_PATH>

要求：
1. 不创建新容器。
2. 不重新启动服务。
3. 继续 wait_ready；如果是 pchit 模式，先完成 pchit warmup，再 benchmark。
4. benchmark 后停止容器并重新生成报告。
5. 不手写 ssh/docker/vllm bench/curl。
```

## 6. 实际案例

### GLM-4.7 baseline

GLM-4.7-W8A8 是当前 stable baseline。新环境先跑它，可以确认镜像、节点、路径、容器和报告链路是否正常。

### Kimi-K2.5-INT4 冒烟

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

`10.16.1.4` 上曾出现退出 137，当时 GPU 显存已占用，不视为注册流程失败。稳定结论以 `10.16.1.9` 为准。

## 7. 故障处理

| 问题 | 处理方式 |
| --- | --- |
| 权限弹窗太多 | 使用绝对路径入口，并在 `settings.local.json` 增加 allow。 |
| 路径不对 | 先确认 Git 工作区、skill 安装目录、产物目录、模型目录分别是什么。 |
| pchit 解析不到命中率 | 需要补充 server log 中 PC 命中率样例，调整解析正则。 |
| pchit 预热超时 | 增大 `pc_hit_timeout`，或把 `pc_hit_tolerance` 从 1 放宽到 2。 |
| benchmark 404 | 必须使用 `/v1/models` 返回的 `served_model_id`。 |
| 容器名冲突 | 不自动 `docker rm`；由用户明确处理旧容器。 |
| 退出 137 | 通常是资源不足或进程被杀；先换空闲节点或释放显存。 |

详细历史说明和更长参数示例见 `references/usage-guide.md`。
