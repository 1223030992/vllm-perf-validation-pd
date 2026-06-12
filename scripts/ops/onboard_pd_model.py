#!/usr/bin/env python3
"""Onboard one Mooncake 1P1D model from verified role scripts."""

import argparse
import os
import re
import shlex
import shutil
import tempfile
from pathlib import Path

import pd_config
from register_pd_model import dump_yaml
from standardize_pd_server_scripts import parse_role_script, proxy_script, role_script


DEFAULT_ROOT = Path(__file__).resolve().parents[2]
TOKEN_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")


def resolve_source(value):
    path = Path(value).expanduser().resolve()
    if not path.is_file():
        raise SystemExit("source_script_missing={}".format(path))
    return path


def infer_precision(model_name):
    upper = model_name.upper()
    match = re.search(r"W(\d+)A(\d+)", upper)
    if match:
        return "w{}a{}".format(match.group(1), match.group(2))
    for token in ("BF16", "FP16", "FP8", "INT8", "INT4"):
        if token in upper:
            return token.lower()
    return "unknown"


def service_defaults(prefill, decode):
    common_keys = (
        "tp", "gpu_range", "quantization", "dtype", "max_num_batched_tokens",
        "max_num_seqs", "gpu_memory_utilization", "max_model_len",
        "speculative_config", "compilation_config",
    )
    for key in ("model_path", "tp", "quantization", "dtype"):
        if str(prefill.get(key, "")) != str(decode.get(key, "")):
            raise SystemExit("prefill_decode_mismatch={} prefill={} decode={}".format(
                key, prefill.get(key), decode.get(key)
            ))
    result = {key: prefill.get(key, "") for key in common_keys}
    result["extra_args"] = ""
    result["prefill_extra_args"] = " ".join(shlex.quote(item) for item in prefill.get("extras", []))
    result["decode_extra_args"] = " ".join(shlex.quote(item) for item in decode.get("extras", []))
    return result


def custom_proxy_content(path):
    text = path.read_text(encoding="utf-8-sig")
    required = ("--proxy-script", "--prefill-url", "--prefill-transfer-port", "--decode-url", "--port")
    missing = [flag for flag in required if flag not in text]
    if missing:
        raise SystemExit("custom_proxy_missing_standard_args={}".format(",".join(missing)))
    return text if text.endswith("\n") else text + "\n"


def write_text(path, content, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="\n")
    if executable:
        os.chmod(str(path), 0o755)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-name", required=True)
    parser.add_argument("--model-short", required=True)
    parser.add_argument("--host-model-path", required=True)
    parser.add_argument("--container-model-path")
    parser.add_argument("--profile-id")
    parser.add_argument("--precision")
    parser.add_argument("--prefill-source", required=True)
    parser.add_argument("--decode-source", required=True)
    parser.add_argument("--proxy-source")
    parser.add_argument("--skill-root", default=str(DEFAULT_ROOT))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not TOKEN_RE.fullmatch(args.model_short):
        raise SystemExit("invalid_model_short={}".format(args.model_short))
    profile_id = args.profile_id or args.model_short + "-vllm018-mooncake"
    if not TOKEN_RE.fullmatch(profile_id):
        raise SystemExit("invalid_profile_id={}".format(profile_id))
    if not args.host_model_path.startswith("/"):
        raise SystemExit("host_model_path_must_be_absolute=1")
    container_model_path = args.container_model_path or "/model/" + Path(args.host_model_path).name
    if not container_model_path.startswith("/"):
        raise SystemExit("container_model_path_must_be_absolute=1")

    root = Path(args.skill_root).expanduser().resolve()
    prefill_source = resolve_source(args.prefill_source)
    decode_source = resolve_source(args.decode_source)
    proxy_source = resolve_source(args.proxy_source) if args.proxy_source else None
    prefill = parse_role_script(prefill_source)
    decode = parse_role_script(decode_source)
    defaults = service_defaults(prefill, decode)
    precision = args.precision or infer_precision(args.model_name)

    target_server = root / "scripts" / "pd-server" / args.model_short
    target_profile = root / "references" / "pd-profiles" / (profile_id + ".yaml")
    target_preset = root / "references" / "test-presets" / (args.model_short + "-smoke.yaml")
    for target in (target_server, target_profile, target_preset):
        if target.exists():
            raise SystemExit("onboard_target_exists={}".format(target))
    for other in (root / "references" / "pd-profiles").glob("*.yaml"):
        data = pd_config.load_yaml(other)
        if str((data.get("model") or {}).get("model_short")) == args.model_short:
            raise SystemExit("model_short_already_registered={}:{}".format(args.model_short, other))

    relative_dir = "scripts/pd-server/{}".format(args.model_short)
    profile = {
        "pd_profile": {"name": profile_id, "description": "{} vLLM 0.18 Mooncake 1P1D".format(args.model_name)},
        "model": {
            "name": args.model_name,
            "model_short": args.model_short,
            "host_model_path": args.host_model_path,
            "container_model_path": container_model_path,
            "precision": precision,
        },
        "pd": {
            "backend": "mooncake_vllm018",
            "topology": "1p1d",
            "mooncake_proxy_script": "mooncake/examples/online_serving/disaggregated_serving/mooncake_connector/mooncake_connector_proxy.py",
            "server_scripts": {
                "prefill": relative_dir + "/p_server.sh",
                "decode": relative_dir + "/d_server.sh",
                "proxy": relative_dir + "/run_proxy.sh",
            },
            "runtime": {"mooncake_wheel": None, "mooncake_dest_device_affinity": True},
            "service_defaults": defaults,
        },
    }
    preset = {
        "test": {
            "mode": "custom",
            "params": {
                "input_lens": [512], "output_len": 32, "concurrencies": [1],
                "num_prompts_mult": 1, "request_rate": None, "percentiles": "50,95,99",
            },
        }
    }
    profile_text = "\n".join(dump_yaml(profile)) + "\n"
    preset_text = "\n".join(dump_yaml(preset)) + "\n"
    proxy_text = custom_proxy_content(proxy_source) if proxy_source else proxy_script()

    print("PROFILE_ID={}".format(profile_id))
    print("MODEL_SHORT={}".format(args.model_short))
    print("CONTAINER_MODEL_PATH={}".format(container_model_path))
    print("INFERRED_PRECISION={}".format(precision))
    print("INFERRED_TP={}".format(defaults["tp"]))
    print("INFERRED_GPU_RANGE={}".format(defaults["gpu_range"]))
    print("SERVER_DIR={}".format(target_server))
    print("PROFILE_PATH={}".format(target_profile))
    print("TEST_PRESET_PATH={}".format(target_preset))
    if args.dry_run:
        print("PROFILE_CONTENT_BEGIN\n{}PROFILE_CONTENT_END".format(profile_text))
        print("TEST_PRESET_CONTENT_BEGIN\n{}TEST_PRESET_CONTENT_END".format(preset_text))
        print("PD_MODEL_ONBOARD_DRY_RUN_DONE=1")
        return 0

    staging_parent = root / ".onboard-staging"
    staging_parent.mkdir(exist_ok=True)
    committed = []
    try:
        with tempfile.TemporaryDirectory(prefix=args.model_short + "-", dir=staging_parent) as temp_dir:
            stage = Path(temp_dir)
            stage_server = stage / "server"
            write_text(stage_server / "p_server.sh", role_script("prefill", prefill), True)
            write_text(stage_server / "d_server.sh", role_script("decode", decode), True)
            write_text(stage_server / "run_proxy.sh", proxy_text, True)
            raw = stage_server / "raw"
            raw.mkdir()
            shutil.copyfile(str(prefill_source), str(raw / "p_server.sh"))
            shutil.copyfile(str(decode_source), str(raw / "d_server.sh"))
            if proxy_source:
                shutil.copyfile(str(proxy_source), str(raw / "run_proxy.sh"))
            stage_profile = stage / "profile.yaml"
            stage_preset = stage / "preset.yaml"
            write_text(stage_profile, profile_text)
            write_text(stage_preset, preset_text)

            parse_role_script(stage_server / "p_server.sh")
            parse_role_script(stage_server / "d_server.sh")
            pd_config.load_yaml(stage_profile)
            pd_config.load_yaml(stage_preset)

            target_server.parent.mkdir(parents=True, exist_ok=True)
            target_profile.parent.mkdir(parents=True, exist_ok=True)
            target_preset.parent.mkdir(parents=True, exist_ok=True)
            os.replace(str(stage_server), str(target_server)); committed.append(target_server)
            os.replace(str(stage_profile), str(target_profile)); committed.append(target_profile)
            os.replace(str(stage_preset), str(target_preset)); committed.append(target_preset)
    except Exception:
        for target in reversed(committed):
            if target.is_dir():
                shutil.rmtree(str(target), ignore_errors=True)
            elif target.exists():
                target.unlink()
        raise
    finally:
        try:
            staging_parent.rmdir()
        except OSError:
            pass

    print("PD_MODEL_ONBOARD_DONE=1")
    print("FIRST_SMOKE_COMMAND=run_pd_task.sh --profile {} --deployment <DEPLOYMENT> --test-preset {}-smoke --image <IMAGE> --mooncake-wheel <WHEEL> --user <user> --abbr <abbr> --assume-yes".format(profile_id, args.model_short))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
