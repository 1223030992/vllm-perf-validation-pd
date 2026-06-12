#!/usr/bin/env python3
"""Standardize local Mooncake 1P1D server scripts without remote side effects."""

import argparse
import difflib
import os
import re
import shlex
import shutil
from pathlib import Path


DEFAULT_ROOT = Path(__file__).resolve().parents[2]
CONTROLLED_EXPORTS = {
    "HIP_VISIBLE_DEVICES", "VLLM_HOST_IP", "VLLM_MOONCAKE_BOOTSTRAP_PORT",
    "NCCL_SOCKET_IFNAME", "GLOO_SOCKET_IFNAME", "NCCL_IB_HCA",
    "MC_ENABLE_DEST_DEVICE_AFFINITY", "VLLM_TORCH_PROFILER_DIR",
}
VALUE_FLAGS = {
    "--port", "--host", "-tp", "--tensor-parallel-size", "-q", "--quantization",
    "--dtype", "--max_num_batched_tokens", "--max-num-batched-tokens",
    "--max-num-seqs", "--gpu-memory-utilization", "--max-model-len",
    "--speculative_config", "--speculative-config", "--compilation-config",
    "--kv-transfer-config", "--profiler-config", "--profiler_config",
}


def shell_quote(value):
    return shlex.quote(str(value))


def resolve(path):
    return Path(path).expanduser().resolve()


def command_tokens(text):
    lines = text.splitlines()
    start = None
    command = []
    for index, line in enumerate(lines):
        if re.search(r"(^\s*|[;&]\s*)vllm\s+serve\b", line):
            start = index
            break
    if start is None:
        raise SystemExit("vllm_serve_command_not_found=1")
    previous = ""
    for candidate in reversed(lines[:start]):
        if candidate.strip():
            previous = candidate.strip()
            break
    array_mode = previous.endswith("=(") or previous == "cmd=("
    index = start
    while index < len(lines):
        line = lines[index].strip()
        if array_mode and line == ")":
            break
        command.append(line[:-1].rstrip() if line.endswith("\\") else line)
        if not array_mode and not line.endswith("\\"):
            break
        index += 1
    joined = " ".join(command)
    prefix = re.search(r"\bvllm\s+serve\b", joined)
    return shlex.split(joined[prefix.start():]), lines[:start]


def parse_role_script(path):
    text = path.read_text(encoding="utf-8-sig")
    tokens, prefix_lines = command_tokens(text)
    if len(tokens) < 3:
        raise SystemExit("invalid_vllm_serve_command={}".format(path))
    model_path = tokens[2]
    assignments = {}
    assignment_pattern = re.compile(r"\b([A-Z][A-Z0-9_]*)=(?:\"([^\"]*)\"|'([^']*)'|([^;\s]+))")
    for line in prefix_lines:
        if line.lstrip().startswith("while [["):
            break
        for match in assignment_pattern.finditer(line):
            assignments[match.group(1)] = next((item for item in match.groups()[1:] if item is not None), "")

    values = {
        "model_path": model_path,
        "port": "8000",
        "tp": "1",
        "quantization": "",
        "dtype": "auto",
        "max_num_batched_tokens": "",
        "max_num_seqs": "",
        "gpu_memory_utilization": "",
        "max_model_len": "",
        "speculative_config": "",
        "compilation_config": "",
    }
    aliases = {
        "--port": "port", "-tp": "tp", "--tensor-parallel-size": "tp",
        "-q": "quantization", "--quantization": "quantization", "--dtype": "dtype",
        "--max_num_batched_tokens": "max_num_batched_tokens",
        "--max-num-batched-tokens": "max_num_batched_tokens",
        "--max-num-seqs": "max_num_seqs", "--gpu-memory-utilization": "gpu_memory_utilization",
        "--max-model-len": "max_model_len", "--speculative_config": "speculative_config",
        "--speculative-config": "speculative_config", "--compilation-config": "compilation_config",
    }
    extras = []
    index = 3
    while index < len(tokens):
        token = tokens[index]
        if token in VALUE_FLAGS:
            if index + 1 >= len(tokens):
                raise SystemExit("missing_flag_value={} in {}".format(token, path))
            if token in aliases:
                values[aliases[token]] = tokens[index + 1]
            index += 2
            continue
        if token == "--enforce-eager":
            index += 1
            continue
        extras.append(token)
        index += 1

    variable_defaults = {
        "model_path": "MODEL_PATH", "port": "PORT", "tp": "TP",
        "quantization": "QUANTIZATION", "dtype": "DTYPE",
        "max_num_batched_tokens": "MAX_NUM_BATCHED_TOKENS", "max_num_seqs": "MAX_NUM_SEQS",
        "gpu_memory_utilization": "GPU_MEMORY_UTILIZATION", "max_model_len": "MAX_MODEL_LEN",
        "speculative_config": "SPECULATIVE_CONFIG", "compilation_config": "COMPILATION_CONFIG",
    }
    for key, variable in variable_defaults.items():
        if values[key] in ("$" + variable, "${" + variable + "}"):
            values[key] = assignments.get(variable, "")
    if not values["tp"]:
        values["tp"] = "1"
    if not values["port"]:
        values["port"] = "8000"
    if not values["dtype"]:
        values["dtype"] = "auto"

    exports = []
    seen = set()
    for line in prefix_lines:
        match = re.match(r"^\s*export\s+([A-Za-z_][A-Za-z0-9_]*)=", line)
        if not match or match.group(1) in CONTROLLED_EXPORTS or match.group(1) in seen:
            continue
        exports.append(line.strip())
        seen.add(match.group(1))
    values["exports"] = exports
    values["extras"] = extras
    return values


def role_script(role, defaults):
    required = "MODEL_PATH PORT VLLM_HOST_IP GPU_RANGE TP"
    transfer_usage = " --transfer-port PORT" if role == "prefill" else ""
    transfer_init = 'TRANSFER_PORT=""; ' if role == "prefill" else ""
    transfer_case = '    --transfer-port) TRANSFER_PORT="$2"; shift 2 ;;\n' if role == "prefill" else ""
    transfer_required = " TRANSFER_PORT" if role == "prefill" else ""
    producer_export = 'export VLLM_MOONCAKE_BOOTSTRAP_PORT="$TRANSFER_PORT"\n' if role == "prefill" else ""
    role_name = "kv_producer" if role == "prefill" else "kv_consumer"
    eager = "  --enforce-eager\n" if role == "prefill" else ""
    extra_lines = "\n".join(defaults["exports"])
    static_extras = " ".join(shell_quote(item) for item in defaults["extras"])
    quant_default = defaults["quantization"]
    text = """#!/usr/bin/env bash
set -euo pipefail

MODEL_PATH={model}; PORT={port}; {transfer_init}VLLM_HOST_IP=""; GPU_RANGE="0,1,2,3,4,5,6,7"; TP={tp}
NETWORK_IFNAME=""; NCCL_IB_HCA=""; MOONCAKE_DEST_DEVICE_AFFINITY="1"
QUANTIZATION={quant}; DTYPE={dtype}; MAX_NUM_BATCHED_TOKENS={max_tokens}
MAX_NUM_SEQS={max_seqs}; GPU_MEMORY_UTILIZATION={gpu_mem}; MAX_MODEL_LEN={max_len}
SPECULATIVE_CONFIG={spec}; COMPILATION_CONFIG={comp}; EXTRA_ARGS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model-path) MODEL_PATH="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
{transfer_case}    --vllm-host-ip) VLLM_HOST_IP="$2"; shift 2 ;;
    --gpu-range) GPU_RANGE="$2"; shift 2 ;;
    --tp) TP="$2"; shift 2 ;;
    --network-ifname) NETWORK_IFNAME="$2"; shift 2 ;;
    --nccl-ib-hca) NCCL_IB_HCA="$2"; shift 2 ;;
    --mooncake-dest-device-affinity) MOONCAKE_DEST_DEVICE_AFFINITY="$2"; shift 2 ;;
    --quantization) QUANTIZATION="$2"; shift 2 ;;
    --dtype) DTYPE="$2"; shift 2 ;;
    --max-num-batched-tokens) MAX_NUM_BATCHED_TOKENS="$2"; shift 2 ;;
    --max-num-seqs) MAX_NUM_SEQS="$2"; shift 2 ;;
    --gpu-memory-utilization) GPU_MEMORY_UTILIZATION="$2"; shift 2 ;;
    --max-model-len) MAX_MODEL_LEN="$2"; shift 2 ;;
    --speculative-config) SPECULATIVE_CONFIG="$2"; shift 2 ;;
    --compilation-config) COMPILATION_CONFIG="$2"; shift 2 ;;
    --extra-args) EXTRA_ARGS="$2"; shift 2 ;;
    *) echo "unknown_arg=$1" >&2; exit 2 ;;
  esac
done

for var in {required}{transfer_required}; do
  [[ -n "${{!var}}" ]] || {{ echo "missing_arg=$var" >&2; exit 2; }}
done
export HIP_VISIBLE_DEVICES="$GPU_RANGE"
export VLLM_HOST_IP
{producer_export}export MC_ENABLE_DEST_DEVICE_AFFINITY="$MOONCAKE_DEST_DEVICE_AFFINITY"
[[ -z "$NETWORK_IFNAME" ]] || {{ export NCCL_SOCKET_IFNAME="$NETWORK_IFNAME"; export GLOO_SOCKET_IFNAME="$NETWORK_IFNAME"; }}
[[ -z "$NCCL_IB_HCA" ]] || export NCCL_IB_HCA
{extra_lines}

cmd=(vllm serve "$MODEL_PATH" --kv-transfer-config '{{"kv_connector":"MooncakeConnector","kv_role":"{role_name}"}}'
{eager}  -tp "$TP" --port "$PORT" --dtype "$DTYPE")
[[ -z "$QUANTIZATION" ]] || cmd+=(-q "$QUANTIZATION")
[[ -z "$MAX_NUM_BATCHED_TOKENS" ]] || cmd+=(--max_num_batched_tokens "$MAX_NUM_BATCHED_TOKENS")
[[ -z "$MAX_NUM_SEQS" ]] || cmd+=(--max-num-seqs "$MAX_NUM_SEQS")
[[ -z "$GPU_MEMORY_UTILIZATION" ]] || cmd+=(--gpu-memory-utilization "$GPU_MEMORY_UTILIZATION")
[[ -z "$MAX_MODEL_LEN" ]] || cmd+=(--max-model-len "$MAX_MODEL_LEN")
[[ -z "$SPECULATIVE_CONFIG" ]] || cmd+=(--speculative_config "$SPECULATIVE_CONFIG")
[[ -z "$COMPILATION_CONFIG" ]] || cmd+=(--compilation-config "$COMPILATION_CONFIG")
cmd+=({static_extras})
if [[ -n "$EXTRA_ARGS" ]]; then read -r -a extra_argv <<< "$EXTRA_ARGS"; cmd+=("${{extra_argv[@]}}"); fi
exec "${{cmd[@]}}"
""".format(
        model=shell_quote(defaults["model_path"]), port=shell_quote(defaults["port"]),
        transfer_init=transfer_init, tp=shell_quote(defaults["tp"]), quant=shell_quote(quant_default),
        dtype=shell_quote(defaults["dtype"]), max_tokens=shell_quote(defaults["max_num_batched_tokens"]),
        max_seqs=shell_quote(defaults["max_num_seqs"]), gpu_mem=shell_quote(defaults["gpu_memory_utilization"]),
        max_len=shell_quote(defaults["max_model_len"]), spec=shell_quote(defaults["speculative_config"]),
        comp=shell_quote(defaults["compilation_config"]), transfer_case=transfer_case,
        required=required, transfer_required=transfer_required, producer_export=producer_export,
        extra_lines=extra_lines, role_name=role_name, eager=eager, static_extras=static_extras,
    )
    return text


def proxy_script():
    return """#!/usr/bin/env bash
set -euo pipefail
PROXY_SCRIPT=""; PREFILL_URL=""; PREFILL_TRANSFER_PORT=""; DECODE_URL=""; PORT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --proxy-script) PROXY_SCRIPT="$2"; shift 2 ;;
    --prefill-url) PREFILL_URL="$2"; shift 2 ;;
    --prefill-transfer-port) PREFILL_TRANSFER_PORT="$2"; shift 2 ;;
    --decode-url) DECODE_URL="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    *) echo "unknown_arg=$1" >&2; exit 2 ;;
  esac
done
for var in PROXY_SCRIPT PREFILL_URL PREFILL_TRANSFER_PORT DECODE_URL PORT; do
  [[ -n "${!var}" ]] || { echo "missing_arg=$var" >&2; exit 2; }
done
[[ -f "$PROXY_SCRIPT" ]] || { echo "proxy_script_missing=$PROXY_SCRIPT" >&2; exit 1; }
prefill_host="${PREFILL_URL#*://}"; prefill_host="${prefill_host%%:*}"
decode_host="${DECODE_URL#*://}"; decode_host="${decode_host%%:*}"
export NO_PROXY="127.0.0.1,localhost,${prefill_host},${decode_host}${NO_PROXY:+,${NO_PROXY}}"
export no_proxy="$NO_PROXY" PYTHONUNBUFFERED=1
exec python3 -u "$PROXY_SCRIPT" --prefill "$PREFILL_URL" "$PREFILL_TRANSFER_PORT" --decode "$DECODE_URL" --port "$PORT"
"""


def diff_text(path, content):
    old = path.read_text(encoding="utf-8-sig") if path.exists() else ""
    return "\n".join(difflib.unified_diff(old.splitlines(), content.splitlines(), str(path), str(path) + ".standardized", lineterm=""))


def main():
    parser = argparse.ArgumentParser(description="Standardize Mooncake 1P1D server scripts")
    parser.add_argument("--model-short", required=True)
    parser.add_argument("--prefill-source", required=True)
    parser.add_argument("--decode-source", required=True)
    parser.add_argument("--proxy-source", required=True)
    parser.add_argument("--skill-root", default=str(DEFAULT_ROOT))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--preserve-raw", action="store_true")
    args = parser.parse_args()
    if not re.match(r"^[a-z0-9][a-z0-9-]*$", args.model_short):
        raise SystemExit("invalid_model_short={}".format(args.model_short))
    sources = {"p_server.sh": resolve(args.prefill_source), "d_server.sh": resolve(args.decode_source), "run_proxy.sh": resolve(args.proxy_source)}
    for path in sources.values():
        if not path.is_file():
            raise SystemExit("source_script_missing={}".format(path))
    root = resolve(args.skill_root)
    target = root / "scripts" / "pd-server" / args.model_short
    contents = {
        "p_server.sh": role_script("prefill", parse_role_script(sources["p_server.sh"])),
        "d_server.sh": role_script("decode", parse_role_script(sources["d_server.sh"])),
        "run_proxy.sh": proxy_script(),
    }
    for name, content in contents.items():
        destination = target / name
        if destination.exists() and destination.read_text(encoding="utf-8-sig") != content and not (args.overwrite or args.dry_run):
            raise SystemExit("target_exists={}; pass --overwrite".format(destination))
        print("STANDARDIZED_TARGET={}".format(destination))
        print("STANDARDIZED_DIFF_BEGIN")
        print(diff_text(destination, content))
        print("STANDARDIZED_DIFF_END")
    if args.dry_run:
        print("PD_SERVER_STANDARDIZE_DRY_RUN_DONE=1")
        return 0
    target.mkdir(parents=True, exist_ok=True)
    for name, content in contents.items():
        destination = target / name
        destination.write_text(content, encoding="utf-8", newline="\n")
        os.chmod(str(destination), 0o755)
    if args.preserve_raw:
        raw = target / "raw"
        raw.mkdir(exist_ok=True)
        for name, source in sources.items():
            shutil.copyfile(str(source), str(raw / name))
    print("PD_SERVER_STANDARDIZE_DONE=1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
