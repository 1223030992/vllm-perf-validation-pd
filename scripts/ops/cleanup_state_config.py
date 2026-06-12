#!/usr/bin/env python3
"""Read the minimum trusted cleanup coordinates from a PD state file."""

import argparse
import json
import shlex
from pathlib import Path


def deep_get(data, dotted):
    current = data
    for key in dotted.split("."):
        if not isinstance(current, dict) or key not in current:
            return ""
        current = current[key]
    return "" if current is None else str(current)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True, type=Path)
    args = parser.parse_args()
    data = json.loads(args.state.read_text(encoding="utf-8-sig"))
    fields = {
        "CLEANUP_PREFILL_NODE": "pd.roles.prefill.node",
        "CLEANUP_PREFILL_CONTAINER": "pd.roles.prefill.container",
        "CLEANUP_PREFILL_PORT": "pd.roles.prefill.port",
        "CLEANUP_DECODE_NODE": "pd.roles.decode.node",
        "CLEANUP_DECODE_CONTAINER": "pd.roles.decode.container",
        "CLEANUP_DECODE_PORT": "pd.roles.decode.port",
    }
    values = {name: deep_get(data, path) for name, path in fields.items()}
    missing = [name for name, value in values.items() if not value]
    if missing:
        raise SystemExit("cleanup_state_missing_fields={}".format(",".join(missing)))
    for name, value in values.items():
        print("{}={}".format(name, shlex.quote(value)))


if __name__ == "__main__":
    raise SystemExit(main())
