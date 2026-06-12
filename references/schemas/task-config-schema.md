# 配置字段说明

推荐使用三层配置，不在仓库 example 中写真实节点。

## Model profile

```yaml
model:
  name: <MODEL_NAME>
  model_short: <MODEL_SHORT>
  host_model_path: <HOST_MODEL_PATH>
  container_model_path: <CONTAINER_MODEL_PATH>
  precision: <PRECISION>
pd:
  backend: mooncake_vllm018
  topology: 1p1d
  server_scripts:
    prefill: scripts/pd-server/<model-short>/p_server.sh
    decode: scripts/pd-server/<model-short>/d_server.sh
    proxy: scripts/pd-server/<model-short>/run_proxy.sh
  runtime:
    mooncake_wheel: null
    mooncake_dest_device_affinity: true
  service_defaults:
    tp: 8
    gpu_range: "0,1,2,3,4,5,6,7"
    quantization: <QUANTIZATION>
    dtype: bfloat16
```

## Deployment

```yaml
deployment:
  id: <DEPLOYMENT_ID>
pd:
  network:
    ifname: <IFNAME>
    nccl_ib_hca: <HCA_LIST>
  roles:
    prefill:
      node: <P_NODE>
      service_ip: <P_SERVICE_IP>
      vllm_host_ip: <P_SERVICE_IP>
      port: 9348
      transfer_port: 8998
    decode:
      node: <D_NODE>
      service_ip: <D_SERVICE_IP>
      vllm_host_ip: <D_SERVICE_IP>
      port: 9349
  proxy:
    node_role: prefill
    port: 8000
```

网卡和 HCA 探测仅告警。节点、service IP 和 `VLLM_HOST_IP` 缺失时在 SSH 前失败。

## Test preset

Custom：

```yaml
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

PCHIT：

```yaml
test:
  mode: pchit
  params:
    input_len: 32768
    output_len: 1024
    batches: [1, 2, 3, 4, 5, 6, 7, 8]
    pc_hit_target: 90
    pchit_benchmark_mode: fixed
    ttft_sla_ms: 5000
    tpot_sla_ms: 50
    sla_stat: mean
```

## 合并优先级

```text
CLI > legacy --config > test preset > deployment > model profile > default
```

真实镜像必须通过 `--image` 提供。新模型使用 `onboard_pd_model.sh` 接入，不复制已有 GLM profile。
