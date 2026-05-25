#!/usr/bin/env python3
"""Standardize a vLLM server script without touching SSH, Docker, or GPUs.

The output format matches the GLM server-script convention used by this skill:
default environment variables first, generic setup, preserved performance
exports, and a parameterized vllm serve command.
"""

import argparse
import difflib
import os
import re
import shutil
from datetime import datetime
from pathlib import Path


SKILL_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SKILL_HOST_ROOT = os.environ.get(
    "SKILL_HOST_ROOT", "/public/home/liuzhh8/.claude/skills/vllm-perf-validation-single"
).rstrip("/")
STANDARDIZE_SCRIPT = DEFAULT_SKILL_HOST_ROOT + "/scripts/ops/standardize_server_script.sh"
REGISTER_MODEL = DEFAULT_SKILL_HOST_ROOT + "/scripts/ops/register_model.sh"


GENERIC_EXPORTS = set(
    [
        "GPU_RANGE",
        "TP",
        "TP_SIZE",
        "MODEL_PATH",
        "PORT",
        "LOG_DIR",
        "HIP_VISIBLE_DEVICES",
    ]
)


def shell_quote(value):
    return "'" + str(value).replace("'", "'\\''") + "'"


def resolve_path(path):
    p = Path(path)
    if not p.is_absolute():
        p = (SKILL_ROOT / path).resolve()
    return p


def relative_to_skill(path):
    p = Path(path)
    try:
        return str(p.resolve().relative_to(SKILL_ROOT)).replace("\\", "/")
    except ValueError:
        return str(path).replace("\\", "/")


def collect_vllm_block(lines):
    start = None
    for idx, line in enumerate(lines):
        if re.match(r"^\s*vllm\s+serve\b", line):
            start = idx
            break
    if start is None:
        raise SystemExit("vllm serve command not found in server script")

    end = start
    while end < len(lines):
        if not lines[end].rstrip().endswith("\\"):
            break
        end += 1
    if end >= len(lines):
        end = len(lines) - 1
    return start, end, lines[start : end + 1]


def export_name(line):
    m = re.match(r"^\s*export\s+([A-Za-z_][A-Za-z0-9_]*)=", line)
    if not m:
        return None
    return m.group(1)


def preserved_exports(lines):
    result = []
    seen = set()
    for line in lines:
        name = export_name(line)
        if not name or name in GENERIC_EXPORTS or name in seen:
            continue
        result.append(line.strip())
        seen.add(name)
    return result


def normalize_arg_line(line):
    stripped = line.strip()
    if not stripped:
        return None
    return "    " + stripped


def should_skip_arg(line):
    stripped = line.strip().rstrip("\\").strip()
    if not stripped:
        return True
    if stripped.startswith("--host "):
        return True
    if stripped.startswith("--port "):
        return True
    if re.match(r"^-tp\s+", stripped):
        return True
    if stripped.startswith("--tensor-parallel-size "):
        return True
    return False


def preserved_vllm_args(block):
    args = []
    for line in block[1:]:
        if should_skip_arg(line):
            continue
        normalized = normalize_arg_line(line)
        if normalized:
            args.append(normalized)
    return args


def build_script(args, original_text):
    lines = original_text.splitlines()
    start, end, block = collect_vllm_block(lines)
    exports = preserved_exports(lines[:start])
    vllm_args = preserved_vllm_args(block)

    output = [
        "# {} service startup script".format(args.model_name),
        "# Supported environment variables: MODEL_PATH, TP, GPU_RANGE, PORT, LOG_DIR",
        "",
        "# Defaults",
        "export GPU_RANGE=${GPU_RANGE:-" + args.gpu_range + "}",
        "export TP_SIZE=${TP:-" + str(args.tp) + "}",
        "export MODEL_PATH=${MODEL_PATH:-" + args.container_model_path + "}",
        "export PORT=${PORT:-" + str(args.port) + "}",
        "export LOG_DIR=${LOG_DIR:-./logs}",
        "",
        "model=${MODEL_PATH##*/}",
        'date=$(date "+%m%d")',
        'mkdir -p "${LOG_DIR}"',
        "",
        'if [[ "${CLEAR_COMPILE_CACHE:-0}" == "1" ]]; then',
        '    rm -rf "${HOME}/.cache" "${HOME}/.triton"',
        "fi",
        "",
        "export HIP_VISIBLE_DEVICES=${GPU_RANGE}",
    ]
    output.extend(exports)
    output.append("")

    command = [
        'vllm serve "${MODEL_PATH}" \\',
        "    --host 0.0.0.0 \\",
        "    --port ${PORT} \\",
        "    -tp ${TP_SIZE} \\",
    ]
    command.extend(vllm_args)
    if command[-1].rstrip().endswith("\\"):
        command[-1] = command[-1].rstrip()[:-1].rstrip()
    output.extend(command)
    return "\n".join(output) + "\n"


def print_next_register_command(args, service_script):
    command = [
        "bash",
        REGISTER_MODEL,
        "--model-name",
        args.model_name,
        "--model-short",
        args.model_short or "<MODEL_SHORT>",
        "--host-model-path",
        "<HOST_MODEL_PATH>",
        "--container-model-path",
        args.container_model_path,
        "--server-script",
        service_script,
        "--port",
        str(args.port),
        "--tp",
        str(args.tp),
        "--gpu-range",
        args.gpu_range,
        "--dry-run",
    ]
    print("NEXT_STEP_REGISTER_DRY_RUN_CMD=")
    print(" \\\n  ".join(shell_quote(x) if any(c in x for c in " <>") else x for x in command))


def print_self_command(args, service_script):
    command = [
        "bash",
        STANDARDIZE_SCRIPT,
        "--model-name",
        args.model_name,
        "--server-script",
        service_script,
        "--container-model-path",
        args.container_model_path,
        "--port",
        str(args.port),
        "--tp",
        str(args.tp),
        "--gpu-range",
        args.gpu_range,
        "--dry-run",
    ]
    if args.model_short:
        command.extend(["--model-short", args.model_short])
    print("STANDARDIZE_DRY_RUN_CMD=")
    print(" \\\n  ".join(shell_quote(x) if any(c in x for c in " <>") else x for x in command))


def parse_args():
    parser = argparse.ArgumentParser(description="Standardize a vLLM server script")
    parser.add_argument("--model-name", required=True)
    parser.add_argument("--server-script", required=True)
    parser.add_argument("--container-model-path", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--tp", type=int, required=True)
    parser.add_argument("--gpu-range", required=True)
    parser.add_argument("--model-short")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--backup", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    script_path = resolve_path(args.server_script)
    if not script_path.exists():
        raise SystemExit("server script does not exist: {}".format(script_path))

    original = script_path.read_text(encoding="utf-8")
    standardized = build_script(args, original)
    service_script = relative_to_skill(script_path)

    print("MODEL_NAME={}".format(args.model_name))
    if args.model_short:
        print("MODEL_SHORT={}".format(args.model_short))
    print("SERVER_SCRIPT={}".format(service_script))
    print("CONTAINER_MODEL_PATH={}".format(args.container_model_path))
    print("PORT={}".format(args.port))
    print("TP={}".format(args.tp))
    print("GPU_RANGE={}".format(args.gpu_range))

    if original == standardized:
        print("STATUS=already_standardized")
    elif args.dry_run:
        print("DRY_RUN=1, no files written.")
        diff = difflib.unified_diff(
            original.splitlines(),
            standardized.splitlines(),
            fromfile=str(script_path),
            tofile=str(script_path) + ".standardized",
            lineterm="",
        )
        print("STANDARDIZED_DIFF_BEGIN")
        for line in diff:
            print(line)
        print("STANDARDIZED_DIFF_END")
    else:
        if args.backup:
            backup = "{}.bak.{}".format(
                script_path, datetime.now().strftime("%Y%m%d%H%M%S")
            )
            shutil.copyfile(str(script_path), backup)
            print("BACKUP={}".format(backup))
        script_path.write_text(standardized, encoding="utf-8")
        try:
            os.chmod(str(script_path), 0o755)
        except OSError:
            pass
        print("UPDATED_SERVER_SCRIPT={}".format(script_path))

    print_self_command(args, service_script)
    print_next_register_command(args, service_script)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
