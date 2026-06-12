# 故障排查

## Preflight 分类

| reason | 含义 |
|---|---|
| `node_unreachable` | 节点无法连接或超时 |
| `ssh_auth_failed` | SSH 认证失败 |
| `docker_unavailable` | Docker CLI 或 daemon 不可用 |
| `docker_permission_denied` | 当前用户无 Docker 权限 |
| `docker_image_missing` | 指定镜像在节点不存在 |
| `docker_image_id_mismatch` | P/D 镜像 ID 不一致或不符合预期 |
| `host_model_path_missing` | Host 模型目录不存在 |
| `required_script_missing` | profile 指向的 P/D/Proxy 脚本不存在 |
| `port_in_use` | 服务端口已被占用 |

网卡或 HCA 未发现只输出 warning，不阻塞任务。

## Mooncake runtime

- `mooncake_transfer_engine_missing`：镜像未预装 Mooncake 且未传 wheel。
- `mooncake_install_failed`：受控 wheel 安装失败。
- 先核对 wheel 与 Python ABI、系统和 DTK 版本是否匹配。

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
