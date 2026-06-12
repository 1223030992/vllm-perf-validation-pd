#!/usr/bin/env python3
"""Register a local Mooncake 1P1D model profile and smoke example."""

import argparse
import re
from copy import deepcopy
from pathlib import Path

import pd_config


DEFAULT_ROOT = Path(__file__).resolve().parents[2]


def yaml_scalar(value):
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, (int, float)):
        return str(value)
    text = str(value)
    if text == "" or re.search(r"[:#{}\[\],&*?|>'\"%@`]|^[-!?]|\s$|^\s", text):
        return "'{}'".format(text.replace("'", "''"))
    return text


def dump_yaml(data, indent=0):
    lines = []
    prefix = " " * indent
    for key, value in data.items():
        if isinstance(value, dict):
            lines.append("{}{}:".format(prefix, key))
            lines.extend(dump_yaml(value, indent + 2))
        elif isinstance(value, list):
            lines.append("{}{}: [{}]".format(prefix, key, ", ".join(yaml_scalar(item) for item in value)))
        else:
            lines.append("{}{}: {}".format(prefix, key, yaml_scalar(value)))
    return lines


def validate_token(name, value):
    if not re.match(r"^[a-z0-9][a-z0-9-]*$", value):
        raise SystemExit("invalid_{}={}".format(name, value))


def main():
    parser = argparse.ArgumentParser(description="Register a Mooncake 1P1D model locally")
    parser.add_argument("--profile-id", required=True)
    parser.add_argument("--model-name", required=True)
    parser.add_argument("--model-short", required=True)
    parser.add_argument("--host-model-path", required=True)
    parser.add_argument("--container-model-path", required=True)
    parser.add_argument("--precision", required=True)
    parser.add_argument("--tp", required=True, type=int)
    parser.add_argument("--gpu-range", required=True)
    parser.add_argument("--quantization", default="")
    parser.add_argument("--dtype", default="bfloat16")
    parser.add_argument("--base-config", required=True)
    parser.add_argument("--user", required=True)
    parser.add_argument("--abbr", required=True)
    parser.add_argument("--skill-root", default=str(DEFAULT_ROOT))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()
    validate_token("profile_id", args.profile_id)
    validate_token("model_short", args.model_short)
    validate_token("abbr", args.abbr)
    if args.tp < 1:
        raise SystemExit("invalid_tp={}".format(args.tp))
    if not args.host_model_path.startswith("/") or not args.container_model_path.startswith("/"):
        raise SystemExit("model_paths_must_be_absolute=1")

    root = Path(args.skill_root).resolve()
    base_path = Path(args.base_config)
    if not base_path.is_absolute():
        base_path = root / base_path
    if not base_path.is_file():
        raise SystemExit("base_config_missing={}".format(base_path))
    raw_base = pd_config.load_yaml(base_path)
    merged_base = pd_config.load_with_profile(base_path)
    pd_base = merged_base.get("pd") or {}
    service_base = deepcopy(pd_base.get("service_defaults") or {})
    runtime_base = deepcopy(pd_base.get("runtime") or {})
    server_dir = root / "scripts" / "pd-server" / args.model_short
    scripts = {name: server_dir / filename for name, filename in (("prefill", "p_server.sh"), ("decode", "d_server.sh"), ("proxy", "run_proxy.sh"))}
    for role, path in scripts.items():
        if not path.is_file():
            raise SystemExit("standardized_{}_script_missing={}".format(role, path))

    relative_dir = "scripts/pd-server/{}".format(args.model_short)
    service_base.update({"tp": args.tp, "gpu_range": args.gpu_range, "quantization": args.quantization, "dtype": args.dtype})
    profile = {
        "pd_profile": {"name": args.profile_id, "description": "{} vLLM 0.18 Mooncake 1P1D defaults".format(args.model_name)},
        "model": {"name": args.model_name, "model_short": args.model_short, "host_model_path": args.host_model_path, "container_model_path": args.container_model_path, "precision": args.precision},
        "pd": {
            "backend": "mooncake_vllm018", "topology": "1p1d",
            "mooncake_proxy_script": pd_base.get("mooncake_proxy_script", "mooncake/examples/online_serving/disaggregated_serving/mooncake_connector/mooncake_connector_proxy.py"),
            "server_scripts": {"prefill": relative_dir + "/p_server.sh", "decode": relative_dir + "/d_server.sh", "proxy": relative_dir + "/run_proxy.sh"},
            "runtime": runtime_base,
            "service_defaults": service_base,
        },
    }
    raw_pd = raw_base.get("pd") or {}
    deployment = {}
    for key in ("network", "roles", "proxy"):
        if key in raw_pd:
            deployment[key] = deepcopy(raw_pd[key])
    example = {
        "task": {"name": args.profile_id.replace("-", "_") + "_1p1d_custom", "run_id": "auto", "owner": args.user, "description": "{} Mooncake 1P1D custom smoke".format(args.model_name)},
        "mode": "pd",
        "pd": {"profile": "references/pd-profiles/{}.yaml".format(args.profile_id)},
        "test": {"mode": "custom", "params": {"input_lens": [512], "output_len": 32, "concurrencies": [1], "num_prompts_mult": 1, "request_rate": None, "percentiles": "50,95,99"}},
    }
    example["pd"].update(deployment)

    profile_path = root / "references" / "pd-profiles" / (args.profile_id + ".yaml")
    example_path = root / "references" / "examples" / (args.profile_id + "-1p1d-custom.yaml")
    for path in (profile_path, example_path):
        if path.exists() and not (args.overwrite or args.dry_run):
            raise SystemExit("target_exists={}; pass --overwrite".format(path))
    for other in (root / "references" / "pd-profiles").glob("*.yaml"):
        if other == profile_path:
            continue
        text = other.read_text(encoding="utf-8-sig")
        if re.search(r"(?m)^\s*model_short:\s*{}\s*$".format(re.escape(args.model_short)), text):
            raise SystemExit("model_short_already_registered={}:{}".format(args.model_short, other))

    profile_text = "\n".join(dump_yaml(profile)) + "\n"
    example_text = "\n".join(dump_yaml(example)) + "\n"
    print("PROFILE_PATH={}".format(profile_path))
    print("EXAMPLE_PATH={}".format(example_path))
    print("USER={}".format(args.user))
    print("ABBR={}".format(args.abbr))
    print("PROFILE_CONTENT_BEGIN\n{}PROFILE_CONTENT_END".format(profile_text))
    print("EXAMPLE_CONTENT_BEGIN\n{}EXAMPLE_CONTENT_END".format(example_text))
    if args.dry_run:
        print("PD_MODEL_REGISTER_DRY_RUN_DONE=1")
        return 0
    profile_path.parent.mkdir(parents=True, exist_ok=True)
    example_path.parent.mkdir(parents=True, exist_ok=True)
    profile_path.write_text(profile_text, encoding="utf-8", newline="\n")
    example_path.write_text(example_text, encoding="utf-8", newline="\n")
    print("PD_MODEL_REGISTER_DONE=1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
