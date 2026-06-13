#!/usr/bin/env python3
"""Create or update a user-local PD deployment configuration."""

import argparse
import os
import re
import tempfile
from pathlib import Path

import pd_config
from register_pd_model import dump_yaml


ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")


def positive_port(value):
    number = int(value)
    if not 1 <= number <= 65535:
        raise argparse.ArgumentTypeError("port must be between 1 and 65535")
    return number


def set_path(data, path, value):
    current = data
    parts = path.split(".")
    for key in parts[:-1]:
        current = current.setdefault(key, {})
    current[parts[-1]] = value


def supplied_updates(args):
    updates = {
        "deployment.id": args.deployment_id,
        "deployment.owner": args.user,
        "deployment.owner_abbr": args.abbr,
    }
    optional = {
        "model.host_model_path": args.host_model_path,
        "pd.network.ifname": args.network_ifname,
        "pd.network.nccl_ib_hca": args.nccl_ib_hca,
        "pd.roles.prefill.node": args.prefill_node,
        "pd.roles.prefill.service_ip": args.prefill_service_ip,
        "pd.roles.prefill.vllm_host_ip": args.prefill_vllm_host_ip,
        "pd.roles.prefill.port": args.prefill_port,
        "pd.roles.prefill.transfer_port": args.prefill_transfer_port,
        "pd.roles.decode.node": args.decode_node,
        "pd.roles.decode.service_ip": args.decode_service_ip,
        "pd.roles.decode.vllm_host_ip": args.decode_vllm_host_ip,
        "pd.roles.decode.port": args.decode_port,
        "pd.proxy.port": args.proxy_port,
    }
    updates.update({key: value for key, value in optional.items() if value is not None})
    return updates


def create_data(args):
    required = (
        "prefill_node", "prefill_service_ip", "decode_node",
        "decode_service_ip", "network_ifname",
    )
    missing = [name for name in required if not getattr(args, name)]
    if missing:
        raise SystemExit("missing_create_arguments={}".format(",".join(missing)))
    data = {
        "deployment": {
            "id": args.deployment_id,
            "owner": args.user,
            "owner_abbr": args.abbr,
        },
        "mode": "pd",
        "pd": {
            "backend": "mooncake_vllm018",
            "topology": "1p1d",
            "network": {
                "ifname": args.network_ifname,
                "nccl_ib_hca": args.nccl_ib_hca or "",
            },
            "roles": {
                "prefill": {
                    "node": args.prefill_node,
                    "service_ip": args.prefill_service_ip,
                    "vllm_host_ip": args.prefill_vllm_host_ip or args.prefill_service_ip,
                    "port": args.prefill_port or 9348,
                    "transfer_port": args.prefill_transfer_port or 8998,
                },
                "decode": {
                    "node": args.decode_node,
                    "service_ip": args.decode_service_ip,
                    "vllm_host_ip": args.decode_vllm_host_ip or args.decode_service_ip,
                    "port": args.decode_port or 9349,
                },
            },
            "proxy": {"node_role": "prefill", "port": args.proxy_port or 8000},
        },
    }
    if args.host_model_path:
        data["model"] = {"host_model_path": args.host_model_path}
    return data


def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
        os.replace(temp_name, str(path))
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--deployment-id", required=True)
    parser.add_argument("--prefill-node")
    parser.add_argument("--prefill-service-ip")
    parser.add_argument("--prefill-vllm-host-ip")
    parser.add_argument("--decode-node")
    parser.add_argument("--decode-service-ip")
    parser.add_argument("--decode-vllm-host-ip")
    parser.add_argument("--prefill-port", type=positive_port)
    parser.add_argument("--decode-port", type=positive_port)
    parser.add_argument("--prefill-transfer-port", type=positive_port)
    parser.add_argument("--proxy-port", type=positive_port)
    parser.add_argument("--network-ifname")
    parser.add_argument("--nccl-ib-hca")
    parser.add_argument("--host-model-path")
    parser.add_argument("--user", required=True)
    parser.add_argument("--abbr", required=True)
    parser.add_argument("--output")
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--update-existing", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not ID_RE.fullmatch(args.deployment_id):
        raise SystemExit("invalid_deployment_id={}".format(args.deployment_id))
    if not ID_RE.fullmatch(args.abbr.lower()):
        raise SystemExit("invalid_abbr={}".format(args.abbr))
    if args.host_model_path and not args.host_model_path.startswith("/"):
        raise SystemExit("host_model_path_must_be_absolute={}".format(args.host_model_path))
    if args.overwrite and args.update_existing:
        raise SystemExit("overwrite_conflicts_with_update_existing=1")

    output = Path(args.output).expanduser() if args.output else Path(
        "/public/home/{}/.config/vllm-perf-validation-pd/deployments/{}.yaml".format(
            args.user, args.deployment_id
        )
    )
    if args.update_existing:
        if not output.is_file():
            raise SystemExit("deployment_missing={}".format(output))
        data = pd_config.load_yaml(output)
        updates = supplied_updates(args)
        for path, value in updates.items():
            set_path(data, path, value)
        operation = "updated"
    else:
        if output.exists() and not args.overwrite:
            raise SystemExit("deployment_exists={}".format(output))
        data = create_data(args)
        updates = supplied_updates(args)
        operation = "configured"

    content = "\n".join(dump_yaml(data)) + "\n"
    print("DEPLOYMENT_ID={}".format(args.deployment_id))
    print("DEPLOYMENT_PATH={}".format(output))
    print("DEPLOYMENT_OPERATION={}".format(operation))
    print("UPDATED_FIELDS={}".format(",".join(sorted(updates))))
    if args.dry_run:
        print("DEPLOYMENT_DRY_RUN=1")
        print(content, end="")
        return 0
    atomic_write(output, content)
    print("DEPLOYMENT_CONFIGURED=1" if operation == "configured" else "DEPLOYMENT_UPDATED=1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
