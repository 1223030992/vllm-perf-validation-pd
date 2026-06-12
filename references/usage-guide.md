# 使用指南

## 唯一入口

PD 起服、检测、benchmark、失败保留和清理都通过：

```text
scripts/ops/run_pd_task.sh
```

远端 skill 同步正确时，输出应包含当前 `PD_SCRIPT_VERSION` 和 `SELECTED_IMAGE`。

真实测试直接调用一次主入口。不要自动先执行 dry-run，也不要运行 `ls`、`cat`、`--help`、额外文档读取或报告扫描。主入口在成功和失败结束前都会自动输出紧凑 state 摘要；成功后不再调用 `show_state.sh`。

`--abbr` 表示用户姓名缩写。例如 `liuzhh8` 使用 `--abbr lzh`，不要使用模型名或任务名代替。

## Custom 参数

支持以下 CLI 覆盖，优先级为 CLI > YAML > 内置默认值：

```text
--input-lens
--output-len
--concurrencies
--num-prompts-mult
--request-rate
--percentiles
--bench-timeout
--mooncake-dest-device-affinity
```

前六个测试数据参数只允许用于 `custom`，传给 `pchit` 会在 SSH 前失败；`--bench-timeout` 和 destination affinity 可用于两种模式。正式 32k example 为：

```text
references/examples/glm47-vllm018-mooncake-1p1d-custom-32k1k-bs1.yaml
```

`--bench-timeout` 默认 3600 秒，适用于单个 custom case 或整个 pchit 调用。destination affinity 默认值来自 GLM4.7 profile，为 `1`。

## Mooncake 传输诊断

P/D 就绪后从服务日志记录 protocol、检测到的 HCA、GID index 和监听地址。`--nccl-ib-hca` 只设置 NCCL 环境变量，Mooncake 仍会自动发现设备；发现额外 HCA 时仅输出 warning。

benchmark 每 30 秒更新 `test.heartbeat_at` 和 `test.elapsed_seconds`。检测到 KV pull `-1`、同步传输超时或 RDMA retry exceeded 时会终止请求，并分类为：

- `mooncake_kv_pull_failed`
- `mooncake_rdma_transfer_timeout`
- `bench_timeout`
- `bench_exit_nonzero`

正式调用不得追加 shell 管道、后台符号或外部 timeout。自动后台任务只能等待原任务完成。

## Proxy 检测

Proxy 运行在 Prefill 容器并绑定 `127.0.0.1`。readiness 使用禁用环境代理的 Python HTTP 客户端依次检查：

- `pd.proxy.listener`
- `pd.proxy.upstream.prefill`
- `pd.proxy.upstream.decode`
- `pd.proxy.bootstrap`
- `pd.proxy.smoke`

`503` 代表 prefiller 尚未初始化，继续重试。其他 4xx 立即失败；5xx、连接错误和请求超时在总超时内重试。

常见失败原因：

- `proxy_listener_timeout`
- `prefill_upstream_unreachable`
- `decode_upstream_unreachable`
- `prefill_bootstrap_unreachable`
- `proxy_upstream_not_ready`
- `proxy_smoke_http_error`
- `proxy_smoke_timeout`
- `proxy_process_exited`

## 保留失败现场

默认失败路径会停止 P/D，但不会执行 `docker rm`。显式传入：

```bash
--keep-containers-on-failure
```

仅在 `start_proxy`、`wait_proxy` 或 `run_bench` 失败时保留容器。其他更早阶段仍自动清理。

受控清理命令：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --cleanup-state /public/home/<user>/skilltest/vllm-perf-validation-pd/work_dirs/<run>/state.json \
  --user <user> --abbr <abbr>
```

主入口只从 state 读取节点、容器名和端口，不接受手写清理目标。

## 状态与产物

`show_state.sh` 输出 P/D role 状态、Mooncake 拓扑、transfer 状态、benchmark 当前 case/heartbeat、Proxy 分阶段结果、cleanup 策略以及 CSV/报告路径。

读取标准 Host 绝对路径时，`show_state.sh` 会从 `/public/home/<user>/...` 自动推导用户；远程读取或非标准路径仍需显式传 `--user`。

custom 模式只输出通用吞吐和延迟指标。`PCHIT_EFFECTIVE_PCT`、`PCHIT_BEST_SLA_CONCURRENCY` 等字段只允许在 `test.mode=pchit` 时出现。

真实成功必须同时满足：

- P/D `READY`
- Proxy smoke `READY`
- benchmark CSV 存在且 case 通过
- P/D 正常停止
- 输出 `PD_TASK_DONE=1`

## 新模型接入

新模型先标准化 P/D/proxy 脚本，再注册 profile 和默认 smoke example。两个入口均为本地-only，不连接 SSH、Docker 或 GPU：

```bash
bash scripts/ops/standardize_pd_server_scripts.sh \
  --model-short <model-short> \
  --prefill-source <p_server.sh> \
  --decode-source <d_server.sh> \
  --proxy-source <run_proxy.sh> \
  --dry-run
```

标准化器提取模型路径、TP、quantization、dtype、batch 参数和模型专属 export，并生成 `scripts/pd-server/<model-short>/`。确认 diff 后去掉 `--dry-run`；覆盖已有文件必须传 `--overwrite`。

```bash
bash scripts/ops/register_pd_model.sh \
  --profile-id <model-vllm018-mooncake> \
  --model-name <MODEL_NAME> --model-short <model-short> \
  --host-model-path <HOST_MODEL_PATH> --container-model-path <CONTAINER_MODEL_PATH> \
  --precision <precision> --tp <tp> --gpu-range <range> \
  --quantization <type> --dtype <dtype> \
  --base-config references/examples/glm47-vllm018-mooncake-1p1d-custom.yaml \
  --user <user> --abbr <abbr> --dry-run
```

注册器从 base config 复制 deployment 层，生成模型 profile 和 `512/32/bs1 custom` example。模型 profile 不保存节点、service IP、端口、网卡或 HCA。当前只允许注册 `mooncake_vllm018 + 1p1d`，xpyd 尚未实现。
