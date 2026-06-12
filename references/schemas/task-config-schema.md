# Task Config Schema

PD task YAML 会与 `pd.profile` 指向的 profile 合并。当前只支持 `mooncake_vllm018 + 1p1d`。

运行时 CLI 可以覆盖 custom 参数：`--input-lens`、`--output-len`、`--concurrencies`、`--num-prompts-mult`、`--request-rate`、`--percentiles`。优先级为 CLI > YAML > 内置默认值，pchit 不接受这些 custom 覆盖。

## 核心结构

```yaml
task:
  name: glm47_vllm018_mooncake_1p1d_custom
mode: pd

pd:
  profile: references/pd-profiles/glm47-vllm018-mooncake.yaml
  server_scripts:
    prefill: scripts/pd-server/glm47-w8a8/p_server.sh
    decode: scripts/pd-server/glm47-w8a8/d_server.sh
    proxy: scripts/pd-server/glm47-w8a8/run_proxy.sh
  runtime:
    mooncake_wheel: null
    mooncake_dest_device_affinity: true
  network:
    ifname: ens61f0np0
    nccl_ib_hca: mlx5_2,mlx5_3
  roles:
    prefill:
      node: 10.16.1.1
      service_ip: 13.13.1.1
      vllm_host_ip: 13.13.1.1
      port: 9348
      transfer_port: 8998
    decode:
      node: 10.16.1.42
      service_ip: 10.16.1.42
      vllm_host_ip: 10.16.1.42
      port: 9349
  proxy:
    node_role: prefill
    port: 8000

test:
  mode: custom
```

example 和 `task.yaml` 不定义 `image.name`。真实镜像必须通过主入口的 `--image` 显式提供。

## Runtime 字段

- `pd.runtime.mooncake_wheel`：可选 HTTP(S) URL 或容器内绝对路径；默认空。
- `pd.runtime.mooncake_dest_device_affinity`：布尔值，GLM4.7 默认 `true`。
- 空值表示镜像必须预装可导入的 `mooncake.engine`。
- 非空值表示在 P/D 新容器中受控安装，然后验证依赖。

## 命令行覆盖

- `--image`：必填镜像引用。
- `--image-id`：可选短或完整镜像 ID；`--image-digest` 是兼容别名。
- `--mooncake-wheel`
- `--host-model-path`
- `--container-model-path`
- `--prefill-node` / `--prefill-service-ip` / `--prefill-vllm-host-ip`
- `--decode-node` / `--decode-service-ip` / `--decode-vllm-host-ip`
- `--prefill-port` / `--decode-port` / `--prefill-transfer-port` / `--proxy-port`
- `--network-ifname` / `--nccl-ib-hca` / `--mooncake-dest-device-affinity`
- `--ready-timeout` / `--proxy-timeout` / `--proxy-request-timeout` / `--bench-timeout` / `--interval`

`--nccl-ib-hca` 只配置 NCCL，不限制 Mooncake Transfer Engine 的 HCA 自动发现。

`--image-prefix` 只控制容器名后缀，不是镜像覆盖参数。

## 模型与服务默认值

GLM4.7 profile 默认模型路径：

```text
/public/opendas/DL_DATA/llm-models/GLM-4.7-W8A8
->
/model/GLM-4.7-W8A8
```

额外 vLLM 参数使用 `pd.service_defaults.extra_args`、`prefill_extra_args` 和 `decode_extra_args`。默认不加入 profiler。

`pd.server_scripts.prefill`、`decode` 和 `proxy` 必须由 profile 明确定义。主入口不提供任何模型专属兜底路径，缺少字段时必须在 SSH 前失败。

新增模型应通过 `standardize_pd_server_scripts.sh` 和 `register_pd_model.sh` 生成脚本、profile 和 example，不要复制 GLM4.7 profile 后手工遗留模型参数。
