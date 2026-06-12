#!/usr/bin/env python3
"""Extract Mooncake transfer topology and failure signals from a role log."""

import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path


def utc_now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def set_path(data, dotted, value):
    current = data
    parts = dotted.split(".")
    for key in parts[:-1]:
        child = current.get(key)
        if not isinstance(child, dict):
            child = {}
            current[key] = child
        current = child
    current[parts[-1]] = value


def parse_log(text):
    protocols = sorted(set(re.findall(r"using\s+([A-Za-z0-9_+-]+)\s+as its protocol", text, re.I)))
    hcas = sorted(set(re.findall(r"Device\s+(mlx5_\d+)\s+port\s+\d+\s+is available", text)))
    gid_indices = sorted(set(int(value) for value in re.findall(r"GID_Index\s+(\d+)", text)))
    listeners = sorted(set(re.findall(r"listening on\s+([^\s]+)", text)))
    counts = [int(value) for value in re.findall(r"Topology discovery complete\. Found\s+(\d+)\s+HCAs", text)]
    return {
        "protocol": ",".join(protocols),
        "detected_hcas": ",".join(hcas),
        "detected_hca_count": max(counts) if counts else len(hcas),
        "gid_indices": ",".join(str(value) for value in gid_indices),
        "listening_addresses": ",".join(listeners),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--role", required=True, choices=("prefill", "decode"))
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--configured-hcas", default="")
    args = parser.parse_args()

    if not args.log.exists():
        raise SystemExit("mooncake_transfer_log_missing={}".format(args.log))
    text = args.log.read_text(encoding="utf-8", errors="replace")
    parsed = parse_log(text)
    configured = {item.strip() for item in args.configured_hcas.split(",") if item.strip()}
    detected = {item for item in parsed["detected_hcas"].split(",") if item}
    outside = sorted(detected - configured) if configured else []

    state = {}
    if args.state.exists():
        state = json.loads(args.state.read_text(encoding="utf-8-sig"))
    prefix = "pd.transfer.{}".format(args.role)
    for key, value in parsed.items():
        set_path(state, prefix + "." + key, value)
    set_path(state, prefix + ".configured_nccl_hcas", args.configured_hcas)
    set_path(state, prefix + ".hcas_outside_nccl_config", ",".join(outside))
    if parsed["protocol"]:
        set_path(state, "pd.transfer.protocol", parsed["protocol"])
    if not state.get("pd", {}).get("transfer", {}).get("status"):
        set_path(state, "pd.transfer.status", "DISCOVERED")
    state["updated_at"] = utc_now_iso()
    args.state.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print("MOONCAKE_TRANSFER_ROLE={}".format(args.role))
    print("MOONCAKE_PROTOCOL={}".format(parsed["protocol"] or "unknown"))
    print("MOONCAKE_DETECTED_HCAS={}".format(parsed["detected_hcas"] or "none"))
    if outside:
        print("WARN_MOONCAKE_HCA_OUTSIDE_NCCL_CONFIG={}".format(",".join(outside)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
