# vllm-perf-validation-pd

这是用于 DCU 环境的 vLLM PD 分离性能验证 skill。当前主线是稳定复现：

- `vLLM 0.18.1 + Mooncake + GLM-4.7-W8A8 + 1P1D PD`
- benchmark 暂时复用 `custom` / `pchit`，请求统一打到 Mooncake proxy
- single/vLLM015 baseline 不在本仓库维护，请使用独立项目 `vllm-perf-validation-single`

正常 PD 流程只调用一个主入口：`scripts/ops/run_pd_task.sh`。不要手写 SSH、Docker、`vllm serve`、Mooncake proxy、benchmark、curl 探测或 stop 命令。

## 唯一推荐入口

第一次运行或改过节点/网络后，先在 Linux/远端 skill 目录执行 dry-run：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --config references/examples/glm47-vllm018-mooncake-1p1d-custom.yaml \
  --user <user> --abbr <abbr> --image-prefix TEST --dry-run
```

确认生成命令符合预期后，再正式运行：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --config references/examples/glm47-vllm018-mooncake-1p1d-custom.yaml \
  --user <user> --abbr <abbr> --assume-yes
```

固定 prefix-cache-hit 烟测：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --config references/examples/glm47-vllm018-mooncake-1p1d-pchit.yaml \
  --user <user> --abbr <abbr> --assume-yes
```

## 覆盖节点和网络

默认示例使用已实测的 1P1D 节点和网络。测试新 P/D 组合时优先用命令行覆盖，不要让代理自行读取 profile 后拼命令：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --config references/examples/glm47-vllm018-mooncake-1p1d-custom.yaml \
  --prefill-node 10.16.1.1 --prefill-service-ip 13.13.1.1 --prefill-vllm-host-ip 13.13.1.1 \
  --decode-node 10.16.1.44 --decode-service-ip 13.13.1.44 --decode-vllm-host-ip 13.13.1.44 \
  --prefill-port 9348 --decode-port 9349 --prefill-transfer-port 8998 --proxy-port 8000 \
  --network-ifname ens61f0np0 \
  --user <user> --abbr <abbr> --assume-yes
```

如果需要覆盖 HCA，再追加：

```bash
--nccl-ib-hca mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_8,mlx5_9
```

## 当前默认值

- 镜像：`10.16.1.152:5000/jenkins/model_test_env/vllm:0.18.1-ubuntu22.04-dtk26.04-py3.10-20260608-1434`
- Prefill：控制节点 `10.16.1.1`，服务 IP / `VLLM_HOST_IP` 为 `13.13.1.1`，vLLM 端口 `9348`，Mooncake transfer port `8998`
- Decode：控制节点 `10.16.1.44`，服务 IP / `VLLM_HOST_IP` 为 `13.13.1.44`，vLLM 端口 `9349`
- Proxy：运行在 prefill 容器中，端口 `8000`
- 网卡：`ens61f0np0`
- 默认不加入 `--profiler-config`

## PD Server 脚本目录

旧 `scripts/server-scripts/` 已从 PD 仓库移除，因为它属于 single/vLLM015 起服方式。后续 vLLM018 + Mooncake PD 起服脚本按模型放在：

```text
scripts/pd-server/<model>/
```

当前已预留：

```text
scripts/pd-server/glm47-w8a8/
```

你后续传入 GLM-4.7-W8A8 原始 1P1D 起服脚本后，再在该目录中做参数化和标准化。

## 本地和远端验证边界

Windows 本地不要求安装或跑通 bash。本地只做非 bash 检查，例如 Python 编译、配置合并、空白检查和文档关键字检查。

需要在 Linux/远端 skill 目录执行的验证：

```bash
bash -n scripts/ops/*.sh
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --config references/examples/glm47-vllm018-mooncake-1p1d-custom.yaml \
  --user <user> --abbr <abbr> --image-prefix TEST --dry-run
```

真实 smoke 通过后，应确认 P/D ready、proxy ready、CSV、JSON/Markdown report 和 `state.json` 都已生成。

## 受控入口和权限建议

建议在 agent settings 中只允许受控入口，例如：

```text
bash /public/home/*/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh *
bash /public/home/*/.claude/skills/vllm-perf-validation-pd/scripts/ops/show_state.sh *
python /public/home/*/.claude/skills/vllm-perf-validation-pd/scripts/ops/pd_config.py *
```

不建议开放宽泛的 `ssh *`、`docker *`、`bash *`。这些命令应由 `run_pd_task.sh` 内部按固定流程生成和执行。

## 产物

默认产物路径：

- Host：`/public/home/<user>/skilltest/vllm-perf-validation-pd`
- Container：`/mnt/skilltest/vllm-perf-validation-pd`

重点文件：

- `work_dirs/<run>/state.json`
- `work_dirs/<run>/logs/*prefill*`
- `work_dirs/<run>/logs/*decode*`
- `work_dirs/<run>/logs/mooncake-proxy-*.log`
- `work_dirs/<run>/csvs/<mode>/all.csv`
- `reports/<run_id>.json`
- `reports/<run_id>.md`

失败时优先看 `state.json` 的 `failure.reason` / `failure.detail` 和 P/D/proxy 日志。脚本会尝试停止已创建容器，但不会执行 `docker rm`。

## 实测记录模板

远端跑通后可在这里追加案例，便于后续复现和回归：

```text
日期：
镜像：
配置：
Prefill：
Decode：
Proxy：
benchmark：
state.json：
CSV：
JSON/Markdown report：
结果摘要：
失败原因或注意事项：
```

## single baseline

本仓库不再内置维护 single/vLLM015 baseline。需要 centralized baseline 时，请使用独立项目 `vllm-perf-validation-single`。
