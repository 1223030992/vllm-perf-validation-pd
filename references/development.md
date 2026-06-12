# 开发与检查

Windows 本地不要求运行 bash。推荐执行：

```powershell
python -m compileall -q scripts
python -m unittest discover -s scripts/tests -v
python scripts/ops/pd_config.py --profile glm47-vllm018-mooncake --test-preset custom-smoke --json
git diff --check
```

Linux 或远端 Skill 目录再执行：

```bash
bash -n scripts/ops/*.sh
```

真实节点回归顺序：

1. `custom-smoke`。
2. `custom-32k1k-c4`。
3. `pchit-fixed`。
4. 同参数连续运行两次，确认 work dir、state、报告和容器名完全隔离。

脚本运行输出保持 ASCII，中文说明放在 README、SKILL 和 references 文档中。
