# vllm-perf-validation-pd 使用指南

本 skill 的 PD 正式流程只通过 `scripts/ops/run_pd_task.sh` 编排。不要在正常流程中手写 SSH、Docker、`vllm serve`、Mooncake proxy、benchmark、curl/API 探测或 stop 命令。

## 推荐执行顺序

1. 在 Linux/远端 skill 目录执行 dry-run，确认命令生成、镜像、节点、端口、网卡和 HCA。
2. 使用相同 config 加 `--assume-yes` 做真实 smoke。
3. 从 `state.json`、CSV、JSON/Markdown report 和 P/D/proxy log 汇总结果。

Windows 本地不需要跑通 bash。本地只做 Python、配置合并、空白和文档检查。

## PD Custom Smoke

先 dry-run：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --config references/examples/glm47-vllm018-mooncake-1p1d-custom.yaml \
  --user <user> --abbr <abbr> --image-prefix TEST --dry-run
```

再真实运行：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --config references/examples/glm47-vllm018-mooncake-1p1d-custom.yaml \
  --user <user> --abbr <abbr> --assume-yes
```

## PD pchit

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --config references/examples/glm47-vllm018-mooncake-1p1d-pchit.yaml \
  --user <user> --abbr <abbr> --assume-yes
```

## 覆盖 P/D 节点和网络

测试新节点时，使用命令行参数覆盖 example 中的默认值：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --config references/examples/glm47-vllm018-mooncake-1p1d-custom.yaml \
  --prefill-node 10.16.1.1 --prefill-service-ip 13.13.1.1 --prefill-vllm-host-ip 13.13.1.1 \
  --decode-node 10.16.1.44 --decode-service-ip 13.13.1.44 --decode-vllm-host-ip 13.13.1.44 \
  --prefill-port 9348 --decode-port 9349 --prefill-transfer-port 8998 --proxy-port 8000 \
  --network-ifname ens61f0np0 \
  --user <user> --abbr <abbr> --assume-yes
```

可选 HCA 覆盖：

```bash
--nccl-ib-hca mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_8,mlx5_9
```

## 当前默认拓扑

- backend：`mooncake_vllm018`
- topology：`1p1d`
- model：`/model/GLM-4.7-W8A8`
- Prefill：`10.16.1.1 / 13.13.1.1:9348`，`kv_role=kv_producer`，transfer port `8998`
- Decode：`10.16.1.44 / 13.13.1.44:9349`，`kv_role=kv_consumer`
- Proxy：prefill 容器内启动，端口 `8000`
- 网卡：`ens61f0np0`
- 默认不加 `--profiler-config`

## 产物路径

每次运行写入：

- Host：`/public/home/<user>/skilltest/vllm-perf-validation-pd`
- Container：`/mnt/skilltest/vllm-perf-validation-pd`

重点产物：

- `work_dirs/<run>/state.json`
- `work_dirs/<run>/logs/*prefill*`
- `work_dirs/<run>/logs/*decode*`
- `work_dirs/<run>/logs/mooncake-proxy-*.log`
- `work_dirs/<run>/csvs/<mode>/all.csv`
- `reports/<run_id>.json`
- `reports/<run_id>.md`

## 失败处理

如果 preflight、P/D readiness、proxy readiness、benchmark 或 stop 失败，优先汇报：

- `state.json` 中的 `status`
- `failure.reason` 和 `failure.detail`
- P/D/proxy 相关日志路径
- 已生成的 CSV、JSON report、Markdown report 路径

不要临时手写恢复命令。`run_pd_task.sh` 会在失败后尝试停止已创建的 P/D 容器，并保留原始非 0 退出码。脚本不执行 `docker rm`。

## 权限建议

agent settings 建议只允许受控入口：

```text
bash /public/home/*/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh *
bash /public/home/*/.claude/skills/vllm-perf-validation-pd/scripts/ops/show_state.sh *
python /public/home/*/.claude/skills/vllm-perf-validation-pd/scripts/ops/pd_config.py *
```

不要建议开放 `ssh *`、`docker *`、`bash *`。

## 旧 centralized baseline

`scripts/ops/run_single_task.sh` 只用于 centralized baseline 的 `custom` 和 `pchit` 对比。PD serving 不使用 `scripts/server-scripts/` 或旧 `start_vllm_service.sh`。
