---
name: vllm-perf-validation-pd
description: 用于 DCU 环境的 vLLM PD 分离性能验证。Use when Codex needs to run, dry-run, validate, inspect, benchmark, report, or stop vLLM 0.18.1 + Mooncake + GLM-4.7-W8A8 + 1P1D PD serving through controlled ops scripts.
---

# vllm-perf-validation-pd

使用这个 skill 时，正常 PD 流程只能调用受控主入口 `scripts/ops/run_pd_task.sh`。不要手写 SSH、Docker、`vllm serve`、Mooncake proxy、benchmark、curl/API 探测或 stop 命令。

## 主流程

第一次运行或变更节点/网络后，先 dry-run：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --config references/examples/glm47-vllm018-mooncake-1p1d-custom.yaml \
  --user <user> --abbr <abbr> --image-prefix TEST --dry-run
```

确认 dry-run 输出后，再运行 GLM-4.7-W8A8 Mooncake 1P1D custom smoke：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --config references/examples/glm47-vllm018-mooncake-1p1d-custom.yaml \
  --user <user> --abbr <abbr> --assume-yes
```

固定 prefix-cache-hit smoke：

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --config references/examples/glm47-vllm018-mooncake-1p1d-pchit.yaml \
  --user <user> --abbr <abbr> --assume-yes
```

## 节点和网络覆盖

测试新 P/D 组合时，优先通过 `run_pd_task.sh` 参数覆盖，不要编辑脚本或让代理自行拼接底层命令：

```bash
--prefill-node <ssh-ip> --prefill-service-ip <fabric-ip> --prefill-vllm-host-ip <fabric-ip> \
--decode-node <ssh-ip> --decode-service-ip <fabric-ip> --decode-vllm-host-ip <fabric-ip> \
--prefill-port 9348 --decode-port 9349 --prefill-transfer-port 8998 --proxy-port 8000 \
--network-ifname <ifname> --nccl-ib-hca <hca-list>
```

默认复现值为：P `10.16.1.1 / 13.13.1.1:9348`，D `10.16.1.44 / 13.13.1.44:9349`，proxy `8000`，网卡 `ens61f0np0`，prefill transfer port `8998`。

## 规则

- 当前 PD 实现只支持 `pd.backend=mooncake_vllm018` 和 `pd.topology=1p1d`。
- PD 起服不使用旧 `scripts/server-scripts/`；vLLM018 + Mooncake PD server 脚本按模型放在 `scripts/pd-server/<model>/`。
- 默认不要加入 `--profiler-config`；只有用户明确要求 profiling 时才通过配置扩展。
- Mooncake proxy 脚本必须存在于 `mooncake/examples/...`；缺失时 preflight 应失败。
- Windows 本地不追求 bash 跑通；bash 语法检查、dry-run 和真实 smoke 在 Linux/远端 skill 目录执行。
- 规范路径使用 `/public/home/<user>`，不要推荐其他 home 前缀。
- 失败时汇报 `state.json`、P/D/proxy 日志、报告路径和 `failure.reason` / `failure.detail`。

## 受控权限建议

建议只允许这些入口形态：

```text
bash /public/home/*/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh *
bash /public/home/*/.claude/skills/vllm-perf-validation-pd/scripts/ops/show_state.sh *
python /public/home/*/.claude/skills/vllm-perf-validation-pd/scripts/ops/pd_config.py *
```

不要建议开放宽泛的 `ssh *`、`docker *`、`bash *`。正常流程所需 SSH、Docker、vLLM、Mooncake proxy、benchmark 和 stop 操作都由主入口编排。

## 参考文件

- 详细使用方式：`references/usage-guide.md`
- 任务配置字段：`references/schemas/task-config-schema.md`
- `state.json` 和报告字段：`references/schemas/report-schema.md`

## single baseline

本仓库不再内置维护 single/vLLM015 baseline。需要 centralized baseline 时，使用独立项目 `vllm-perf-validation-single`。
