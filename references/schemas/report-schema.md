# 报告 Schema

本文档定义 vLLM DCU 性能测试报告的推荐结构。字段名保持英文，便于脚本读取；
字段说明使用中文，便于维护和版本迭代。

## 单任务报告结构

```json
{
  "run_id": "string",
  "task_name": "string",
  "image": "string",
  "status": "PASS | FAIL | PARTIAL | SKIPPED",
  "model": {
    "name": "string",
    "host_model_path": "string",
    "container_model_path": "string",
    "served_model_id": "string",
    "bench_model_id": "string",
    "tp": 8,
    "port": 9348,
    "node": "string"
  },
  "deployment": {
    "status": "PASS | FAIL",
    "container_name": "string",
    "start_time": "ISO8601",
    "end_time": "ISO8601",
    "startup_duration_seconds": 0,
    "readiness_duration_seconds": 0,
    "gpu_topology": "string"
  },
  "test": {
    "mode": "full | pchit | engin | custom",
    "status": "PASS | FAIL | PARTIAL",
    "start_time": "ISO8601",
    "end_time": "ISO8601",
    "duration_seconds": 0
  },
  "results": {
    "log_dir": "string",
    "csv_file": "string",
    "scenarios_tested": ["string"],
    "key_metrics": {
      "max_qps": 0.0,
      "max_tok_s": 0.0,
      "avg_ttft_ms": 0.0,
      "avg_tpot_ms": 0.0
    }
  },
  "summary": {
    "total_requests": 0,
    "passed_scenarios": "N/N",
    "failed_scenarios": 0
  },
  "recommendation": {
    "block_release": false,
    "need_manual_review": false,
    "reason": "string"
  },
  "baseline": {
    "status": "baseline_missing",
    "source": null
  }
}
```

## 多模型聚合报告结构

```json
{
  "run_id": "string",
  "task_name": "string",
  "status": "PASS | FAIL | PARTIAL | INTERRUPTED",
  "start_time": "ISO8601",
  "end_time": "ISO8601",
  "duration_seconds": 0,
  "config": {
    "schedule_strategy": "serial | parallel",
    "test_mode": "full | pchit | engin | custom",
    "total_models": 2,
    "total_nodes": 1,
    "fail_continue": true
  },
  "node_results": [
    {
      "node_ip": "10.16.1.1",
      "dcu_type": "BW1000",
      "status": "COMPLETED",
      "model_results": [
        {
          "model_name": "GLM-4.7-W8A8",
          "host_model_path": "/public/opendas/DL_DATA/llm-models/glm4.7/GLM-4.7-W8A8",
          "container_model_path": "/model/GLM-4.7-W8A8",
          "served_model_id": "/model/GLM-4.7-W8A8",
          "bench_model_id": "/model/GLM-4.7-W8A8",
          "status": "PASS",
          "port": 9348,
          "container_name": "<container_prefix>-0515-glm47int8-2540",
          "deployment": { "status": "PASS", "start_time": "...", "end_time": "..." },
          "test": { "mode": "full", "status": "PASS", "duration_seconds": 600 },
          "key_metrics": {
            "max_qps": 125.5,
            "max_tok_s": 4520.0,
            "avg_ttft_ms": 85.3,
            "avg_tpot_ms": 12.1
          },
          "output": {
            "log_dir": "...",
            "csv_file": "..."
          }
        }
      ]
    }
  ],
  "summary": {
    "total_models": 2,
    "passed": 2,
    "failed": 0,
    "skipped": 0,
    "node_completed": 1,
    "node_total": 1
  },
  "cross_model_comparison": [
    ["Model", "QPS(max)", "tok/s(max)", "TTFT(avg)", "TPOT(avg)", "Status"],
    ["GLM-4.7-W8A8", "125.5", "4520.0", "85.3ms", "12.1ms", "PASS"],
    ["GLM-5-INT8", "98.2", "3890.0", "95.1ms", "14.2ms", "PASS"]
  ],
  "recommendation": {
    "block_release": false,
    "need_manual_review": false,
    "reason": "所有模型均通过性能验证"
  },
  "baseline": {
    "status": "baseline_missing",
    "source": null
  }
}
```

## 字段说明

### config

| 字段 | 类型 | 说明 |
|---|---|---|
| `schedule_strategy` | string | 调度策略，取值为 `serial` 或 `parallel` |
| `test_mode` | string | 测试模式 |
| `total_models` | int | 模型总数 |
| `total_nodes` | int | 节点总数，单节点场景固定为 1 |
| `fail_continue` | bool | 某个模型失败后是否继续执行后续模型 |

### node_results

| 字段 | 类型 | 说明 |
|---|---|---|
| `node_ip` | string | 节点 IP |
| `dcu_type` | string | DCU 类型 |
| `status` | string | 节点执行状态，如 `COMPLETED`、`RUNNING`、`FAILED` |
| `model_results` | array | 该节点上的所有模型结果 |

### summary

| 字段 | 类型 | 说明 |
|---|---|---|
| `total_models` | int | 模型总数 |
| `passed` | int | 通过数量 |
| `failed` | int | 失败数量 |
| `skipped` | int | 跳过数量 |
| `node_completed` | int | 已完成节点数 |
| `node_total` | int | 总节点数 |

### cross_model_comparison

跨模型对比表，用于快速对比不同模型的核心性能指标。

### 状态判定

| 状态 | 含义 |
|---|---|
| `PASS` | 所有场景或模型通过 |
| `PARTIAL` | 部分场景或模型通过，部分失败或跳过 |
| `FAIL` | 测试失败 |
| `INTERRUPTED` | 用户中断执行 |
| `SKIPPED` | 未执行任何测试 |
