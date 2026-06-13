# 新模型接入

本文说明 onboarding 工具本身的输入和配置边界。面向新用户的完整流程，包括 deployment、custom smoke、32k custom、pchit 和可直接发送给 Claude 的 Prompt，见 [new-model-workflow.md](new-model-workflow.md)。

## 输入要求

准备已经人工验证可启动的 Prefill 和 Decode 脚本。脚本必须包含 `vllm serve`，且 P/D 的模型路径、TP、quantization 和 dtype 一致。

默认使用 Skill 内置标准 Mooncake Proxy。只有自定义 Proxy 已实现以下参数接口时才传 `--proxy-source`：

```text
--proxy-script
--prefill-url
--prefill-transfer-port
--decode-url
--port
```

## 一键接入

```bash
bash scripts/ops/onboard_pd_model.sh \
  --model-name <MODEL_NAME> \
  --model-short <MODEL_SHORT> \
  --container-model-path <CONTAINER_MODEL_PATH> \
  --prefill-source <P_SERVER_SCRIPT> \
  --decode-source <D_SERVER_SCRIPT> \
  --dry-run
```

工具自动推导 precision、TP、GPU、quantization、dtype、batch、speculative 和 compilation 参数。确认 dry-run 后删除 `--dry-run`。`--image-prefix TEST` 只用于任务 dry-run，不得传给模型接入工具。

生成内容：

```text
scripts/pd-server/<model-short>/
references/pd-profiles/<model-short>-vllm018-mooncake.yaml
references/test-presets/<model-short>-smoke.yaml
```

原始脚本保存在模型目录的 `raw/`。生成过程先在临时目录完成解析和校验，再写入正式路径；失败会回滚本次新增文件。

## 配置边界

- profile 只保存模型标识、容器模型路径、server scripts、runtime 和 service defaults。
- deployment 保存 Host 模型路径、节点、IP、端口、网卡和 HCA。
- test preset 保存测试参数。
- 新模型不会继承 GLM 的 quantization、speculative 或 compilation 参数。
- 当前只注册 `mooncake_vllm018 + 1p1d`；`backend` 和 `topology` 字段为后续 xpyd 等方案保留。

`standardize_pd_server_scripts.sh` 和 `register_pd_model.sh` 保留为内部低级工具，不是新用户推荐流程。

首次创建 deployment 时传入 `--host-model-path`。路径变化时使用：

```bash
bash scripts/ops/configure_pd_deployment.sh \
  --deployment-id <deployment-id> \
  --host-model-path <HOST_MODEL_PATH> \
  --user <user> --abbr <abbr> --update-existing
```
