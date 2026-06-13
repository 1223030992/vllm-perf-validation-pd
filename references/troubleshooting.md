# 故障排查

## 调用被拒绝

未知参数或参数值缺失会在 SSH、state 和容器操作前被拒绝：

```text
PD_INVOCATION_REJECTED=1
TASK_STARTED=0
FAILURE_STAGE=parse_arguments
ARGUMENT_ERROR=...
ARGUMENT_HINT=...
```

该输出表示没有启动任务。当前 Claude 对话中不得自动修正并重试，也不得调用 `show_state.sh`。应修正提示词中的唯一命令块后，在新的明确授权下重新执行。

## Preflight 分类

| reason | 含义 |
|---|---|
| `node_unreachable` | 节点无法连接或超时 |
| `ssh_auth_failed` | SSH 认证失败 |
| `docker_unavailable` | Docker CLI 或 daemon 不可用 |
| `docker_permission_denied` | 当前用户无 Docker 权限 |
| `docker_image_missing` | 指定镜像在节点不存在 |
| `docker_image_id_mismatch` | P/D 镜像 ID 不一致或不符合预期 |
| `host_model_path_missing` | Host 模型目录不存在；使用 `configure_pd_deployment.sh --update-existing --host-model-path <PATH>` 更新个人 deployment，或临时传 `run_pd_task.sh --host-model-path <PATH>`，不要编辑共享 profile |
| `required_script_missing` | profile 指向的 P/D/Proxy 脚本不存在 |
| `port_in_use` | 服务端口已被占用 |

网卡或 HCA 未发现只输出 warning，不阻塞任务。

## Mooncake runtime

- `mooncake_transfer_engine_missing`：镜像未预装 Mooncake 且未传 wheel。
- `mooncake_install_failed`：受控 wheel 安装失败。
- 先核对 wheel 与 Python ABI、系统和 DTK 版本是否匹配。

## KV Cache 容量

`kv_cache_capacity_insufficient` 表示模型原生最大序列长度或配置的 `max_model_len` 超过当前 KV cache 容量。报告会记录模型最大长度、所需/可用 KV cache GiB 和 vLLM 估算上限。优先降低 `--max-model-len`；只有确认设备显存仍有余量时才提高 `--gpu-memory-utilization`。后续 all-reduce 或 worker terminated 日志不覆盖该第一根因。

## Proxy

readiness 依次检查 listener、P/D upstream、Prefill bootstrap 和真实 1-token PD 请求。常见分类：

- `proxy_listener_timeout`
- `prefill_upstream_unreachable`
- `decode_upstream_unreachable`
- `prefill_bootstrap_unreachable`
- `proxy_upstream_not_ready`
- `proxy_smoke_http_error`
- `proxy_smoke_timeout`

Proxy 日志出现 `Inited prefiller` 和 `All prefiller instances are ready` 表示 bootstrap 初始化完成。

## RDMA 与 benchmark

以下信号会触发 watchdog 快速失败：

- `transport retry counter exceeded`
- `Sync batch data transfer timeout`
- `Mooncake transfer engine returned -1`
- `pulling kv_caches ... failed`

对应分类通常为 `mooncake_rdma_transfer_timeout` 或 `mooncake_kv_pull_failed`。使用 `--keep-containers-on-failure` 可保留后期失败现场。

## 状态污染

当前版本每次使用唯一 invocation id，并在初始化 state 时执行 reset。若看到旧 failure 字段，优先确认远端 Skill 是否已同步到当前仓库版本。
