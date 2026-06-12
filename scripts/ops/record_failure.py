#!/usr/bin/env python3
"""Record a PD stage failure while preserving a more specific child error."""

import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path


ERROR_PATTERNS = [
    (r"(?:DOCKER|PD)_IMAGE_ID_MISMATCH", "docker_image_id_mismatch"),
    (r"DOCKER_IMAGE_NOT_FOUND", "docker_image_not_found"),
    (r"HOST_MODEL_PATH_NOT_FOUND", "host_model_path_missing"),
    (r"REQUIRED_SCRIPT_NOT_FOUND", "required_script_missing"),
    (r"PORT_IN_USE", "port_in_use"),
    (r"mooncake_install_failed", "mooncake_install_failed"),
    (r"mooncake_transfer_engine_missing", "mooncake_transfer_engine_missing"),
]


def utc_now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def deep_get(data, path):
    current = data
    for key in path.split("."):
        if not isinstance(current, dict) or key not in current:
            return None
        current = current[key]
    return current


def set_path(data, path, value):
    current = data
    parts = path.split(".")
    for key in parts[:-1]:
        current = current.setdefault(key, {})
    current[parts[-1]] = value


def classify(stage, output):
    for pattern, reason in ERROR_PATTERNS:
        if re.search(pattern, output, re.IGNORECASE):
            return reason
    return "{}_failed".format(stage)


def summarize(output):
    lines = [line.rstrip() for line in output.splitlines() if line.strip()]
    return "\n".join(lines[-40:])[-4000:]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--stage", required=True)
    parser.add_argument("--exit-code", required=True, type=int)
    parser.add_argument("--output-file", type=Path)
    args = parser.parse_args()

    state = {}
    if args.state.exists():
        state = json.loads(args.state.read_text(encoding="utf-8-sig"))
    output = ""
    if args.output_file and args.output_file.exists():
        output = args.output_file.read_text(encoding="utf-8", errors="replace")

    set_path(state, "status", "TASK_FAILED")
    set_path(state, "failure.stage", args.stage)
    set_path(state, "failure.exit_code", args.exit_code)
    if not deep_get(state, "failure.reason"):
        set_path(state, "failure.reason", classify(args.stage, output))
    if not deep_get(state, "failure.detail"):
        set_path(state, "failure.detail", summarize(output) or args.stage)
    state["updated_at"] = utc_now_iso()
    args.state.parent.mkdir(parents=True, exist_ok=True)
    args.state.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
