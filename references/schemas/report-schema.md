# State 与报告字段

`run_pd_task.sh` 持续更新 `state.json`，`render_report.py` 根据 state 和可选 benchmark CSV 生成 JSON/Markdown 报告。

PD 报告包含 `pd.proxy.listener`、`pd.proxy.upstream`、`pd.proxy.bootstrap`、`pd.proxy.smoke` 和 `cleanup`。CSV 路径区分预期路径与实际生成文件。

## 关键字段

```json
{
  "status": "INITIALIZED | RUNTIME_FAILED | SERVICE_FAILED | COMPLETED | TASK_FAILED | STOP_FAILED",
  "image_ref": "repository:tag",
  "image_ids": {
    "prefill": "sha256 without prefix",
    "decode": "sha256 without prefix"
  },
  "pd": {
    "runtime": {
      "mooncake_wheel": "URL or path",
      "mooncake_dest_device_affinity": true,
      "prefill": {
        "status": "READY | FAILED",
        "mooncake_version": "string",
        "log_file": "path",
        "log_tail": "string"
      },
      "decode": {
        "status": "READY | FAILED",
        "mooncake_version": "string",
        "log_file": "path",
        "log_tail": "string"
      }
    },
    "roles": {
      "prefill": {"node": "IP", "container": "name", "port": 9348, "status": "string"},
      "decode": {"node": "IP", "container": "name", "port": 9349, "status": "string"}
    },
    "proxy": {"node": "IP", "container": "name", "port": 8000, "status": "string"},
    "transfer": {
      "status": "DISCOVERED | MONITORING | READY | FAILED",
      "protocol": "rdma",
      "failure_reason": "string",
      "prefill": {"detected_hcas": "comma separated", "gid_indices": "comma separated"},
      "decode": {"detected_hcas": "comma separated", "gid_indices": "comma separated"}
    }
  },
  "test": {
    "status": "RUNNING | COMPLETED | FAILED",
    "current_case": {"input_len": 32768, "output_len": 1024, "concurrency": 1, "num_prompts": 1},
    "heartbeat_at": "UTC timestamp",
    "elapsed_seconds": 30,
    "bench_timeout_seconds": 3600
  },
  "failure": {
    "stage": "stage name",
    "reason": "classified reason",
    "detail": "bounded summary or role",
    "exit_code": 1
  },
  "paths": {
    "work_dir_host": "path",
    "csv_file_host": "path",
    "report_json_host": "path",
    "report_md_host": "path"
  }
}
```

## 失败保证

- 子脚本已写入具体 `failure.reason` 时，主入口不得覆盖。
- 主入口补充 `failure.stage` 和 `failure.exit_code`。
- runtime/readiness 日志摘要最多保留约 4000 字节。
- stop 失败单独写 role 的 `stop_status`，不得覆盖原始服务失败。
- CSV 不存在时仍应生成失败报告，并标记 CSV 缺失。

常见原因包括：`docker_image_not_found`、`docker_image_id_mismatch`、`host_model_path_missing`、`mooncake_transfer_engine_missing`、`mooncake_install_failed`、`python_dependency_missing`、`out_of_memory`、`readiness_timeout`、`mooncake_rdma_transfer_timeout`、`mooncake_kv_pull_failed` 和 `bench_timeout`。
