# State 与报告字段

## 顶层状态

```json
{
  "status": "COMPLETED | TASK_FAILED | STOP_FAILED",
  "invocation_id": "timestamp-random",
  "report": {
    "execution_status": "PASS | FAIL",
    "benchmark_status": "PASS | FAIL",
    "sla_status": "PASS | PARTIAL | FAIL | NOT_APPLICABLE"
  }
}
```

PCHIT 请求全部成功但部分并发不满足 SLA 时，execution 和 benchmark 为 `PASS`，SLA 为 `PARTIAL`。

## PD 状态

```json
{
  "pd": {
    "backend": "mooncake_vllm018",
    "topology": "1p1d",
    "roles": {
      "prefill": {"node": "...", "container": "...", "port": 9348, "status": "READY"},
      "decode": {"node": "...", "container": "...", "port": 9349, "status": "READY"}
    },
    "runtime": {
      "prefill": {"status": "READY", "mooncake_version": "..."},
      "decode": {"status": "READY", "mooncake_version": "..."}
    },
    "proxy": {
      "listener": {"status": "READY"},
      "upstream": {"prefill": {"status": "READY"}, "decode": {"status": "READY"}},
      "bootstrap": {"status": "READY"},
      "smoke": {"status": "READY"}
    },
    "transfer": {
      "status": "READY | FAILED",
      "protocol": "rdma",
      "failure_reason": null
    }
  }
}
```

## Benchmark 与产物

```json
{
  "test": {
    "status": "RUNNING | COMPLETED | FAILED",
    "execution_status": "PASS | FAIL",
    "benchmark_status": "PASS | FAIL",
    "sla_status": "PASS | PARTIAL | FAIL | NOT_APPLICABLE",
    "current_case": {},
    "heartbeat_at": "UTC timestamp",
    "elapsed_seconds": 30
  },
  "paths": {
    "work_dir_host": "...",
    "csv_file_host": "...",
    "report_json_host": "...",
    "report_md_host": "..."
  }
}
```

失败信息保存在 `failure.stage`、`failure.reason`、`failure.detail` 和 `failure.exit_code`。stop 结果不得覆盖原始失败原因。
