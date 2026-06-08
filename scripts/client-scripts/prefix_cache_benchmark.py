#!/usr/bin/env python3
"""Prefix Cache 命中率压测工具。

这个脚本用于测试长输入场景下的 prefix cache / radix cache 收益，重点回答：

1. 在 64k/70k 输入、1k 输出、指定 prefix cache 命中率下，满足 SLA 的最大并发是多少。
2. 在用户指定的一组并发下，TTFT/TPOT/ITL/P95/P99 等指标分别是多少。

脚本的核心设计是“共享前缀 + 随机后缀”：

- 同一个 case 内，所有请求的前 prefix_len 个 token 完全一致，用于制造稳定的 prefix cache 命中。
- 每个请求 prefix 之后的 suffix token 不同，避免整条 prompt 完全相同导致实际命中率接近 100%。
- prefix_len 会按 prefix_block_size 向下对齐，避免最后一个不完整 KV block 造成命中率波动。

TPOT 口径特别注意：

- TPOT = 首 token 之后到请求结束的 decoding 总耗时 / (completion_tokens - 1)
- ITL 只是 streaming chunk/token 间隔的辅助观测值，不用于替代 TPOT。
- 这个口径更适合 MTP 场景，因为 MTP 可能让单次 stream 间隔不等价于单 token decode 时间。
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import hashlib
import json
import math
import random
import time
import uuid
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any


TIMESTAMP_FORMAT = "%Y-%m-%d-%H-%M-%S"

# CSV fields are intentionally stable because render_report.py consumes them.
DEFAULT_COLUMNS = [
    "mode",
    "prompt_namespace",
    "dp_size",
    "dp_prefix_warmup_rounds",
    "dp_cache_block_size",
    "effective_prefix_block_size",
    "effective_prefix_warmup_requests",
    "dp_warmup_endpoint_count",
    "phase",
    "status",
    "error_reason",
    "sla_pass",
    "cache_hit_pct",
    "effective_cache_hit_pct",
    "expected_per_request_cache_hit_pct",
    "prefix_len",
    "input",
    "output",
    "num_prompts",
    "concurrency",
    "peak_concurrent_requests",
    "duration_s",
    "rps",
    "total_input_tokens",
    "total_generated_tokens",
    "generate_throughput_tok_s",
    "peak_output_throughput_tok_s",
    "total_throughput_tok_s",
    "mean_ttft_ms",
    "median_ttft_ms",
    "p95_ttft_ms",
    "p99_ttft_ms",
    "mean_tpot_ms",
    "median_tpot_ms",
    "p95_tpot_ms",
    "p99_tpot_ms",
    "mean_itl_ms",
    "median_itl_ms",
    "p95_itl_ms",
    "p99_itl_ms",
    "QPM",
    "completed_requests",
    "failed_requests",
]


tokenizer = None


def namespace_seed(namespace: str) -> int:
    """把 prompt namespace 转成稳定整数种子。

    不使用 Python 内置 hash，因为它在不同进程间默认带随机盐，不能保证复现。
    """

    digest = hashlib.sha256(namespace.encode("utf-8")).digest()
    return int.from_bytes(digest[:8], byteorder="big", signed=False)


@dataclass
class RequestResult:
    """单个请求的观测结果。

    所有时间在内部先用秒保存，写 CSV 时再转换成 ms。失败请求不会参与
    latency/throughput 统计，但会让该 case 的 SLA 判定失败。
    """

    success: bool
    ttft_s: float = 0.0
    tpot_s: float = 0.0
    latency_s: float = 0.0
    mean_itl_s: float = 0.0
    completion_tokens: int = 0
    prompt_tokens: int = 0
    total_tokens: int = 0
    error: str = ""


def normalize_cache_hit(value: float) -> float:
    """兼容 0.9 和 90 两种写法，内部统一成 0~1 的比例。"""

    if value < 0:
        raise ValueError("--prefix-cache-hit must be >= 0")
    if value > 1:
        if value > 100:
            raise ValueError("--prefix-cache-hit must be <= 1.0 or <= 100")
        return value / 100.0
    return value


def percentile(values: list[float], pct: float) -> float:
    """不依赖 numpy 的 percentile，便于在干净压测环境里直接运行。"""

    if not values:
        return 0.0
    sorted_values = sorted(values)
    if len(sorted_values) == 1:
        return sorted_values[0]
    rank = (len(sorted_values) - 1) * pct / 100.0
    lower = math.floor(rank)
    upper = math.ceil(rank)
    if lower == upper:
        return sorted_values[int(rank)]
    lower_value = sorted_values[lower]
    upper_value = sorted_values[upper]
    return lower_value + (upper_value - lower_value) * (rank - lower)


def mean(values: list[float]) -> float:
    if not values:
        return 0.0
    return sum(values) / len(values)


def median(values: list[float]) -> float:
    return percentile(values, 50)


def align_down(value: int, block_size: int) -> int:
    """按 KV cache block 大小向下对齐 prefix_len。

    例如 64k * 90% = 58982.4，block_size=16 时会变成 58976。
    这样所有共享前缀都由完整 block 组成，减少“最后一个不完整 block 是否命中”
    造成的 TTFT 波动。
    """

    if block_size <= 1:
        return value
    return value - (value % block_size)


def effective_prefix_block_size(args: argparse.Namespace) -> int:
    """Return the block/page size used to align generated shared prefixes."""

    return args.dp_cache_block_size if args.dp_cache_block_size > 0 else args.prefix_block_size


def effective_prefix_warmup_requests(args: argparse.Namespace) -> int:
    """Return total prefix warmup requests for the selected warmup path."""

    if args.dp_warmup_endpoints:
        return len(args.dp_warmup_endpoints) * args.dp_prefix_warmup_rounds
    if args.dp_size <= 1:
        return args.prefix_warmup_requests
    return max(args.prefix_warmup_requests, args.dp_size * args.dp_prefix_warmup_rounds)


def build_concurrency_list(args: argparse.Namespace) -> list[int]:
    """生成要测试的并发列表。

    fixed 模式可以显式传 --concurrency-list；否则 fixed/sla-search 都使用
    min/max/step 生成列表。
    """

    if args.concurrency_list:
        return args.concurrency_list
    if args.concurrency_step <= 0:
        raise ValueError("--concurrency-step must be > 0")
    return list(range(args.min_concurrency, args.max_concurrency + 1, args.concurrency_step))


def build_input_lengths(args: argparse.Namespace) -> list[int]:
    """生成输入长度列表。

    --input-lengths 使用 token 数；--input-lengths-k 使用 Ki token，1k=1024。
    如果两者都传，优先使用 --input-lengths-k。
    """

    if args.input_lengths_k:
        return [int(length_k * 1024) for length_k in args.input_lengths_k]
    return args.input_lengths


def create_prefix(input_len: int, prefix_len: int, args: argparse.Namespace) -> list[int]:
    """为一个 input_len 生成稳定共享前缀。

    同一组参数下 prefix_ids 是确定的，方便复现实验。不同 input_len/prefix_len 会
    使用不同随机种子，避免 64k/70k 两组 case 意外共享过多 token。
    """

    rng = random.Random(args.seed + namespace_seed(args.prompt_namespace) + input_len * 9973 + prefix_len)
    return [rng.randint(args.token_id_min, args.token_id_max) for _ in range(prefix_len)]


def create_prompt(
    input_len: int,
    prefix_ids: list[int],
    args: argparse.Namespace,
    unique_seed: int,
) -> list[int]:
    """生成单条 prompt。

    prefix_ids 完全复用，suffix 用 unique_seed 生成，所以同一 case 内：

    - 前 prefix_len 个 token 完全相同，满足 prefix cache 命中率构造。
    - 后 input_len-prefix_len 个 token 不同，避免整条请求都被缓存。
    """

    suffix_len = input_len - len(prefix_ids)
    if suffix_len < 0:
        raise ValueError("prefix_len cannot be greater than input_len")
    rng = random.Random(args.seed + namespace_seed(args.prompt_namespace) + unique_seed)
    suffix_ids = [rng.randint(args.token_id_min, args.token_id_max) for _ in range(suffix_len)]
    return prefix_ids + suffix_ids


def detokenize_to_str(token_id_list: list[int], tokenizer_path: str) -> str:
    """当服务端不接受 token id list 时，将 token ids 解码成字符串 prompt。"""

    global tokenizer
    if tokenizer is None:
        if not tokenizer_path:
            raise ValueError("--tokenizer-path is required when --str-input is set")
        from transformers import AutoTokenizer

        tokenizer = AutoTokenizer.from_pretrained(tokenizer_path)
    return tokenizer.decode(token_id_list)


def completion_payload(
    args: argparse.Namespace,
    prompt: str | list[int],
    output_len: int,
) -> dict[str, Any]:
    """构造 OpenAI completions 兼容请求体。"""

    return {
        "model": args.model,
        "stream": True,
        "max_tokens": output_len,
        "temperature": args.temperature,
        "top_p": args.top_p,
        "prompt": prompt,
        "ignore_eos": args.ignore_eos,
        "stream_options": {"include_usage": True},
    }


def extract_text_delta(chunk_dict: dict[str, Any]) -> str:
    """兼容 completions 和 chat-completions 风格的 stream delta。

    当前脚本调用的是 /v1/completions，正常应从 choices[0].text 取增量。
    这里兼容 delta.content 是为了适配部分服务端实现差异。
    """

    choices = chunk_dict.get("choices") or []
    if not choices:
        return ""
    first_choice = choices[0] or {}
    if "text" in first_choice:
        return first_choice.get("text") or ""
    delta = first_choice.get("delta") or {}
    return delta.get("content") or ""


async def single_request(
    session: aiohttp.ClientSession,
    args: argparse.Namespace,
    prompt_ids: list[int],
    output_len: int,
    base_url: str | None = None,
) -> RequestResult:
    """发送单个 streaming 请求并计算 TTFT/TPOT/ITL。

    SSE 解析要按行处理，而不是假设一次 TCP chunk 只包含一条 data。
    因此这里维护 buffer，把不完整行留到下一次 chunk 再解析。
    """

    prompt: str | list[int]
    if args.str_input:
        prompt = detokenize_to_str(prompt_ids, args.tokenizer_path)
    else:
        prompt = prompt_ids

    request_base_url = base_url or args.base_url
    url = f"{request_base_url.rstrip('/')}/v1/completions"
    data = completion_payload(args, prompt, output_len)
    t_start = time.perf_counter()
    first_token_time: float | None = None
    last_token_time: float | None = None
    end_time = t_start
    generated_events = 0
    itl_values_s: list[float] = []
    usage_data = {
        "prompt_tokens": len(prompt_ids),
        "completion_tokens": 0,
        "total_tokens": len(prompt_ids),
    }
    buffer = ""

    try:
        async with session.post(url, json=data) as response:
            if response.status >= 400:
                text = await response.text()
                return RequestResult(
                    success=False,
                    prompt_tokens=len(prompt_ids),
                    error=f"HTTP {response.status}: {text[:500]}",
                )

            async for raw_chunk in response.content.iter_chunked(args.stream_chunk_bytes):
                now = time.perf_counter()
                buffer += raw_chunk.decode("utf-8", errors="replace")

                # 一个网络 chunk 里可能包含多条 SSE data，也可能只包含半条。
                # splitlines(keepends=True) 后，如果最后一行没有换行符，说明它还不完整，
                # 需要放回 buffer 等下一次网络 chunk 拼完整。
                lines = buffer.splitlines(keepends=True)
                if lines and not lines[-1].endswith(("\n", "\r")):
                    buffer = lines.pop()
                else:
                    buffer = ""

                for line in lines:
                    line = line.strip()
                    if not line or not line.startswith("data:"):
                        continue
                    chunk_str = line[5:].strip()
                    if chunk_str == "[DONE]":
                        end_time = now
                        continue

                    chunk_dict = json.loads(chunk_str)
                    usage = chunk_dict.get("usage")
                    if usage is not None:
                        # vLLM/SGLang 可能只在最后一个 chunk 携带 usage。
                        # 优先相信服务端 usage，拿不到时再用本地估算。
                        usage_data = {
                            "prompt_tokens": int(usage.get("prompt_tokens") or len(prompt_ids)),
                            "completion_tokens": int(usage.get("completion_tokens") or 0),
                            "total_tokens": int(usage.get("total_tokens") or len(prompt_ids)),
                        }

                    text_delta = extract_text_delta(chunk_dict)
                    if text_delta == "":
                        # usage-only 或 role/control chunk 不应作为生成 token 事件。
                        continue

                    generated_events += 1
                    if first_token_time is None:
                        # TTFT = 请求发出到第一次实际文本增量返回。
                        first_token_time = now
                        last_token_time = now
                    else:
                        assert last_token_time is not None
                        # ITL 是相邻 stream 增量之间的间隔，只作为辅助指标。
                        itl_values_s.append(now - last_token_time)
                        last_token_time = now
                    end_time = now

            if buffer.strip().startswith("data:"):
                chunk_str = buffer.strip()[5:].strip()
                if chunk_str and chunk_str != "[DONE]":
                    chunk_dict = json.loads(chunk_str)
                    usage = chunk_dict.get("usage")
                    if usage is not None:
                        usage_data = {
                            "prompt_tokens": int(usage.get("prompt_tokens") or len(prompt_ids)),
                            "completion_tokens": int(usage.get("completion_tokens") or 0),
                            "total_tokens": int(usage.get("total_tokens") or len(prompt_ids)),
                        }
    except Exception as exc:
        return RequestResult(success=False, prompt_tokens=len(prompt_ids), error=repr(exc))

    t_end = time.perf_counter()
    end_time = max(end_time, t_end)
    if first_token_time is None:
        return RequestResult(
            success=False,
            latency_s=t_end - t_start,
            prompt_tokens=len(prompt_ids),
            error="No generated token was observed in the stream",
        )

    completion_tokens = usage_data["completion_tokens"] or generated_events
    total_tokens = usage_data["total_tokens"] or (len(prompt_ids) + completion_tokens)
    ttft_s = first_token_time - t_start
    latency_s = end_time - t_start
    decode_total_s = max(0.0, end_time - first_token_time)
    if completion_tokens > 1:
        # MTP 口径：TPOT 不用 ITL 均值，而用首 token 后的总 decode 耗时
        # 除以后续 token 数。这样不会被多 token 一次返回的 stream 形态误导。
        tpot_s = decode_total_s / (completion_tokens - 1)
    else:
        tpot_s = 0.0

    return RequestResult(
        success=True,
        ttft_s=ttft_s,
        tpot_s=tpot_s,
        latency_s=latency_s,
        mean_itl_s=mean(itl_values_s),
        completion_tokens=completion_tokens,
        prompt_tokens=usage_data["prompt_tokens"],
        total_tokens=total_tokens,
    )


async def run_request_set(
    session: aiohttp.ClientSession,
    args: argparse.Namespace,
    prompts: list[list[int]],
    output_len: int,
    concurrency: int,
    base_url: str | None = None,
) -> tuple[list[RequestResult], float]:
    """按 max concurrency 运行一组请求。

    prompts 的数量是 num_prompts，semaphore 控制同一时刻最多 concurrency 个
    请求在服务端运行。这样 num_prompts 可以大于 concurrency，用多轮 batch 降低抖动。
    """

    semaphore = asyncio.Semaphore(concurrency)

    async def limited_request(prompt_ids: list[int]) -> RequestResult:
        async with semaphore:
            return await single_request(session, args, prompt_ids, output_len, base_url=base_url)

    t_start = time.perf_counter()
    if args.request_rate > 0:
        async def rate_limited_request(request_index: int, prompt_ids: list[int]) -> RequestResult:
            scheduled_start = t_start + request_index / args.request_rate
            delay_s = scheduled_start - time.perf_counter()
            if delay_s > 0:
                await asyncio.sleep(delay_s)
            async with semaphore:
                return await single_request(session, args, prompt_ids, output_len, base_url=base_url)

        results = await asyncio.gather(
            *(rate_limited_request(idx, prompt_ids) for idx, prompt_ids in enumerate(prompts))
        )
    else:
        results = await asyncio.gather(*(limited_request(prompt_ids) for prompt_ids in prompts))
    duration_s = time.perf_counter() - t_start
    return results, duration_s


async def http_warmup(session: aiohttp.ClientSession, args: argparse.Namespace) -> dict[str, Any] | None:
    """轻量 HTTP warmup。

    目的只是预热 TCP 连接、HTTP 路径、服务端基础请求路径，不用于 prefix cache。
    """

    if args.http_warmup_requests <= 0:
        return None
    print(f"HTTP warmup: requests={args.http_warmup_requests}", flush=True)
    prompts = [
        create_prompt(16, [], args, unique_seed=10_000_000 + idx)
        for idx in range(args.http_warmup_requests)
    ]
    concurrency = min(args.http_warmup_requests, max(1, args.min_concurrency))
    results, duration_s = await run_request_set(
        session,
        args,
        prompts,
        output_len=1,
        concurrency=concurrency,
    )
    row = summarize_case(
        args,
        input_len=16,
        output_len=1,
        prefix_len=0,
        cache_hit_ratio=0.0,
        concurrency=concurrency,
        results=results,
        duration_s=duration_s,
        phase="http_warmup",
    )
    print_serving_benchmark_result(row, title="HTTP Warmup Result")
    return row


async def prefix_warmup(
    session: aiohttp.ClientSession,
    args: argparse.Namespace,
    input_len: int,
    prefix_ids: list[int],
) -> dict[str, Any] | None:
    """每个 input_len/cache_hit 组合的 prefix warmup。

    warmup 请求使用同一个共享 prefix，先让服务端 radix/prefix cache 存住目标
    prefix。正式测试仍会重新生成不同 suffix 的请求，避免整条 prompt 完全相同。
    """

    warmup_requests = effective_prefix_warmup_requests(args)
    if warmup_requests <= 0:
        return None
    print(
        f"Prefix warmup: input={input_len}, prefix_len={len(prefix_ids)}, "
        f"requests={warmup_requests}",
        flush=True,
    )
    prompts = [
        create_prompt(input_len, prefix_ids, args, unique_seed=20_000_000 + input_len + idx)
        for idx in range(warmup_requests)
    ]
    concurrency = min(warmup_requests, max(1, args.min_concurrency))
    if args.dp_warmup_endpoints:
        all_results: list[RequestResult] = []
        total_duration_s = 0.0
        endpoint_prompts = [
            create_prompt(
                input_len,
                prefix_ids,
                args,
                unique_seed=20_000_000 + input_len + endpoint_idx * 100_003 + round_idx,
            )
            for endpoint_idx, _ in enumerate(args.dp_warmup_endpoints)
            for round_idx in range(args.dp_prefix_warmup_rounds)
        ]
        print(
            f"DP explicit warmup endpoints: {len(args.dp_warmup_endpoints)}, "
            f"rounds={args.dp_prefix_warmup_rounds}",
            flush=True,
        )
        for endpoint_idx, endpoint in enumerate(args.dp_warmup_endpoints):
            start = endpoint_idx * args.dp_prefix_warmup_rounds
            end = start + args.dp_prefix_warmup_rounds
            endpoint_results, endpoint_duration_s = await run_request_set(
                session,
                args,
                endpoint_prompts[start:end],
                output_len=args.prefix_warmup_output_length,
                concurrency=min(args.dp_prefix_warmup_rounds, max(1, args.min_concurrency)),
                base_url=endpoint,
            )
            all_results.extend(endpoint_results)
            total_duration_s += endpoint_duration_s
        results = all_results
        duration_s = total_duration_s
        concurrency = min(args.dp_prefix_warmup_rounds, max(1, args.min_concurrency))
    else:
        results, duration_s = await run_request_set(
            session,
            args,
            prompts,
            output_len=args.prefix_warmup_output_length,
            concurrency=concurrency,
        )
    row = summarize_case(
        args,
        input_len=input_len,
        output_len=args.prefix_warmup_output_length,
        prefix_len=len(prefix_ids),
        cache_hit_ratio=normalize_cache_hit(args.prefix_cache_hit),
        concurrency=concurrency,
        results=results,
        duration_s=duration_s,
        phase="prefix_warmup",
    )
    print_serving_benchmark_result(row, title="Prefix Warmup Result")
    return row


def summarize_case(
    args: argparse.Namespace,
    input_len: int,
    output_len: int,
    prefix_len: int,
    cache_hit_ratio: float,
    concurrency: int,
    results: list[RequestResult],
    duration_s: float,
    phase: str = "bench",
) -> dict[str, Any]:
    """把一个 case 的所有请求结果聚合成 CSV/JSON 行。"""

    completed = [result for result in results if result.success]
    failed = [result for result in results if not result.success]
    ttft_ms = [result.ttft_s * 1000 for result in completed]
    tpot_ms = [result.tpot_s * 1000 for result in completed]
    itl_ms = [result.mean_itl_s * 1000 for result in completed if result.mean_itl_s > 0]
    total_prompt_tokens = sum(result.prompt_tokens for result in completed)
    total_completion_tokens = sum(result.completion_tokens for result in completed)
    total_tokens = total_prompt_tokens + total_completion_tokens
    num_prompts = len(results)
    rps = len(completed) / duration_s if duration_s > 0 else 0.0
    generate_throughput = total_completion_tokens / duration_s if duration_s > 0 else 0.0
    total_throughput = total_tokens / duration_s if duration_s > 0 else 0.0

    row = {
        "mode": args.mode,
        "prompt_namespace": args.prompt_namespace,
        "dp_size": args.dp_size,
        "dp_prefix_warmup_rounds": args.dp_prefix_warmup_rounds,
        "dp_cache_block_size": args.dp_cache_block_size,
        "effective_prefix_block_size": effective_prefix_block_size(args),
        "effective_prefix_warmup_requests": effective_prefix_warmup_requests(args),
        "dp_warmup_endpoint_count": len(args.dp_warmup_endpoints or []),
        "phase": phase,
        "status": "",
        "error_reason": "",
        "sla_pass": "",
        "cache_hit_pct": cache_hit_ratio * 100,
        "effective_cache_hit_pct": (prefix_len / input_len * 100) if input_len else 0,
        "expected_per_request_cache_hit_pct": (prefix_len / input_len * 100) if input_len else 0,
        "prefix_len": prefix_len,
        "input": input_len,
        "output": output_len,
        "num_prompts": num_prompts,
        "concurrency": concurrency,
        "peak_concurrent_requests": min(concurrency, num_prompts),
        "duration_s": duration_s,
        "rps": rps,
        "total_input_tokens": total_prompt_tokens,
        "total_generated_tokens": total_completion_tokens,
        "generate_throughput_tok_s": generate_throughput,
        "peak_output_throughput_tok_s": "N/A",
        "total_throughput_tok_s": total_throughput,
        "mean_ttft_ms": mean(ttft_ms),
        "median_ttft_ms": median(ttft_ms),
        "p95_ttft_ms": percentile(ttft_ms, 95),
        "p99_ttft_ms": percentile(ttft_ms, 99),
        "mean_tpot_ms": mean(tpot_ms),
        "median_tpot_ms": median(tpot_ms),
        "p95_tpot_ms": percentile(tpot_ms, 95),
        "p99_tpot_ms": percentile(tpot_ms, 99),
        "mean_itl_ms": mean(itl_ms),
        "median_itl_ms": median(itl_ms),
        "p95_itl_ms": percentile(itl_ms, 95),
        "p99_itl_ms": percentile(itl_ms, 99),
        "QPM": rps * 60,
        "completed_requests": len(completed),
        "failed_requests": len(failed),
    }
    if len(completed) == 0:
        row["status"] = "FAIL"
        row["error_reason"] = failed[0].error if failed else "no_completed_requests"
    elif failed and args.fail_on_request_error:
        row["status"] = "FAIL"
        row["error_reason"] = "failed_requests_{}".format(len(failed))
    elif phase == "bench":
        row["sla_pass"] = evaluate_sla(args, row)
        row["status"] = "PASS" if row["sla_pass"] else "FAIL"
        if not row["sla_pass"]:
            row["error_reason"] = "sla_failed"
    else:
        row["sla_pass"] = "N/A"
        row["status"] = "PASS" if not failed else "PARTIAL"
        if failed:
            row["error_reason"] = "failed_requests_{}".format(len(failed))
    return row


def evaluate_sla(args: argparse.Namespace, row: dict[str, Any]) -> bool:
    """按 mean/p95/p99 中指定口径判断 SLA 是否通过。"""

    if row["completed_requests"] == 0:
        return False
    if args.fail_on_request_error and row["failed_requests"] > 0:
        return False
    ttft_key = f"{args.sla_stat}_ttft_ms"
    tpot_key = f"{args.sla_stat}_tpot_ms"
    return row[ttft_key] <= args.ttft_sla_ms and row[tpot_key] <= args.tpot_sla_ms


def format_value(value: Any) -> Any:
    if isinstance(value, float):
        return f"{value:.6f}"
    return value


def append_csv(csv_path: Path, row: dict[str, Any], write_header: bool) -> None:
    """追加写 CSV；第一次写入时输出表头。"""

    with csv_path.open("a", newline="", encoding="utf-8") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=DEFAULT_COLUMNS)
        if write_header:
            writer.writeheader()
        writer.writerow({column: format_value(row.get(column, "")) for column in DEFAULT_COLUMNS})


TABLE_COLUMNS = [
    ("phase", "phase", 12),
    ("mode", "mode", 10),
    ("input", "input", 8),
    ("prefix_len", "prefix", 8),
    ("concurrency", "bs", 4),
    ("num_prompts", "reqs", 6),
    ("duration_s", "dur_s", 9),
    ("rps", "rps", 8),
    ("generate_throughput_tok_s", "gen_tok/s", 10),
    ("total_throughput_tok_s", "tot_tok/s", 10),
    ("mean_ttft_ms", "mean_ttft", 11),
    ("p95_ttft_ms", "p95_ttft", 10),
    ("p99_ttft_ms", "p99_ttft", 10),
    ("mean_tpot_ms", "mean_tpot", 11),
    ("p95_tpot_ms", "p95_tpot", 10),
    ("p99_tpot_ms", "p99_tpot", 10),
    ("failed_requests", "fail", 5),
    ("sla_pass", "sla", 6),
]


def table_cell(value: Any, width: int) -> str:
    if isinstance(value, bool):
        text = "PASS" if value else "FAIL"
    elif isinstance(value, float):
        text = f"{value:.2f}"
    else:
        text = str(value)
    if len(text) > width:
        text = text[: max(0, width - 1)] + "…"
    return text.rjust(width)


def print_metrics_table(rows: list[dict[str, Any]], title: str | None = None) -> None:
    if not rows:
        return
    if title:
        print(f"\n{title}", flush=True)
    header = " | ".join(label.rjust(width) for _, label, width in TABLE_COLUMNS)
    separator = "-+-".join("-" * width for _, _, width in TABLE_COLUMNS)
    print(header, flush=True)
    print(separator, flush=True)
    for row in rows:
        print(
            " | ".join(table_cell(row.get(key, ""), width) for key, _, width in TABLE_COLUMNS),
            flush=True,
        )


def format_metric_value(value: Any) -> str:
    if isinstance(value, bool):
        return "PASS" if value else "FAIL"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return f"{value:.2f}"
    return str(value)


def print_metric_line(label: str, value: Any) -> None:
    print(f"{label:<42}{format_metric_value(value):<10}", flush=True)


def print_serving_benchmark_result(row: dict[str, Any], title: str = "Serving Benchmark Result") -> None:
    print(f"\n============ {title} ============", flush=True)
    print_metric_line("Phase:", row.get("phase", ""))
    print_metric_line("Mode:", row.get("mode", ""))
    print_metric_line("SLA pass:", row.get("sla_pass", ""))
    print_metric_line("Cache hit target (%):", row.get("cache_hit_pct", 0.0))
    print_metric_line("Expected per-request PC hit (%):", row.get("expected_per_request_cache_hit_pct", 0.0))
    print_metric_line("Prefix length:", row.get("prefix_len", 0))
    print_metric_line("Input length:", row.get("input", 0))
    print_metric_line("Output length:", row.get("output", 0))
    print_metric_line("Successful requests:", row.get("completed_requests", 0))
    print_metric_line("Failed requests:", row.get("failed_requests", 0))
    if row.get("phase") == "bench" and row.get("sla_pass") is True and row.get("failed_requests", 0) > 0:
        print(
            "Warning: failed requests were recorded; SLA decision used completed requests only.",
            flush=True,
        )
    print_metric_line("Maximum request concurrency:", row.get("concurrency", 0))
    print_metric_line("Benchmark duration (s):", row.get("duration_s", 0.0))
    print_metric_line("Total input tokens:", row.get("total_input_tokens", 0))
    print_metric_line("Total generated tokens:", row.get("total_generated_tokens", 0))
    print_metric_line("Request throughput (req/s):", row.get("rps", 0.0))
    print_metric_line("Output token throughput (tok/s):", row.get("generate_throughput_tok_s", 0.0))
    print_metric_line("Peak output token throughput (tok/s):", row.get("peak_output_throughput_tok_s", "N/A"))
    print_metric_line("Peak concurrent requests:", row.get("peak_concurrent_requests", 0))
    print_metric_line("Total token throughput (tok/s):", row.get("total_throughput_tok_s", 0.0))
    print("---------------Time to First Token----------------", flush=True)
    print_metric_line("Mean TTFT (ms):", row.get("mean_ttft_ms", 0.0))
    print_metric_line("Median TTFT (ms):", row.get("median_ttft_ms", 0.0))
    print_metric_line("P95 TTFT (ms):", row.get("p95_ttft_ms", 0.0))
    print_metric_line("P99 TTFT (ms):", row.get("p99_ttft_ms", 0.0))
    print("-----Time per Output Token (excl. 1st token)------", flush=True)
    print_metric_line("Mean TPOT (ms):", row.get("mean_tpot_ms", 0.0))
    print_metric_line("Median TPOT (ms):", row.get("median_tpot_ms", 0.0))
    print_metric_line("P95 TPOT (ms):", row.get("p95_tpot_ms", 0.0))
    print_metric_line("P99 TPOT (ms):", row.get("p99_tpot_ms", 0.0))
    print("---------------Inter-token Latency----------------", flush=True)
    print_metric_line("Mean ITL (ms):", row.get("mean_itl_ms", 0.0))
    print_metric_line("Median ITL (ms):", row.get("median_itl_ms", 0.0))
    print_metric_line("P95 ITL (ms):", row.get("p95_itl_ms", 0.0))
    print_metric_line("P99 ITL (ms):", row.get("p99_itl_ms", 0.0))
    print("==================================================", flush=True)


def build_case_prompts(
    args: argparse.Namespace,
    input_len: int,
    prefix_ids: list[int],
    concurrency: int,
    repeat_idx: int,
    request_multiplier: int,
    seed_offset: int,
) -> list[list[int]]:
    """构造一个正式 case 或 warmup case 的全部 prompts。"""

    num_prompts = concurrency * request_multiplier
    return [
        create_prompt(
            input_len,
            prefix_ids,
            args,
            unique_seed=seed_offset + input_len * 101 + concurrency * 10_003 + repeat_idx * 1_000_003 + idx,
        )
        for idx in range(num_prompts)
    ]


async def run_case(
    session: aiohttp.ClientSession,
    args: argparse.Namespace,
    input_len: int,
    prefix_ids: list[int],
    concurrency: int,
) -> tuple[list[RequestResult], float]:
    """执行正式统计 case。

    num_repeats 会把多个重复轮次合并统计。每轮请求数为
    concurrency * request_multiplier。
    """

    all_results: list[RequestResult] = []
    total_duration_s = 0.0
    for repeat_idx in range(args.num_repeats):
        prompts = build_case_prompts(
            args,
            input_len,
            prefix_ids,
            concurrency,
            repeat_idx,
            args.request_multiplier,
            seed_offset=30_000_000,
        )
        results, duration_s = await run_request_set(
            session,
            args,
            prompts,
            output_len=args.output_length,
            concurrency=concurrency,
        )
        all_results.extend(results)
        total_duration_s += duration_s
    return all_results, total_duration_s


async def run_case_warmup(
    session: aiohttp.ClientSession,
    args: argparse.Namespace,
    input_len: int,
    prefix_ids: list[int],
    concurrency: int,
) -> dict[str, Any] | None:
    """执行同输入/同输出/同并发的 case warmup，但不计入最终统计。"""

    if args.case_warmup_repeats <= 0:
        return None
    print(
        f"Case warmup: input={input_len}, concurrency={concurrency}, "
        f"repeats={args.case_warmup_repeats}",
        flush=True,
    )
    all_results: list[RequestResult] = []
    total_duration_s = 0.0
    for repeat_idx in range(args.case_warmup_repeats):
        prompts = build_case_prompts(
            args,
            input_len,
            prefix_ids,
            concurrency,
            repeat_idx,
            args.case_warmup_request_multiplier,
            seed_offset=40_000_000,
        )
        results, duration_s = await run_request_set(
            session,
            args,
            prompts,
            output_len=args.output_length,
            concurrency=concurrency,
        )
        all_results.extend(results)
        total_duration_s += duration_s

    row = summarize_case(
        args,
        input_len=input_len,
        output_len=args.output_length,
        prefix_len=len(prefix_ids),
        cache_hit_ratio=normalize_cache_hit(args.prefix_cache_hit),
        concurrency=concurrency,
        results=all_results,
        duration_s=total_duration_s,
        phase="case_warmup",
    )
    print_serving_benchmark_result(row, title="Case Warmup Result")
    return row


def write_json_report(
    json_path: Path,
    args: argparse.Namespace,
    best_by_input: dict[int, int | None],
    rows: list[dict[str, Any]],
    warmup_rows: list[dict[str, Any]],
) -> None:
    payload: dict[str, Any] = {
        "args": vars_for_json(args),
        "best_by_input": best_by_input,
        "rows": rows,
    }
    if args.save_warmup_results:
        payload["warmup_rows"] = warmup_rows
    json_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")


async def benchmark(args: argparse.Namespace) -> None:
    """主 benchmark 流程。

    对每个 input length：
    1. 计算并对齐 prefix_len。
    2. 生成该 input length 专属共享 prefix。
    3. 做 prefix warmup。
    4. 按并发列表执行正式 case。
    5. sla-search 模式遇到 SLA fail 即停止当前 input length。
    """

    global aiohttp
    import aiohttp

    cache_hit_ratio = normalize_cache_hit(args.prefix_cache_hit)
    input_lengths = build_input_lengths(args)
    concurrency_list = build_concurrency_list(args)
    if not input_lengths:
        raise ValueError("At least one input length is required")
    if not concurrency_list:
        raise ValueError("At least one concurrency is required")

    args.save_path.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime(TIMESTAMP_FORMAT)
    if args.prompt_namespace == "auto":
        args.prompt_namespace = f"auto-{timestamp}-{uuid.uuid4().hex[:8]}"
    print(f"Prompt namespace: {args.prompt_namespace}", flush=True)
    if args.request_rate > 0:
        print(f"Request rate: {args.request_rate:.3f} req/s", flush=True)
    else:
        print("Request rate: unlimited", flush=True)
    print(f"DP size: {args.dp_size}", flush=True)
    print(f"DP prefix warmup rounds: {args.dp_prefix_warmup_rounds}", flush=True)
    print(f"DP warmup endpoint count: {len(args.dp_warmup_endpoints or [])}", flush=True)
    print(f"Effective prefix block size: {effective_prefix_block_size(args)}", flush=True)
    print(f"Effective prefix warmup requests: {effective_prefix_warmup_requests(args)}", flush=True)
    csv_path = args.csv_file or (args.save_path / f"{timestamp}_prefix_cache_benchmark.csv")
    json_path = args.json_file or (args.save_path / f"{timestamp}_prefix_cache_benchmark.json")
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, Any]] = []
    warmup_rows: list[dict[str, Any]] = []
    best_by_input: dict[int, int | None] = {}

    timeout = aiohttp.ClientTimeout(total=args.request_timeout_s)
    connector = aiohttp.TCPConnector(limit=0, ttl_dns_cache=300)
    async with aiohttp.ClientSession(timeout=timeout, connector=connector) as session:
        http_warmup_row = await http_warmup(session, args)
        if http_warmup_row is not None:
            warmup_rows.append(http_warmup_row)
            write_json_report(json_path, args, best_by_input, rows, warmup_rows)

        for input_len in input_lengths:
            raw_prefix_len = int(input_len * cache_hit_ratio)
            prefix_len = align_down(raw_prefix_len, effective_prefix_block_size(args))
            prefix_ids = create_prefix(input_len, prefix_len, args)
            best_by_input[input_len] = None
            print(
                f"\n=== input={input_len}, output={args.output_length}, "
                f"cache_hit={cache_hit_ratio * 100:.2f}%, prefix_len={prefix_len} ===",
                flush=True,
            )
            prefix_warmup_row = await prefix_warmup(session, args, input_len, prefix_ids)
            if prefix_warmup_row is not None:
                warmup_rows.append(prefix_warmup_row)
                write_json_report(json_path, args, best_by_input, rows, warmup_rows)

            for concurrency in concurrency_list:
                print(f"\n--- concurrency={concurrency} ---", flush=True)
                case_warmup_row = await run_case_warmup(session, args, input_len, prefix_ids, concurrency)
                if case_warmup_row is not None:
                    warmup_rows.append(case_warmup_row)
                    write_json_report(json_path, args, best_by_input, rows, warmup_rows)
                results, duration_s = await run_case(session, args, input_len, prefix_ids, concurrency)
                row = summarize_case(
                    args,
                    input_len=input_len,
                    output_len=args.output_length,
                    prefix_len=prefix_len,
                    cache_hit_ratio=cache_hit_ratio,
                    concurrency=concurrency,
                    results=results,
                    duration_s=duration_s,
                    phase="bench",
                )
                rows.append(row)
                append_csv(csv_path, row, write_header=len(rows) == 1)
                write_json_report(json_path, args, best_by_input, rows, warmup_rows)
                print_serving_benchmark_result(row, title="Serving Benchmark Result")

                if row["sla_pass"]:
                    best_by_input[input_len] = concurrency
                elif args.mode == "sla-search":
                    print(
                        f"Stop input={input_len}: concurrency={concurrency} failed SLA. "
                        f"best_concurrency={best_by_input[input_len]}",
                        flush=True,
                    )
                    break

    write_json_report(json_path, args, best_by_input, rows, warmup_rows)
    print("\n=== Final Summary ===", flush=True)
    print_metrics_table(rows, title="Benchmark summary")
    if args.mode == "sla-search":
        for input_len in input_lengths:
            print(f"input={input_len} best_sla_concurrency={best_by_input[input_len]}", flush=True)
    else:
        finished = sorted({row["concurrency"] for row in rows})
        print(f"fixed mode completed_concurrency_list={finished}", flush=True)
    print(f"CSV: {csv_path}", flush=True)
    print(f"JSON: {json_path}", flush=True)


def vars_for_json(args: argparse.Namespace) -> dict[str, Any]:
    result = vars(args).copy()
    for key, value in list(result.items()):
        if isinstance(value, Path):
            result[key] = str(value)
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Prefix cache 命中率 SLA 搜索与指定并发压测工具"
    )
    parser.add_argument("--base-url", type=str, default="http://127.0.0.1:8080", help="OpenAI 兼容服务地址")
    parser.add_argument("--model", type=str, default="DeepSeek-V3", help="请求体中的 model 字段")
    parser.add_argument(
        "--mode",
        choices=["sla-search", "fixed"],
        default="sla-search",
        help="sla-search 找最大达标并发；fixed 按指定并发完整测试",
    )
    parser.add_argument(
        "--input-lengths",
        type=int,
        nargs="+",
        default=[65536, 71680],
        help="输入 token 长度列表，例如 65536 71680",
    )
    parser.add_argument(
        "--input-lengths-k",
        type=float,
        nargs="+",
        default=None,
        help="按 Ki token 指定输入长度，1=1024；如果设置则优先于 --input-lengths",
    )
    parser.add_argument("--output-length", type=int, default=1024, help="每个请求生成 token 数")
    parser.add_argument(
        "--prefix-cache-hit",
        type=float,
        default=0.9,
        help="目标 prefix cache 命中率，0.9 和 90 都表示 90%%",
    )
    parser.add_argument("--prefix-block-size", type=int, default=16, help="prefix_len 向下对齐的 block 大小")
    parser.add_argument("--min-concurrency", type=int, default=1, help="并发搜索起点")
    parser.add_argument("--max-concurrency", type=int, default=64, help="并发搜索终点或 fixed 默认终点")
    parser.add_argument("--concurrency-step", type=int, default=1, help="未设置 --concurrency-list 时的并发步长")
    parser.add_argument("--concurrency-list", type=int, nargs="*", default=None, help="fixed 或自定义测试的并发列表")
    parser.add_argument(
        "--request-multiplier",
        type=int,
        default=16,
        help="num_prompts = concurrency * request_multiplier",
    )
    parser.add_argument("--num-repeats", type=int, default=1, help="正式统计重复轮次，结果合并统计")
    parser.add_argument("--http-warmup-requests", type=int, default=4, help="短请求 HTTP warmup 数量")
    parser.add_argument("--prefix-warmup-requests", type=int, default=1, help="每个 input/cache 组合的 prefix warmup 请求数")
    parser.add_argument("--prefix-warmup-output-length", type=int, default=1, help="prefix warmup 的输出长度")
    parser.add_argument("--case-warmup-repeats", type=int, default=0, help="每个正式 case 前的同形态 warmup 轮数")
    parser.add_argument("--dp-size", type=int, default=1, help="DP rank/engine count for DP-aware prefix warmup")
    parser.add_argument(
        "--dp-prefix-warmup-rounds",
        type=int,
        default=1,
        help="Prefix warmup rounds per DP rank/engine when --dp-size > 1",
    )
    parser.add_argument(
        "--dp-cache-block-size",
        type=int,
        default=0,
        help="Cache page/block size used for prefix alignment; 0 means use --prefix-block-size",
    )
    parser.add_argument(
        "--dp-warmup-endpoints",
        type=str,
        nargs="*",
        default=[],
        help="Optional per-DP base URLs for deterministic prefix warmup coverage",
    )
    parser.add_argument(
        "--case-warmup-request-multiplier",
        type=int,
        default=1,
        help="case warmup 的请求乘数，默认比正式统计轻",
    )
    parser.add_argument("--ttft-sla-ms", type=float, default=5000, help="TTFT SLA 阈值，单位 ms")
    parser.add_argument("--tpot-sla-ms", type=float, default=50, help="TPOT SLA 阈值，单位 ms")
    parser.add_argument("--sla-stat", choices=["mean", "p95", "p99"], default="mean", help="SLA 判定口径")
    parser.add_argument(
        "--fail-on-request-error",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="Treat any failed request as SLA failure; default is to judge SLA from completed requests only",
    )
    parser.add_argument("--temperature", type=float, default=0.0, help="采样 temperature")
    parser.add_argument("--top-p", type=float, default=0.95, help="采样 top_p")
    parser.add_argument("--ignore-eos", action=argparse.BooleanOptionalAction, default=True, help="是否忽略 EOS")
    parser.add_argument("--str-input", action=argparse.BooleanOptionalAction, default=False, help="将 token ids 解码成字符串 prompt")
    parser.add_argument("--tokenizer-path", type=str, default="", help="--str-input 时使用的 tokenizer 路径")
    parser.add_argument("--token-id-min", type=int, default=42, help="随机 token id 最小值")
    parser.add_argument("--token-id-max", type=int, default=10000, help="随机 token id 最大值")
    parser.add_argument("--seed", type=int, default=60, help="随机种子")
    parser.add_argument(
        "--request-rate",
        type=float,
        default=0.0,
        help="Client request launch rate in req/s; <= 0 means unlimited",
    )
    parser.add_argument("--request-timeout-s", type=float, default=7200, help="单请求超时时间，单位秒")
    parser.add_argument("--stream-chunk-bytes", type=int, default=4096, help="读取 streaming 响应的 chunk 大小")
    parser.add_argument("--save-path", type=Path, default=Path("./"), help="CSV/JSON 输出目录")
    parser.add_argument("--csv-file", type=Path, default=None, help="Write CSV to this exact path")
    parser.add_argument("--json-file", type=Path, default=None, help="Write JSON report to this exact path")
    parser.add_argument(
        "--prompt-namespace",
        type=str,
        default="auto",
        help="prompt 隔离命名空间；auto 表示每次运行自动生成，固定值可用于复现实验",
    )
    parser.add_argument(
        "--save-warmup-results",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="是否把 warmup 统计写入 JSON；默认只实时打印，不写正式 CSV",
    )
    args = parser.parse_args()

    if args.min_concurrency <= 0 or args.max_concurrency <= 0:
        raise ValueError("Concurrency values must be > 0")
    if args.request_multiplier <= 0:
        raise ValueError("--request-multiplier must be > 0")
    if args.num_repeats <= 0:
        raise ValueError("--num-repeats must be > 0")
    if args.output_length <= 0:
        raise ValueError("--output-length must be > 0")
    if not math.isfinite(args.request_rate):
        raise ValueError("--request-rate must be a finite number")
    if args.dp_size <= 0:
        raise ValueError("--dp-size must be > 0")
    if args.dp_prefix_warmup_rounds <= 0:
        raise ValueError("--dp-prefix-warmup-rounds must be > 0")
    if args.dp_cache_block_size < 0:
        raise ValueError("--dp-cache-block-size must be >= 0")
    if args.dp_warmup_endpoints and len(args.dp_warmup_endpoints) != args.dp_size:
        raise ValueError("--dp-warmup-endpoints length must equal --dp-size")
    if args.token_id_min > args.token_id_max:
        raise ValueError("--token-id-min must be <= --token-id-max")
    if args.prompt_namespace == "":
        raise ValueError("--prompt-namespace must not be empty; use 'auto' for automatic isolation")
    return args


if __name__ == "__main__":
    asyncio.run(benchmark(parse_args()))

