#!/usr/bin/env python3
"""更新 vLLM 性能测试运行状态文件。兼容 Python 3.6+。"""

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path


def parse_value(value):
    if value == "null":
        return None
    if value == "true":
        return True
    if value == "false":
        return False
    try:
        if "." in value:
            return float(value)
        return int(value)
    except ValueError:
        return value


def set_path(data, dotted_key, value):
    current = data
    parts = dotted_key.split(".")
    for part in parts[:-1]:
        child = current.get(part)
        if not isinstance(child, dict):
            child = {}
            current[part] = child
        current = child
    current[parts[-1]] = value


def utc_now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def main():
    parser = argparse.ArgumentParser(description="更新 vLLM 性能测试 state.json")
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--set", action="append", default=[], dest="sets", metavar="KEY=VALUE")
    parser.add_argument("--reset", action="store_true")
    args = parser.parse_args()

    data = {}
    if args.state.exists() and not args.reset:
        data = json.loads(args.state.read_text(encoding="utf-8-sig"))

    for item in args.sets:
        if "=" not in item:
            raise SystemExit("--set 参数必须是 KEY=VALUE: {}".format(item))
        key, value = item.split("=", 1)
        set_path(data, key, parse_value(value))

    data["updated_at"] = utc_now_iso()
    args.state.parent.mkdir(parents=True, exist_ok=True)
    args.state.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
