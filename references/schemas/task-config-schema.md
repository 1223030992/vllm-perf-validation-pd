# Task Config Schema

PD task 是一个小型 YAML 文件，会和 `pd.profile` 指向的 profile 合并。字段名保持英文，说明使用中文。

## 示例

```yaml
task:
  name: glm47_vllm018_mooncake_1p1d_custom
  run_id: auto
  owner: liuzhihuan
  description: GLM-4.7 vLLM 0.18.1 Mooncake 1P1D custom smoke

mode: pd

image:
  name: 10.16.1.152:5000/jenkins/model_test_env/vllm:0.18.1-ubuntu22.04-dtk26.04-py3.10-20260608-1434
  pull_policy: if_not_present

pd:
  profile: references/pd-profiles/glm47-vllm018-mooncake.yaml
  backend: mooncake_vllm018
  topology: 1p1d
  network:
    ifname: ens61f0np0
    nccl_ib_hca: mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_8,mlx5_9
  roles:
    prefill:
      node: 10.16.1.1
      service_ip: 13.13.1.1
      vllm_host_ip: 13.13.1.1
      port: 9348
      transfer_port: 8998
    decode:
      node: 10.16.1.44
      service_ip: 13.13.1.44
      vllm_host_ip: 13.13.1.44
      port: 9349
  proxy:
    node_role: prefill
    port: 8000
  service_defaults:
    tp: 8
    gpu_range: "0,1,2,3,4,5,6,7"
    quantization: slimquant_marlin
    dtype: bfloat16
    max_num_batched_tokens: 16384
    speculative_config: '{"method": "mtp", "num_speculative_tokens": 2, "quantization": "slimquant_marlin"}'
    compilation_config: '{"cudagraph_mode": "PIECEWISE"}'
    extra_args: ""
    prefill_extra_args: ""
    decode_extra_args: ""

test:
  mode: custom
  params:
    input_lens: [512]
    output_len: 32
    concurrencies: [1]
    num_prompts_mult: 1
    request_rate: null
    percentiles: "50,95,99"
```

## 支持范围

- `mode`：当前 PD 任务只使用 `pd`
- `pd.backend`：当前只支持 `mooncake_vllm018`
- `pd.topology`：当前只支持 `1p1d`
- `test.mode`：当前支持 `custom` 或 `pchit`

## 关键字段

- `pd.roles.prefill.node`：prefill 控制节点，通常是 SSH 入口 IP
- `pd.roles.prefill.service_ip`：proxy 访问 prefill vLLM 的服务 IP
- `pd.roles.prefill.vllm_host_ip`：prefill 容器内的 `VLLM_HOST_IP`
- `pd.roles.prefill.port`：prefill vLLM 端口
- `pd.roles.prefill.transfer_port`：Mooncake prefill transfer port，默认复现值为 `8998`
- `pd.roles.decode.node`：decode 控制节点，通常是 SSH 入口 IP
- `pd.roles.decode.service_ip`：proxy 访问 decode vLLM 的服务 IP
- `pd.roles.decode.vllm_host_ip`：decode 容器内的 `VLLM_HOST_IP`
- `pd.roles.decode.port`：decode vLLM 端口
- `pd.proxy.port`：Mooncake proxy 端口，默认 `8000`
- `pd.network.ifname`：`NCCL_SOCKET_IFNAME` / `GLOO_SOCKET_IFNAME`
- `pd.network.nccl_ib_hca`：`NCCL_IB_HCA`

## 命令行覆盖

`run_pd_task.sh` 支持不改 YAML 直接覆盖节点和网络：

- `--prefill-node`
- `--prefill-service-ip`
- `--prefill-vllm-host-ip`
- `--decode-node`
- `--decode-service-ip`
- `--decode-vllm-host-ip`
- `--prefill-port`
- `--decode-port`
- `--prefill-transfer-port`
- `--proxy-port`
- `--network-ifname`
- `--nccl-ib-hca`

## vLLM 额外参数

仅在明确需要时使用：

- `pd.service_defaults.extra_args`
- `pd.service_defaults.prefill_extra_args`
- `pd.service_defaults.decode_extra_args`

默认不要加入 `--profiler-config`。如果后续要启用 profiler，应通过显式配置或命令参数启用，并在实测记录中说明。
