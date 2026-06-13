#!/usr/bin/env python3
"""Validate runtime memory controls and benchmark lengths before remote actions."""

import argparse
import math


def positive_int(value, name):
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        raise ValueError("{} must be a positive integer".format(name))
    if parsed <= 0:
        raise ValueError("{} must be a positive integer".format(name))
    return parsed


def validate(max_model_len, gpu_memory_utilization, test_mode, input_lens, output_len):
    limit = None
    if max_model_len not in (None, ""):
        limit = positive_int(max_model_len, "max_model_len")

    if gpu_memory_utilization not in (None, ""):
        try:
            utilization = float(gpu_memory_utilization)
        except (TypeError, ValueError):
            raise ValueError("gpu_memory_utilization must be greater than 0 and at most 1")
        if not math.isfinite(utilization) or not 0 < utilization <= 1:
            raise ValueError("gpu_memory_utilization must be greater than 0 and at most 1")

    inputs = [positive_int(value, "input_len") for value in str(input_lens).replace(",", " ").split()]
    if not inputs:
        raise ValueError("at least one input length is required")
    output = positive_int(output_len, "output_len")
    required = max(inputs) + output
    if limit is not None and required > limit:
        raise ValueError(
            "{} test requires {} tokens but max_model_len is {}".format(
                test_mode, required, limit
            )
        )
    return {"required_sequence_length": required, "max_model_len": limit}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--max-model-len", default="")
    parser.add_argument("--gpu-memory-utilization", default="")
    parser.add_argument("--test-mode", required=True, choices=("custom", "pchit"))
    parser.add_argument("--input-lens", required=True)
    parser.add_argument("--output-len", required=True)
    args = parser.parse_args()
    try:
        result = validate(
            args.max_model_len,
            args.gpu_memory_utilization,
            args.test_mode,
            args.input_lens,
            args.output_len,
        )
    except ValueError as exc:
        print("PD_INVOCATION_REJECTED=1")
        print("TASK_STARTED=0")
        print("FAILURE_STAGE=validate_runtime_limits")
        print("ARGUMENT_ERROR={}".format(exc))
        return 2
    print("REQUIRED_SEQUENCE_LENGTH={}".format(result["required_sequence_length"]))
    print("MAX_MODEL_LEN_EFFECTIVE={}".format(result["max_model_len"] or "unset"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
