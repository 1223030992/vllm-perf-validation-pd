#!/usr/bin/env python3
"""输出 state.json 摘要。兼容 Python 3.6+。"""

import argparse
import csv
import json
from pathlib import Path


def deep_get(data, path, default=None):
    current = data
    for key in path.split("."):
        if not isinstance(current, dict) or key not in current:
            return default
        current = current[key]
    return current


def as_float(value):
    if value in (None, ""):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def first_number(row, keys):
    for key in keys:
        value = as_float(row.get(key))
        if value is not None:
            return value
    return None


def csv_summary(csv_file):
    if not csv_file or not Path(csv_file).exists():
        return {}
    with Path(csv_file).open("r", encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        return {}

    def values(keys):
        result = []
        for row in rows:
            value = first_number(row, keys)
            if value is not None:
                result.append(value)
        return result

    summary = {}
    metrics = {
        "qps": ["rps", "request_throughput", "qps"],
        "output_tok_s": ["generate_throughput_tok_s", "output_token_throughput"],
        "total_tok_s": ["total_throughput_tok_s", "total_token_throughput"],
        "ttft_ms": ["mean_ttft", "mean_ttft_ms"],
        "tpot_ms": ["mean_tpot", "mean_tpot_ms"],
        "itl_p99_ms": ["p99_itl", "p99_itl_ms"],
    }
    for label, keys in metrics.items():
        vals = values(keys)
        if vals:
            summary[label] = max(vals)
    return summary


def main():
    parser = argparse.ArgumentParser(description="查看 vLLM 性能测试 state.json")
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--full", action="store_true")
    args = parser.parse_args()

    if not args.state.exists():
        raise SystemExit("state 文件不存在: {}".format(args.state))
    state = json.loads(args.state.read_text(encoding="utf-8-sig"))

    if args.full:
        print(json.dumps(state, ensure_ascii=False, indent=2))
        return 0

    fields = [
        ("status", "status"),
        ("node", "node"),
        ("container", "container.name"),
        ("image", "image"),
        ("model", "model.name"),
        ("served_model_id", "model.served_model_id"),
        ("bench_model_id", "model.bench_model_id"),
        ("work_dir_host", "paths.work_dir_host"),
        ("work_dir_container", "paths.work_dir_container"),
        ("csv_file_host", "paths.csv_file_host"),
        ("report_json_host", "paths.report_json_host"),
        ("report_md_host", "paths.report_md_host"),
        ("ops_version", "ops.version"),
        ("stop_status", "status"),
        ("port_released", "service.port_released"),
        ("failure_reason", "failure.reason"),
    ]
    for label, path in fields:
        value = deep_get(state, path)
        if value not in (None, ""):
            print("{}={}".format(label.upper(), value))

    csv_file = deep_get(state, "paths.csv_file_host") or deep_get(state, "paths.csv_file")
    for label, value in sorted(csv_summary(csv_file).items()):
        print("{}={}".format(label.upper(), value))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
