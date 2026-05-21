# 日志分类规则

判断 vLLM 服务处于加载中、已就绪或失败状态时使用本文档。

## 等待 / 非失败信号

当前日志包含以下内容时，应继续等待直到超时，不要立即判定失败：

- `Loading safetensors checkpoint shards`
- `torch.compile takes`
- `Compiling a graph for compile range`
- `No available shared memory broadcast block found`
- `Initializing moe_cache_singleton`
- `Cache the graph of compile range`
- `Using cache directory`
- `hipModuleLoad ... Success`
- `Starting to load model`
- `Please install aiter if you want to infer with aiter_moe`
- `Skip AMD buffer-ops lowering`
- `TensorFloat32 tensor cores`
- `min_p, logit_bias, and min_tokens`
- `bash: cannot set terminal process group`
- `bash: no job control in this shell`

## 就绪信号

日志包含以下内容时，应调用 `/v1/models` 发现 `served_model_id`，再使用该模型 id
发起 chat 健康检查：

- `APIServer pid`
- `Started server process`
- `Application startup complete`
- `Uvicorn running`
- `Route: /v1/chat/completions`

只有当 `/v1/models` 能返回模型 id，且使用该 id 的健康检查返回 HTTP 200 时，才算服务就绪。

## 失败信号

当前日志或进程检查出现以下情况时，应立即判定失败：

- `Traceback`
- `ImportError`
- `ModuleNotFoundError`
- `RuntimeError`
- `cannot open shared object file`
- `Killed`
- `OOM`
- `out of memory`
- `hipError`
- `ROCm error`
- 服务进程在就绪前退出
- 端口持续不可用直到超时
- 健康检查持续失败直到超时

启动脚本已经删除旧日志后，才可以按当前日志判断失败；不要把旧日志里的历史错误当成本次失败。
