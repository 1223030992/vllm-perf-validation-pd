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
