# Report And State Schema

`run_pd_task.sh` 会持续写入 `state.json`。`render_report.py` 根据 `state.json` 和 benchmark CSV 生成 JSON / Markdown 报告。字段名保持英文，说明使用中文。

## 关键 state 字段

```json
{
  "status": "READY | BENCH_DONE | SERVICE_FAILED | SERVICE_TIMEOUT | BENCH_FAILED | STOPPED",
  "model": {
    "name": "GLM-4.7-W8A8",
    "model_short": "glm47int8",
    "container_model_path": "/model/GLM-4.7-W8A8",
    "served_model_id": "string",
    "bench_model_id": "string",
    "bench_model_id_source": "proxy | decode | config_fallback"
  },
  "pd": {
    "backend": "mooncake_vllm018",
    "topology": "1p1d",
    "roles": {
      "prefill": {
        "node": "10.16.1.1",
        "container": "name",
        "port": "9348",
        "transfer_port": "8998",
        "kv_role": "kv_producer",
        "vllm_host_ip": "13.13.1.1",
        "network_ifname": "ens61f0np0",
        "log_file": "path",
        "pid_file": "path"
      },
      "decode": {
        "node": "10.16.1.44",
        "container": "name",
        "port": "9349",
        "kv_role": "kv_consumer",
        "vllm_host_ip": "13.13.1.44",
        "network_ifname": "ens61f0np0",
        "log_file": "path",
        "pid_file": "path"
      }
    },
    "proxy": {
      "status": "READY",
      "node": "10.16.1.1",
      "container": "name",
      "port": "8000",
      "prefill_url": "http://13.13.1.1:9348",
      "prefill_transfer_port": "8998",
      "decode_url": "http://13.13.1.44:9349",
      "served_model_id_source": "unavailable"
    }
  },
  "paths": {
    "work_dir_host": "path",
    "csv_file_host": "path",
    "report_json_host": "path",
    "report_md_host": "path"
  },
  "failure": {
    "reason": "string",
    "detail": "string"
  }
}
```

## 状态含义

- `READY`：P/D/proxy 已进入可用状态
- `BENCH_DONE`：benchmark 完成，通常应有 CSV 和报告
- `SERVICE_FAILED`：preflight、起服、proxy 或 stop 阶段失败
- `SERVICE_TIMEOUT`：P/D 或 proxy readiness 超时
- `BENCH_FAILED`：benchmark 阶段失败
- `STOPPED`：服务停止流程完成

## 报告必须包含的信息

最终汇总应覆盖：

- P/D/proxy 容器名、节点、端口和日志路径
- `state.json`、CSV、JSON report、Markdown report 路径
- `served_model_id`
- `bench_model_id` 和 `bench_model_id_source`
- CSV 存在时的 benchmark 指标摘要
- 失败时的 `failure.reason` 和 `failure.detail`

## 失败报告

如果任务失败且 CSV 不存在，报告仍应生成，并明确标记失败状态与缺失 CSV。用户调试时优先查看：

- `work_dirs/<run>/state.json`
- P/D vLLM log
- Mooncake proxy log
- JSON / Markdown report
