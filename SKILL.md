---
name: vllm-perf-validation-pd
description: Controlled vLLM performance validation for centralized custom/pchit and vLLM 0.18 + Mooncake 1P1D PD serving.
---

# vllm-perf-validation-pd

Use this skill for two supported workflows:

- Centralized baseline: call `scripts/ops/run_single_task.sh` for `custom` or `pchit`.
- PD serving: call `scripts/ops/run_pd_task.sh` with a YAML config under `references/examples/`.

Do not hand-write SSH, Docker, vLLM, Mooncake proxy, benchmark, or stop commands for normal operation. Use the ops entrypoints so `state.json`, CSV paths, logs, and reports remain consistent.

## PD Quick Commands

Custom:

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --config references/examples/glm47-vllm018-mooncake-1p1d-custom.yaml \
  --user <user> --abbr <abbr> --assume-yes
```

Fixed PC hit:

```bash
bash /public/home/<user>/.claude/skills/vllm-perf-validation-pd/scripts/ops/run_pd_task.sh \
  --config references/examples/glm47-vllm018-mooncake-1p1d-pchit.yaml \
  --user <user> --abbr <abbr> --assume-yes
```

## Constraints

- Current PD implementation supports only `pd.backend=mooncake_vllm018` and `pd.topology=1p1d`.
- `custom` and `pchit` are the supported benchmark modes.
- Mooncake examples must already exist under `mooncake/examples/...`.
- Network interface and HCA values come from config and are validated in preflight; they are not guessed.
