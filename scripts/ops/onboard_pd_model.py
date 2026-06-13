#!/usr/bin/env python3
"""Onboard one Mooncake 1P1D model from verified role scripts."""

import argparse
import hashlib
import os
import re
import shlex
import shutil
import tempfile
from pathlib import Path

import pd_config
from register_pd_model import dump_yaml
from standardize_pd_server_scripts import parse_role_script, proxy_script, role_script


DEFAULT_ROOT = Path(os.path.abspath(__file__)).parents[2]
TOKEN_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")


class OnboardFailure(Exception):
    def __init__(self, reason, detail=None):
        super().__init__(detail or reason)
        self.reason = reason
        self.detail = detail or reason


class StructuredArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise OnboardFailure("invalid_arguments", message)


def lexical_absolute_path(value):
    return Path(os.path.abspath(os.path.expanduser(str(value))))


def display_path_text(path):
    return str(path).replace("\\", "/")


def resolve_source(value, role):
    display_path = lexical_absolute_path(value)
    resolved_path = Path(value).expanduser().resolve()
    if not resolved_path.is_file():
        raise OnboardFailure("{}_source_missing".format(role), display_path_text(display_path))
    if resolved_path.stat().st_size == 0:
        raise OnboardFailure("{}_source_empty".format(role), display_path_text(display_path))
    return display_path, resolved_path


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_text_lf(path, content, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(content)
    if executable:
        os.chmod(str(path), 0o755)


def parse_source(path, role):
    try:
        return parse_role_script(path)
    except SystemExit as exc:
        detail = str(exc)
        if "vllm_serve_command_not_found" in detail:
            reason = "{}_vllm_serve_missing".format(role)
        else:
            reason = "{}_source_parse_failed".format(role)
        raise OnboardFailure(reason, "path={} error={}".format(path, detail))
    except (ValueError, OSError) as exc:
        raise OnboardFailure(
            "{}_source_parse_failed".format(role),
            "path={} error={}:{}".format(path, type(exc).__name__, exc),
        )


def validate_role(parsed, role, expected):
    actual = parsed.get("kv_role") or ""
    if not actual:
        raise OnboardFailure("{}_kv_role_missing".format(role), "expected={}".format(expected))
    if actual != expected:
        raise OnboardFailure(
            "{}_kv_role_mismatch".format(role),
            "expected={} actual={}".format(expected, actual),
        )


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
            raise OnboardFailure(
                "prefill_decode_mismatch",
                "field={} prefill={} decode={}".format(key, prefill.get(key), decode.get(key)),
            )
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
        raise OnboardFailure("custom_proxy_missing_standard_args", ",".join(missing))
    return text if text.endswith("\n") else text + "\n"


def render_profile(args, profile_id, container_model_path, precision, defaults):
    relative_dir = "scripts/pd-server/{}".format(args.model_short)
    model = {
        "name": args.model_name,
        "model_short": args.model_short,
        "container_model_path": container_model_path,
        "precision": precision,
    }
    if args.host_model_path:
        model["host_model_path"] = args.host_model_path
    profile = {
        "pd_profile": {"name": profile_id, "description": "{} vLLM 0.18 Mooncake 1P1D".format(args.model_name)},
        "model": model,
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
    return "\n".join(dump_yaml(profile)) + "\n", "\n".join(dump_yaml(preset)) + "\n"


def remove_committed(paths):
    completed = True
    for target in reversed(paths):
        try:
            if target.is_dir():
                shutil.rmtree(str(target))
            elif target.exists():
                target.unlink()
        except OSError:
            completed = False
    return completed


def source_summary(role, display_path, resolved_path, parsed):
    print("{}_SOURCE={}".format(role.upper(), display_path_text(display_path)))
    print("{}_SOURCE_BYTES={}".format(role.upper(), resolved_path.stat().st_size))
    print("{}_SOURCE_SHA256={}".format(role.upper(), sha256_file(resolved_path)))
    print("{}_KV_ROLE={}".format(role.upper(), parsed.get("kv_role") or "not_detected"))
    print("{}_PRESERVED_EXPORTS={}".format(role.upper(), " | ".join(parsed.get("exports", [])) or "none"))
    print("{}_EXTRA_ARGS={}".format(role.upper(), " ".join(parsed.get("extras", [])) or "none"))


def onboard(args):
    stage = "validate_arguments"
    committed = []
    staging_parent = None
    try:
        if not TOKEN_RE.fullmatch(args.model_short):
            raise OnboardFailure("invalid_model_short", args.model_short)
        profile_id = args.profile_id or args.model_short + "-vllm018-mooncake"
        if not TOKEN_RE.fullmatch(profile_id):
            raise OnboardFailure("invalid_profile_id", profile_id)
        if args.host_model_path and not args.host_model_path.startswith("/"):
            raise OnboardFailure("host_model_path_must_be_absolute", args.host_model_path)
        if not args.container_model_path and not args.host_model_path:
            raise OnboardFailure(
                "container_model_path_required",
                "pass --container-model-path when --host-model-path is omitted",
            )
        container_model_path = args.container_model_path or "/model/" + Path(args.host_model_path).name
        if not container_model_path.startswith("/"):
            raise OnboardFailure("container_model_path_must_be_absolute", container_model_path)

        root = lexical_absolute_path(args.skill_root)
        stage = "validate_sources"
        prefill_display, prefill_source = resolve_source(args.prefill_source, "prefill")
        decode_display, decode_source = resolve_source(args.decode_source, "decode")
        if args.proxy_source:
            proxy_display, proxy_source = resolve_source(args.proxy_source, "proxy")
        else:
            proxy_display, proxy_source = None, None
        prefill = parse_source(prefill_source, "prefill")
        decode = parse_source(decode_source, "decode")
        validate_role(prefill, "prefill", "kv_producer")
        validate_role(decode, "decode", "kv_consumer")
        defaults = service_defaults(prefill, decode)
        precision = args.precision or infer_precision(args.model_name)

        target_server = root / "scripts" / "pd-server" / args.model_short
        target_profile = root / "references" / "pd-profiles" / (profile_id + ".yaml")
        target_preset = root / "references" / "test-presets" / (args.model_short + "-smoke.yaml")
        stage = "check_targets"
        for target in (target_server, target_profile, target_preset):
            if target.exists():
                raise OnboardFailure("onboard_target_exists", str(target))
        for other in (root / "references" / "pd-profiles").glob("*.yaml"):
            data = pd_config.load_yaml(other)
            if str((data.get("model") or {}).get("model_short")) == args.model_short:
                raise OnboardFailure("model_short_already_registered", "{}:{}".format(args.model_short, other))

        profile_text, preset_text = render_profile(args, profile_id, container_model_path, precision, defaults)
        proxy_text = custom_proxy_content(proxy_source) if proxy_source else proxy_script()

        print("PROFILE_ID={}".format(profile_id))
        print("MODEL_SHORT={}".format(args.model_short))
        print("HOST_MODEL_PATH={}".format(args.host_model_path or "deployment_required"))
        print("CONTAINER_MODEL_PATH={}".format(container_model_path))
        print("INFERRED_PRECISION={}".format(precision))
        print("INFERRED_TP={}".format(defaults["tp"]))
        print("INFERRED_GPU_RANGE={}".format(defaults["gpu_range"]))
        source_summary("prefill", prefill_display, prefill_source, prefill)
        source_summary("decode", decode_display, decode_source, decode)
        if proxy_source:
            print("PROXY_SOURCE={}".format(display_path_text(proxy_display)))
            print("PROXY_SOURCE_BYTES={}".format(proxy_source.stat().st_size))
            print("PROXY_SOURCE_SHA256={}".format(sha256_file(proxy_source)))
        print("SERVER_DIR={}".format(target_server))
        print("PROFILE_PATH={}".format(target_profile))
        print("TEST_PRESET_PATH={}".format(target_preset))

        stage = "prepare_staging"
        staging_parent = root / ".onboard-staging"
        staging_parent.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=args.model_short + "-", dir=str(staging_parent)) as temp_dir:
            stage_root = Path(temp_dir)
            stage_server = stage_root / "server"
            write_text_lf(stage_server / "p_server.sh", role_script("prefill", prefill), True)
            write_text_lf(stage_server / "d_server.sh", role_script("decode", decode), True)
            write_text_lf(stage_server / "run_proxy.sh", proxy_text, True)
            raw = stage_server / "raw"
            raw.mkdir()
            shutil.copyfile(str(prefill_source), str(raw / "p_server.sh"))
            shutil.copyfile(str(decode_source), str(raw / "d_server.sh"))
            if proxy_source:
                shutil.copyfile(str(proxy_source), str(raw / "run_proxy.sh"))
            stage_profile = stage_root / "profile.yaml"
            stage_preset = stage_root / "preset.yaml"
            write_text_lf(stage_profile, profile_text)
            write_text_lf(stage_preset, preset_text)

            stage = "validate_staging"
            generated_prefill = parse_source(stage_server / "p_server.sh", "generated_prefill")
            generated_decode = parse_source(stage_server / "d_server.sh", "generated_decode")
            validate_role(generated_prefill, "generated_prefill", "kv_producer")
            validate_role(generated_decode, "generated_decode", "kv_consumer")
            pd_config.load_yaml(stage_profile)
            pd_config.load_yaml(stage_preset)
            print("STAGING_VALIDATED=1")

            if args.dry_run:
                print("PROFILE_CONTENT_BEGIN\n{}PROFILE_CONTENT_END".format(profile_text))
                print("TEST_PRESET_CONTENT_BEGIN\n{}TEST_PRESET_CONTENT_END".format(preset_text))
                print("PD_MODEL_ONBOARD_DRY_RUN_DONE=1")
                return 0

            stage = "commit_targets"
            target_server.parent.mkdir(parents=True, exist_ok=True)
            target_profile.parent.mkdir(parents=True, exist_ok=True)
            target_preset.parent.mkdir(parents=True, exist_ok=True)
            os.replace(str(stage_server), str(target_server)); committed.append(target_server)
            os.replace(str(stage_profile), str(target_profile)); committed.append(target_profile)
            os.replace(str(stage_preset), str(target_preset)); committed.append(target_preset)

        stage = "verify_commit"
        required_targets = (
            target_server / "p_server.sh", target_server / "d_server.sh",
            target_server / "run_proxy.sh", target_profile, target_preset,
        )
        for target in required_targets:
            if not target.is_file():
                raise OnboardFailure("committed_target_missing", str(target))
        print("SERVER_PREFILL_SHA256={}".format(sha256_file(target_server / "p_server.sh")))
        print("SERVER_DECODE_SHA256={}".format(sha256_file(target_server / "d_server.sh")))
        print("SERVER_PROXY_SHA256={}".format(sha256_file(target_server / "run_proxy.sh")))
        print("PROFILE_SHA256={}".format(sha256_file(target_profile)))
        print("TEST_PRESET_SHA256={}".format(sha256_file(target_preset)))
        print("PD_MODEL_ONBOARD_DONE=1")
        print("FIRST_SMOKE_COMMAND=run_pd_task.sh --profile {} --deployment <DEPLOYMENT> --test-preset {}-smoke --image <IMAGE> --mooncake-wheel <WHEEL> --user <user> --abbr <abbr> --assume-yes".format(profile_id, args.model_short))
        return 0
    except OnboardFailure as exc:
        rollback_completed = remove_committed(committed)
        print("PD_MODEL_ONBOARD_FAILED=1")
        print("FAILURE_STAGE={}".format(stage))
        print("FAILURE_REASON={}".format(exc.reason))
        print("FAILURE_DETAIL={}".format(exc.detail))
        print("ROLLBACK_COMPLETED={}".format(1 if rollback_completed else 0))
        return 1
    except SystemExit as exc:
        rollback_completed = remove_committed(committed)
        print("PD_MODEL_ONBOARD_FAILED=1")
        print("FAILURE_STAGE={}".format(stage))
        print("FAILURE_REASON=validation_error")
        print("FAILURE_DETAIL={}".format(exc))
        print("ROLLBACK_COMPLETED={}".format(1 if rollback_completed else 0))
        return 1
    except Exception as exc:
        rollback_completed = remove_committed(committed)
        print("PD_MODEL_ONBOARD_FAILED=1")
        print("FAILURE_STAGE={}".format(stage))
        print("FAILURE_REASON=unexpected_error")
        print("FAILURE_DETAIL={}:{}".format(type(exc).__name__, exc))
        print("ROLLBACK_COMPLETED={}".format(1 if rollback_completed else 0))
        return 1
    finally:
        if staging_parent is not None:
            try:
                staging_parent.rmdir()
            except OSError:
                pass


def emit_parse_failure(exc):
    print("PD_MODEL_ONBOARD_FAILED=1")
    print("FAILURE_STAGE=parse_arguments")
    print("FAILURE_REASON={}".format(exc.reason))
    print("FAILURE_DETAIL={}".format(exc.detail))
    print("ROLLBACK_COMPLETED=1")


def main():
    parser = StructuredArgumentParser()
    parser.add_argument("--model-name", required=True)
    parser.add_argument("--model-short", required=True)
    parser.add_argument("--host-model-path")
    parser.add_argument("--container-model-path")
    parser.add_argument("--profile-id")
    parser.add_argument("--precision")
    parser.add_argument("--prefill-source", required=True)
    parser.add_argument("--decode-source", required=True)
    parser.add_argument("--proxy-source")
    parser.add_argument("--skill-root", default=str(DEFAULT_ROOT))
    parser.add_argument("--dry-run", action="store_true")
    try:
        args = parser.parse_args()
    except OnboardFailure as exc:
        emit_parse_failure(exc)
        return 2
    return onboard(args)


if __name__ == "__main__":
    raise SystemExit(main())
