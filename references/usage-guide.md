# 完整使用说明

## 配置分层

Skill 将配置拆成三层：

| 层 | 内容 | 是否提交仓库 |
|---|---|---|
| model profile | 模型路径、P/D 脚本、TP、量化、dtype、模型专属参数 | 是 |
| deployment | 节点、service IP、端口、网卡、HCA | 否，保存在用户目录 |
| test preset | custom/pchit 测试参数 | 是 |

合并优先级为 CLI > legacy config > test preset > deployment > model profile > 内置默认值。

## 推荐运行

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --profile <PROFILE_ID> \
  --deployment /public/home/<user>/.config/vllm-perf-validation-pd/deployments/<ID>.yaml \
  --test-preset <TEST_PRESET> \
  --image <IMAGE> --mooncake-wheel <WHEEL> \
  --user <user> --abbr <abbr> --assume-yes
```

`--abbr` 是姓名缩写。镜像已预装 Mooncake 时省略 `--mooncake-wheel`。

## Custom 覆盖参数

```text
--input-lens
--output-len
--concurrencies
--num-prompts-mult
--request-rate
--percentiles
```

## PCHIT 覆盖参数

```text
--pchit-input-len
--pchit-output-len
--pchit-batches
--pc-hit-target
--pchit-mode
--ttft-sla-ms
--tpot-sla-ms
--sla-stat
```

`--bench-timeout`、`--ready-timeout`、`--proxy-timeout` 和 `--interval` 可用于两种测试模式。

## 运行隔离

每次自动生成：

```text
<model-short>-<mode>-<timestamp>-<random>
```

该标识用于 work dir、state、报告和容器名。显式 `--run-id` 已存在时会在起服前失败，不覆盖历史结果。

## Dry-run

`--dry-run` 不连接真实节点。默认只输出 effective config、阶段和关键命令；`--verbose-dry-run` 才输出完整子脚本命令。

## 失败保留与清理

`--keep-containers-on-failure` 仅在 Proxy 或 benchmark 等后期失败时保留容器。清理必须使用：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --cleanup-state <STATE_HOST> --user <user> --abbr <abbr>
```

主入口从 state 读取节点、容器名和端口，不接受手写清理目标。

## 产物

```text
work_dirs/<run-id>/state.json
work_dirs/<run-id>/logs/
work_dirs/<run-id>/csvs/<mode>/all.csv
reports/<run-id>.json
reports/<run-id>.md
```

成功后根据主入口摘要即可判断结果。失败时再调用 `show_state.sh --state <STATE_HOST>`。
