#!/usr/bin/env python3
"""Classify vLLM startup failures and persist the first actionable cause."""

import argparse
import json
import re
from pathlib import Path


KV_CACHE_PATTERN = re.compile(
    r"max\s+seq\s+len\s*\((?P<model_max>\d+)\).*?"
    r"\((?P<required>[0-9.]+)\s+GiB\s+KV\s+cache\s+is\s+needed.*?"
    r"available\s+KV\s+cache\s+memory\s*\((?P<available>[0-9.]+)\s+GiB\).*?"
    r"estimated\s+maximum\s+model\s+length\s+is\s+(?P<estimated>\d+)",
    re.IGNORECASE | re.DOTALL,
)


def analyze(text, fallback_reason="log_failure_signal"):
    match = KV_CACHE_PATTERN.search(text)
    if match:
        return {
            "reason": "kv_cache_capacity_insufficient",
            "model_max_sequence_length": int(match.group("model_max")),
            "required_kv_cache_gib": float(match.group("required")),
            "available_kv_cache_gib": float(match.group("available")),
            "estimated_max_model_len": int(match.group("estimated")),
        }
    lowered = text.lower()
    if "please install mooncake" in lowered or "mooncake_transfer_engine" in lowered:
        return {"reason": "mooncake_transfer_engine_missing"}
    if "modulenotfounderror" in lowered or "importerror" in lowered or "no module named" in lowered:
        return {"reason": "python_dependency_missing"}
    if re.search(r"out\s+of\s+memory|\boom\b|\bkilled\b", text, re.IGNORECASE):
        return {"reason": "out_of_memory"}
    return {"reason": fallback_reason}


def set_path(data, path, value):
    current = data
    parts = path.split(".")
    for key in parts[:-1]:
        current = current.setdefault(key, {})
    current[parts[-1]] = value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--role", required=True, choices=("prefill", "decode"))
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--fallback-reason", default="log_failure_signal")
    args = parser.parse_args()

    text = args.log.read_text(encoding="utf-8", errors="replace") if args.log.exists() else ""
    diagnostic = analyze(text, args.fallback_reason)
    state = json.loads(args.state.read_text(encoding="utf-8-sig")) if args.state.exists() else {}
    tail = "\n".join(text.splitlines()[-40:])[-4000:]
    set_path(state, "status", "SERVICE_FAILED")
    set_path(state, "pd.roles.{}.status".format(args.role), "FAILED")
    set_path(state, "pd.roles.{}.log_tail".format(args.role), tail)
    set_path(state, "failure.reason", diagnostic["reason"])
    set_path(state, "failure.detail", args.role)
    for key, value in diagnostic.items():
        if key != "reason":
            set_path(state, "failure.diagnostics.{}".format(key), value)
    args.state.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("FAILURE_REASON={}".format(diagnostic["reason"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
