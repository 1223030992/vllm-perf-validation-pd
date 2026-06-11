#!/usr/bin/env python3
"""Print a compact summary for a PD task state.json."""

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
        "pchit_effective_pct": ["effective_cache_hit_pct"],
        "pchit_best_sla_concurrency": ["concurrency"],
    }
    for label, keys in metrics.items():
        vals = values(keys)
        if vals:
            summary[label] = max(vals)

    completed = values(["completed_requests"])
    failed = values(["failed_requests"])
    if completed:
        summary["completed_requests"] = int(sum(completed))
    if failed:
        summary["failed_requests"] = int(sum(failed))
    return summary


def emit_field(label, state, *paths):
    for path in paths:
        value = deep_get(state, path)
        if value not in (None, ""):
            print("{}={}".format(label.upper(), value))
            return


def main():
    parser = argparse.ArgumentParser(description="Show vllm-perf-validation-pd state.json")
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--full", action="store_true")
    args = parser.parse_args()

    if not args.state.exists():
        raise SystemExit("state_file_missing: {}".format(args.state))
    state = json.loads(args.state.read_text(encoding="utf-8-sig"))

    if args.full:
        print(json.dumps(state, ensure_ascii=False, indent=2))
        return 0

    field_groups = [
        ("status", ["status"]),
        ("failure_reason", ["failure.reason"]),
        ("failure_stage", ["failure.stage"]),
        ("config", ["config.path"]),
        ("image", ["image"]),
        ("model", ["model.name", "model.container_model_path"]),
        ("served_model_id", ["model.served_model_id"]),
        ("bench_model_id", ["model.bench_model_id"]),
        ("bench_model_id_source", ["model.bench_model_id_source"]),
        ("work_dir_host", ["paths.work_dir_host"]),
        ("work_dir_container", ["paths.work_dir_container"]),
        ("csv_file_host", ["paths.csv_file_host", "paths.csv_file"]),
        ("report_json_host", ["paths.report_json_host"]),
        ("report_md_host", ["paths.report_md_host"]),
        ("ops_version", ["ops.version"]),
        ("prefill_node", ["pd.roles.prefill.node", "roles.prefill.node"]),
        ("prefill_container", ["pd.roles.prefill.container", "roles.prefill.container"]),
        ("prefill_service_ip", ["pd.roles.prefill.service_ip", "roles.prefill.service_ip"]),
        ("prefill_vllm_host_ip", ["pd.roles.prefill.vllm_host_ip", "roles.prefill.vllm_host_ip"]),
        ("prefill_port", ["pd.roles.prefill.port", "roles.prefill.port"]),
        ("prefill_transfer_port", ["pd.roles.prefill.transfer_port", "roles.prefill.transfer_port"]),
        ("decode_node", ["pd.roles.decode.node", "roles.decode.node"]),
        ("decode_container", ["pd.roles.decode.container", "roles.decode.container"]),
        ("decode_service_ip", ["pd.roles.decode.service_ip", "roles.decode.service_ip"]),
        ("decode_vllm_host_ip", ["pd.roles.decode.vllm_host_ip", "roles.decode.vllm_host_ip"]),
        ("decode_port", ["pd.roles.decode.port", "roles.decode.port"]),
        ("proxy_node", ["pd.proxy.node", "proxy.node"]),
        ("proxy_container", ["pd.proxy.container", "proxy.container"]),
        ("proxy_port", ["pd.proxy.port", "proxy.port"]),
        ("proxy_prefill_url", ["pd.proxy.prefill_url", "proxy.prefill_url"]),
        ("proxy_decode_url", ["pd.proxy.decode_url", "proxy.decode_url"]),
        ("pchit_benchmark_mode", ["pchit.benchmark.mode"]),
        ("pchit_target_pct", ["pchit.benchmark.target_pct"]),
        ("pchit_effective_pct", ["pchit.benchmark.effective_cache_hit_pct"]),
        ("pchit_best_sla_concurrency", ["pchit.benchmark.best_sla_concurrency"]),
    ]
    for label, paths in field_groups:
        emit_field(label, state, *paths)

    csv_file = deep_get(state, "paths.csv_file_host") or deep_get(state, "paths.csv_file")
    for label, value in sorted(csv_summary(csv_file).items()):
        print("{}={}".format(label.upper(), value))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
