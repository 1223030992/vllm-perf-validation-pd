#!/usr/bin/env python3
"""Create a user-local PD deployment configuration."""

import argparse
import os
import re
import tempfile
from pathlib import Path


ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")


def quote(value):
    text = "" if value is None else str(value)
    return '"{}"'.format(text.replace("\\", "\\\\").replace('"', '\\"'))


def render(args):
    prefill_host = args.prefill_vllm_host_ip or args.prefill_service_ip
    decode_host = args.decode_vllm_host_ip or args.decode_service_ip
    lines = [
        "deployment:",
        f"  id: {quote(args.deployment_id)}",
        f"  owner: {quote(args.user)}",
        f"  owner_abbr: {quote(args.abbr)}",
        "mode: pd",
        "pd:",
        "  backend: mooncake_vllm018",
        "  topology: 1p1d",
        "  network:",
        f"    ifname: {quote(args.network_ifname)}",
        f"    nccl_ib_hca: {quote(args.nccl_ib_hca)}",
        "  roles:",
        "    prefill:",
        f"      node: {quote(args.prefill_node)}",
        f"      service_ip: {quote(args.prefill_service_ip)}",
        f"      vllm_host_ip: {quote(prefill_host)}",
        f"      port: {args.prefill_port}",
        f"      transfer_port: {args.prefill_transfer_port}",
        "    decode:",
        f"      node: {quote(args.decode_node)}",
        f"      service_ip: {quote(args.decode_service_ip)}",
        f"      vllm_host_ip: {quote(decode_host)}",
        f"      port: {args.decode_port}",
        "  proxy:",
        "    node_role: prefill",
        f"    port: {args.proxy_port}",
        "",
    ]
    return "\n".join(lines)


def positive_port(value):
    number = int(value)
    if not 1 <= number <= 65535:
        raise argparse.ArgumentTypeError("port must be between 1 and 65535")
    return number


def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--deployment-id", required=True)
    parser.add_argument("--prefill-node", required=True)
    parser.add_argument("--prefill-service-ip", required=True)
    parser.add_argument("--prefill-vllm-host-ip")
    parser.add_argument("--decode-node", required=True)
    parser.add_argument("--decode-service-ip", required=True)
    parser.add_argument("--decode-vllm-host-ip")
    parser.add_argument("--prefill-port", type=positive_port, default=9348)
    parser.add_argument("--decode-port", type=positive_port, default=9349)
    parser.add_argument("--prefill-transfer-port", type=positive_port, default=8998)
    parser.add_argument("--proxy-port", type=positive_port, default=8000)
    parser.add_argument("--network-ifname", required=True)
    parser.add_argument("--nccl-ib-hca", default="")
    parser.add_argument("--user", required=True)
    parser.add_argument("--abbr", required=True)
    parser.add_argument("--output")
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not ID_RE.fullmatch(args.deployment_id):
        raise SystemExit("invalid_deployment_id={}".format(args.deployment_id))
    if not ID_RE.fullmatch(args.abbr.lower()):
        raise SystemExit("invalid_abbr={}".format(args.abbr))

    output = Path(args.output).expanduser() if args.output else Path(
        f"/public/home/{args.user}/.config/vllm-perf-validation-pd/deployments/{args.deployment_id}.yaml"
    )
    content = render(args)
    print(f"DEPLOYMENT_ID={args.deployment_id}")
    print(f"DEPLOYMENT_PATH={output}")
    if args.dry_run:
        print("DEPLOYMENT_DRY_RUN=1")
        print(content, end="")
        return
    if output.exists() and not args.overwrite:
        raise SystemExit(f"deployment_exists={output}")
    atomic_write(output, content)
    print("DEPLOYMENT_CONFIGURED=1")


if __name__ == "__main__":
    main()
