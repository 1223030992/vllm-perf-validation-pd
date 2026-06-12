#!/usr/bin/env python3
"""Register a local Mooncake 1P1D model profile and smoke example."""

import argparse
import re
from pathlib import Path


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
    parser.add_argument("--max-num-batched-tokens", default="")
    parser.add_argument("--max-num-seqs", default="")
    parser.add_argument("--gpu-memory-utilization", default="")
    parser.add_argument("--max-model-len", default="")
    parser.add_argument("--speculative-config", default="")
    parser.add_argument("--compilation-config", default="")
    parser.add_argument("--extra-args", default="")
    parser.add_argument("--prefill-extra-args", default="")
    parser.add_argument("--decode-extra-args", default="")
    parser.add_argument("--base-config", help="Deprecated; deployment data is no longer inherited")
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
    server_dir = root / "scripts" / "pd-server" / args.model_short
    scripts = {name: server_dir / filename for name, filename in (("prefill", "p_server.sh"), ("decode", "d_server.sh"), ("proxy", "run_proxy.sh"))}
    for role, path in scripts.items():
        if not path.is_file():
            raise SystemExit("standardized_{}_script_missing={}".format(role, path))

    relative_dir = "scripts/pd-server/{}".format(args.model_short)
    service_base = {
        "tp": args.tp,
        "gpu_range": args.gpu_range,
        "quantization": args.quantization,
        "dtype": args.dtype,
        "max_num_batched_tokens": args.max_num_batched_tokens,
        "max_num_seqs": args.max_num_seqs,
        "gpu_memory_utilization": args.gpu_memory_utilization,
        "max_model_len": args.max_model_len,
        "speculative_config": args.speculative_config,
        "compilation_config": args.compilation_config,
        "extra_args": args.extra_args,
        "prefill_extra_args": args.prefill_extra_args,
        "decode_extra_args": args.decode_extra_args,
    }
    profile = {
        "pd_profile": {"name": args.profile_id, "description": "{} vLLM 0.18 Mooncake 1P1D defaults".format(args.model_name)},
        "model": {"name": args.model_name, "model_short": args.model_short, "host_model_path": args.host_model_path, "container_model_path": args.container_model_path, "precision": args.precision},
        "pd": {
            "backend": "mooncake_vllm018", "topology": "1p1d",
            "mooncake_proxy_script": "mooncake/examples/online_serving/disaggregated_serving/mooncake_connector/mooncake_connector_proxy.py",
            "server_scripts": {"prefill": relative_dir + "/p_server.sh", "decode": relative_dir + "/d_server.sh", "proxy": relative_dir + "/run_proxy.sh"},
            "runtime": {"mooncake_wheel": None, "mooncake_dest_device_affinity": True},
            "service_defaults": service_base,
        },
    }
    preset = {
        "test": {"mode": "custom", "params": {"input_lens": [512], "output_len": 32, "concurrencies": [1], "num_prompts_mult": 1, "request_rate": None, "percentiles": "50,95,99"}},
    }

    profile_path = root / "references" / "pd-profiles" / (args.profile_id + ".yaml")
    preset_path = root / "references" / "test-presets" / (args.model_short + "-smoke.yaml")
    for path in (profile_path, preset_path):
        if path.exists() and not (args.overwrite or args.dry_run):
            raise SystemExit("target_exists={}; pass --overwrite".format(path))
    for other in (root / "references" / "pd-profiles").glob("*.yaml"):
        if other == profile_path:
            continue
        text = other.read_text(encoding="utf-8-sig")
        if re.search(r"(?m)^\s*model_short:\s*{}\s*$".format(re.escape(args.model_short)), text):
            raise SystemExit("model_short_already_registered={}:{}".format(args.model_short, other))

    profile_text = "\n".join(dump_yaml(profile)) + "\n"
    preset_text = "\n".join(dump_yaml(preset)) + "\n"
    print("PROFILE_PATH={}".format(profile_path))
    print("TEST_PRESET_PATH={}".format(preset_path))
    print("USER={}".format(args.user))
    print("ABBR={}".format(args.abbr))
    print("PROFILE_CONTENT_BEGIN\n{}PROFILE_CONTENT_END".format(profile_text))
    print("TEST_PRESET_CONTENT_BEGIN\n{}TEST_PRESET_CONTENT_END".format(preset_text))
    if args.dry_run:
        print("PD_MODEL_REGISTER_DRY_RUN_DONE=1")
        return 0
    profile_path.parent.mkdir(parents=True, exist_ok=True)
    preset_path.parent.mkdir(parents=True, exist_ok=True)
    profile_path.write_text(profile_text, encoding="utf-8", newline="\n")
    preset_path.write_text(preset_text, encoding="utf-8", newline="\n")
    print("PD_MODEL_REGISTER_DONE=1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
