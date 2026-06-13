#!/usr/bin/env python3
"""Validate run_pd_task.sh arguments before any task state or remote action."""

import sys


VALUE_OPTIONS = {
    "--abbr",
    "--bench-timeout",
    "--cleanup-state",
    "--concurrencies",
    "--config",
    "--container-model-path",
    "--container-prefix",
    "--date",
    "--decode-node",
    "--decode-port",
    "--decode-service-ip",
    "--decode-vllm-host-ip",
    "--deployment",
    "--home-root",
    "--host-home-root",
    "--host-model-path",
    "--gpu-memory-utilization",
    "--image",
    "--image-digest",
    "--image-id",
    "--image-prefix",
    "--input-lens",
    "--interval",
    "--mooncake-dest-device-affinity",
    "--mooncake-wheel",
    "--max-model-len",
    "--nccl-ib-hca",
    "--network-ifname",
    "--num-prompts-mult",
    "--output-container-root",
    "--output-host-root",
    "--output-len",
    "--pc-hit-target",
    "--pchit-batches",
    "--pchit-input-len",
    "--pchit-mode",
    "--pchit-output-len",
    "--percentiles",
    "--prefill-node",
    "--prefill-port",
    "--prefill-service-ip",
    "--prefill-transfer-port",
    "--prefill-vllm-host-ip",
    "--profile",
    "--proxy-port",
    "--proxy-request-timeout",
    "--proxy-timeout",
    "--ready-timeout",
    "--request-rate",
    "--run-id",
    "--skill-host-root",
    "--sla-stat",
    "--test-preset",
    "--tpot-sla-ms",
    "--ttft-sla-ms",
    "--user",
}

FLAG_OPTIONS = {
    "--assume-yes",
    "--dry-run",
    "--help",
    "--keep-containers-on-failure",
    "--verbose-dry-run",
}

ARGUMENT_HINTS = {
    "--prefill-host-ip": "use --prefill-service-ip and --prefill-vllm-host-ip",
    "--decode-host-ip": "use --decode-service-ip and --decode-vllm-host-ip",
    "--nic": "use --network-ifname",
    "--hca": "use --nccl-ib-hca",
    "--input-length": "use --input-lens",
    "--output-length": "use --output-len",
    "--concurrency": "use --concurrencies",
    "--test-mode": "test mode is selected by --test-preset; do not pass --test-mode",
    "--num-prompts": "use a test preset or --num-prompts-mult; there is no direct --num-prompts option",
}


def rejection(argument, hint):
    return [
        "PD_INVOCATION_REJECTED=1",
        "TASK_STARTED=0",
        "FAILURE_STAGE=parse_arguments",
        "ARGUMENT_ERROR={}".format(argument),
        "ARGUMENT_HINT={}".format(hint),
    ]


def validate(argv):
    index = 0
    while index < len(argv):
        argument = argv[index]
        if argument in FLAG_OPTIONS:
            index += 1
            continue
        if argument in VALUE_OPTIONS:
            if index + 1 >= len(argv) or argv[index + 1].startswith("--"):
                return rejection(argument, "this option requires one value; correct the command and start a new invocation")
            index += 2
            continue
        if argument.startswith("--"):
            hint = ARGUMENT_HINTS.get(
                argument,
                "use only the documented run_pd_task.sh options; do not infer aliases or retry this invocation",
            )
            return rejection(argument, hint)
        return rejection(
            argument,
            "unexpected positional argument; use the documented option form and do not retry this invocation",
        )
    return []


def main(argv=None):
    errors = validate(list(sys.argv[1:] if argv is None else argv))
    if not errors:
        return 0
    print("\n".join(errors))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
