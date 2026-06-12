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


def csv_summary(csv_file, test_mode=""):
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
    if test_mode == "pchit":
        metrics.update({"pchit_effective_pct": ["effective_cache_hit_pct"]})
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
    if test_mode == "pchit":
        passing = []
        for row in rows:
            status = str(row.get("status") or "").strip().upper()
            sla_pass = str(row.get("sla_pass") or "").strip().lower()
            if status == "PASS" or sla_pass in {"true", "1", "yes", "pass"}:
                value = first_number(row, ["concurrency"])
                if value is not None:
                    passing.append(value)
        if passing:
            summary["pchit_best_sla_concurrency"] = int(max(passing))
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
        ("failure_detail", ["failure.detail"]),
        ("failure_exit_code", ["failure.exit_code"]),
        ("config", ["config.path"]),
        ("image", ["image"]),
        ("prefill_image_id", ["image_ids.prefill"]),
        ("decode_image_id", ["image_ids.decode"]),
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
        ("prefill_status", ["pd.roles.prefill.status"]),
        ("prefill_readiness_seconds", ["pd.roles.prefill.readiness_duration_seconds"]),
        ("prefill_served_model_id", ["pd.roles.prefill.served_model_id"]),
        ("prefill_runtime", ["pd.runtime.prefill.status"]),
        ("prefill_mooncake_version", ["pd.runtime.prefill.mooncake_version"]),
        ("decode_node", ["pd.roles.decode.node", "roles.decode.node"]),
        ("decode_container", ["pd.roles.decode.container", "roles.decode.container"]),
        ("decode_service_ip", ["pd.roles.decode.service_ip", "roles.decode.service_ip"]),
        ("decode_vllm_host_ip", ["pd.roles.decode.vllm_host_ip", "roles.decode.vllm_host_ip"]),
        ("decode_port", ["pd.roles.decode.port", "roles.decode.port"]),
        ("decode_status", ["pd.roles.decode.status"]),
        ("decode_readiness_seconds", ["pd.roles.decode.readiness_duration_seconds"]),
        ("decode_served_model_id", ["pd.roles.decode.served_model_id"]),
        ("decode_runtime", ["pd.runtime.decode.status"]),
        ("decode_mooncake_version", ["pd.runtime.decode.mooncake_version"]),
        ("mooncake_dest_device_affinity", ["pd.runtime.mooncake_dest_device_affinity"]),
        ("transfer_status", ["pd.transfer.status"]),
        ("transfer_protocol", ["pd.transfer.protocol"]),
        ("transfer_failure_reason", ["pd.transfer.failure_reason"]),
        ("transfer_error_summary", ["pd.transfer.error_summary"]),
        ("prefill_detected_hcas", ["pd.transfer.prefill.detected_hcas"]),
        ("prefill_gid_indices", ["pd.transfer.prefill.gid_indices"]),
        ("decode_detected_hcas", ["pd.transfer.decode.detected_hcas"]),
        ("decode_gid_indices", ["pd.transfer.decode.gid_indices"]),
        ("proxy_node", ["pd.proxy.node", "proxy.node"]),
        ("proxy_container", ["pd.proxy.container", "proxy.container"]),
        ("proxy_port", ["pd.proxy.port", "proxy.port"]),
        ("proxy_status", ["pd.proxy.status"]),
        ("proxy_attempts", ["pd.proxy.attempts"]),
        ("proxy_readiness_seconds", ["pd.proxy.readiness_duration_seconds"]),
        ("proxy_listener_status", ["pd.proxy.listener.status"]),
        ("proxy_listener_error", ["pd.proxy.listener.error"]),
        ("proxy_prefill_upstream_status", ["pd.proxy.upstream.prefill.status"]),
        ("proxy_decode_upstream_status", ["pd.proxy.upstream.decode.status"]),
        ("proxy_bootstrap_status", ["pd.proxy.bootstrap.status"]),
        ("proxy_smoke_status", ["pd.proxy.smoke.status"]),
        ("proxy_smoke_http_code", ["pd.proxy.smoke.http_code"]),
        ("proxy_smoke_error", ["pd.proxy.smoke.error"]),
        ("proxy_prefill_url", ["pd.proxy.prefill_url", "proxy.prefill_url"]),
        ("proxy_decode_url", ["pd.proxy.decode_url", "proxy.decode_url"]),
        ("cleanup_policy", ["cleanup.policy"]),
        ("containers_preserved", ["cleanup.containers_preserved"]),
        ("cleanup_status", ["cleanup.status"]),
        ("test_status", ["test.status"]),
        ("execution_status", ["test.execution_status", "report.execution_status"]),
        ("benchmark_status", ["test.benchmark_status", "report.benchmark_status"]),
        ("sla_status", ["test.sla_status", "report.sla_status"]),
        ("test_current_case", ["test.current_case"]),
        ("test_heartbeat_at", ["test.heartbeat_at"]),
        ("test_elapsed_seconds", ["test.elapsed_seconds"]),
        ("bench_timeout_seconds", ["test.bench_timeout_seconds"]),
        ("pchit_benchmark_mode", ["pchit.benchmark.mode"]),
        ("pchit_target_pct", ["pchit.benchmark.target_pct"]),
        ("pchit_effective_pct", ["pchit.benchmark.effective_cache_hit_pct"]),
        ("pchit_best_sla_concurrency", ["pchit.benchmark.best_sla_concurrency"]),
    ]
    for label, paths in field_groups:
        emit_field(label, state, *paths)

    csv_file = deep_get(state, "paths.csv_file_host") or deep_get(state, "paths.csv_file")
    test_mode = str(deep_get(state, "test.mode", "") or "").lower()
    for label, value in sorted(csv_summary(csv_file, test_mode).items()):
        print("{}={}".format(label.upper(), value))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
