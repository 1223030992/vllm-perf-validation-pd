# 已验证案例

## 2026-06-12 GLM-4.7-W8A8

环境：`vLLM 0.18.1 + Mooncake + 1P1D`，8 卡 Prefill + 8 卡 Decode，Mooncake wheel 受控安装。成功实测脚本版本为 `2026.06.12-rdma-watchdog-v5`；后续版本保持该链路并增加易用性能力。

### Custom 512/32/c1

状态：通过。

| 指标 | 结果 |
|---|---:|
| QPS | 0.54 |
| 输出吞吐 | 17.33 tok/s |
| 总吞吐 | 294.56 tok/s |
| TTFT | 266.02 ms |
| TPOT | 50.97 ms |
| ITL P99 | 558.69 ms |

### Custom 32768/1024/c4

状态：通过。

| 指标 | 结果 |
|---|---:|
| 测试时长 | 64.70 s |
| QPS | 0.06 |
| 输出吞吐 | 63.31 tok/s |
| 总吞吐 | 2089.10 tok/s |
| TTFT mean | 17068.56 ms |
| TTFT P99 | 23718.86 ms |
| TPOT mean | 37.59 ms |
| TPOT P99 | 39.93 ms |
| ITL P99 | 46.82 ms |

历史 `32768/1024/c1` 曾出现 RDMA transfer timeout。c4 成功不能证明该 c1 case 已修复，两者必须分别记录。

### PCHIT fixed bs1..8

状态：执行通过，36 个请求零失败，有效 cache hit 约 89.99%。bs1-5 满足当前 SLA，bs6-8 未满足，最佳 SLA 并发为 5。因此：

```text
execution_status=PASS
benchmark_status=PASS
sla_status=PARTIAL
```

### 已确认的正常现象

- Proxy `/metrics` 返回 404 不代表测试失败；`/v1/completions` 返回 200 且 CSV PASS 才是 benchmark 判据。
- 模型类重复注册和 speculative decoding 提示是 warning，不直接判失败。
- `NCCL_IB_HCA` 不是 Mooncake HCA 白名单，Mooncake 可能发现额外 HCA。

## 2026-06-13 GLM-5.1-W4A8-V2_6

环境：`vLLM 0.18.1 + Mooncake + 1P1D`，8 卡 Prefill + 8 卡 Decode，Mooncake wheel 受控安装。成功脚本版本为 `2026.06.13-user-workflow-v10`，成功镜像为：

```text
10.16.1.152:5000/jenkins/model_test_env/vllm:0.18.1-ubuntu22.04-dtk26.04-py3.10-20260612-0904
```

关键服务参数：

```text
profile=glm51-w4a8-vllm018-mooncake
max_model_len=67000
gpu_memory_utilization=0.92
tp=8
kv_cache_dtype=fp8_ds_mla
```

该镜像支持 GLM5.1。此前另一版 vLLM 0.18.1 镜像在 Mooncake KV cache 注册阶段失败，不能据此判断 Skill 或节点配置异常；新模型测试必须先确认镜像本身支持目标模型。

### Custom 512/32/c1

状态：通过，1 个请求成功，0 失败。

| 指标 | 结果 |
|---|---:|
| QPS | 0.39 |
| 输出吞吐 | 12.38 tok/s |
| 总吞吐 | 210.49 tok/s |
| TTFT | 803.72 ms |
| TPOT | 57.42 ms |
| ITL P99 | 568.34 ms |

任务状态：

```text
execution_status=PASS
benchmark_status=PASS
sla_status=NOT_APPLICABLE
PD_TASK_DONE=1
```

### PCHIT fixed 32768/1024/bs1..8

状态：执行通过，36 个请求成功，0 失败，有效 PC Hit 约 `89.99%`。

| bs | mean TTFT | mean TPOT | SLA |
|---:|---:|---:|---|
| 1 | 1492.84 ms | 38.76 ms | PASS |
| 2 | 4120.92 ms | 35.95 ms | PASS |
| 3 | 5257.35 ms | 43.42 ms | FAIL |
| 4 | 5154.40 ms | 49.81 ms | FAIL |
| 5 | 6514.12 ms | 51.24 ms | FAIL |
| 6 | 8794.11 ms | 52.34 ms | FAIL |
| 7 | 8952.26 ms | 54.66 ms | FAIL |
| 8 | 9565.89 ms | 53.43 ms | FAIL |

当前 SLA 使用 mean TTFT `<5000 ms`、mean TPOT `<50 ms`，最佳 SLA 并发为 `2`。最终状态：

```text
execution_status=PASS
benchmark_status=PASS
sla_status=PARTIAL
completed_requests=36
failed_requests=0
PD_TASK_DONE=1
```

`sla_status=PARTIAL` 表示请求均成功完成，但只有部分并发满足 SLA，不表示 P/D 服务、Mooncake 传输或 benchmark 失败。

GLM5.1 已完整验证 onboarding、deployment、custom smoke、pchit、容器停止和报告生成。通用复用步骤见 [new-model-workflow.md](new-model-workflow.md)。`32768/1024/c4` custom 尚未实测，不在支持矩阵中标记为通过。
