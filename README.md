# vllm-perf-validation-pd

这是面向 vLLM PD 分离服务横向扩展的性能验证项目。当前保留集中式 `custom` / `pchit` 测试能力，并新增 `vllm018 + mooncake + 1P1D` 的 PD 分离起服骨架。

## 当前支持

- 集中式 baseline：继续使用 `scripts/ops/run_single_task.sh`，支持 `custom` 和 `pchit`。
- PD 分离：使用 `scripts/ops/run_pd_task.sh`，第一版正式支持 `pd.backend=mooncake_vllm018`、`pd.topology=1p1d`。
- PD benchmark：`custom` 和固定 PC 命中率 `pchit` 都通过 Mooncake proxy 端口发请求。
- 可扩展配置：模型和 PD 默认参数放在 `references/pd-profiles/`，具体任务放在 `references/examples/`。

## 快速入口

集中式 custom：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_single_task.sh \
  --profile glm47int8 --node <node> --image <image> --test-mode custom \
  --input-lens "512" --output-len 32 --concurrencies "1" \
  --num-prompts-mult 1 --percentiles "50,95,99" \
  --user <user> --abbr <abbr> --assume-yes
```

PD custom dry-run：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --config references/examples/glm47-vllm018-mooncake-1p1d-custom.yaml \
  --user <user> --abbr <abbr> --image-prefix TEST --dry-run
```

PD pchit dry-run：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --config references/examples/glm47-vllm018-mooncake-1p1d-pchit.yaml \
  --user <user> --abbr <abbr> --image-prefix TEST --dry-run
```

## Mooncake Example

真实运行前，把 mooncake example 包放到项目根目录，使下面路径存在：

```text
mooncake/examples/online_serving/disaggregated_serving/mooncake_connector/mooncake_connector_proxy.py
```

preflight 只检查该文件是否存在，不负责安装 wheel 或下载依赖。

## 1P1D 默认复现参数

- Prefill: `kv_role=kv_producer`，服务端口 `9348`。
- Decode: `kv_role=kv_consumer`，服务端口 `9349`。
- Proxy: 默认运行在 prefill 容器，端口 `8000`。
- GLM-4.7: `TP=8`，`HIP_VISIBLE_DEVICES=0,1,2,3,4,5,6,7`，`max_num_batched_tokens=16384`。
- 网络：网卡和 `NCCL_IB_HCA` 从 YAML 显式配置，脚本只校验，不自动猜测。

## 后续扩展点

- 新模型：新增 `references/pd-profiles/<model>-<backend>.yaml` 和对应 example。
- 新 PD 后端：新增 backend profile，并在 `run_pd_task.sh` 中增加 backend 分支。
- 多 P 多 D / Ray：`pd.topology=npxd` 已预留，当前运行会明确报未实现。
