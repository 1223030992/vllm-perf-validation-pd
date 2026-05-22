#!/usr/bin/env python3
"""Parse Prefix Cache hit rate observations from a vLLM server log.

The parser is intentionally permissive because vendor builds often log this
metric with slightly different labels. Values in [0, 1] are treated as ratios;
larger values are treated as percentages.
"""

import argparse
import json
import re
from pathlib import Path


PATTERNS = [
    re.compile(
        r"(?i)(?:prefix[\s_-]*cache|pc|cache)[^\n]{0,120}?"
        r"(?:hit[\s_-]*(?:rate|ratio)|命中率)[^\n]{0,80}?"
        r"([0-9]+(?:\.[0-9]+)?)\s*%"
    ),
    re.compile(
        r"(?i)(?:prefix[\s_-]*cache|pc|cache)[^\n]{0,120}?"
        r"(?:hit[\s_-]*(?:rate|ratio)|命中率)[^\n]{0,80}?"
        r"([01](?:\.[0-9]+)?)"
    ),
]


def to_pct(raw):
    value = float(raw)
    if 0 <= value <= 1:
        return value * 100
    return value


def parse_observations(text):
    observations = []
    for line_no, line in enumerate(text.splitlines(), 1):
        for pattern in PATTERNS:
            match = pattern.search(line)
            if match:
                observations.append(
                    {
                        "line_no": line_no,
                        "observed_pct": round(to_pct(match.group(1)), 4),
                        "line": line.strip(),
                    }
                )
                break
    return observations


def main():
    parser = argparse.ArgumentParser(description="Parse Prefix Cache hit rate from server log")
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--target", required=True, type=float)
    parser.add_argument("--tolerance", type=float, default=1.0)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    if not args.log.exists():
        raise SystemExit("PCHIT_LOG_NOT_FOUND: {}".format(args.log))

    observations = parse_observations(args.log.read_text(encoding="utf-8", errors="ignore"))
    if not observations:
        result = {
            "status": "PCHIT_HIT_RATE_NOT_FOUND",
            "target_pct": args.target,
            "tolerance_pct": args.tolerance,
            "observed_pct": None,
            "line_no": None,
            "line": "",
        }
        if args.json:
            print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        else:
            print("STATUS={}".format(result["status"]))
        return 1

    latest = observations[-1]
    observed = latest["observed_pct"]
    passed = observed >= (args.target - args.tolerance)
    result = {
        "status": "PASS" if passed else "WAITING",
        "target_pct": args.target,
        "tolerance_pct": args.tolerance,
        "observed_pct": observed,
        "line_no": latest["line_no"],
        "line": latest["line"],
    }
    if args.json:
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    else:
        print("STATUS={}".format(result["status"]))
        print("OBSERVED_PC_HIT_PCT={}".format(result["observed_pct"]))
        print("PC_HIT_LOG_LINE_NO={}".format(result["line_no"]))
        print("PC_HIT_LOG_LINE={}".format(result["line"]))
    return 0 if passed else 2


if __name__ == "__main__":
    raise SystemExit(main())
