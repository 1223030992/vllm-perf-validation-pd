#!/usr/bin/env python3
"""Register a new model profile/example for the vLLM perf validation skill.

This script is intentionally local-only: it never connects to SSH, Docker, or GPUs.
It is Python 3.6 compatible because some target hosts only provide Python 3.6.
"""

import argparse
import os
import re
import shutil
from datetime import datetime
from pathlib import Path


SKILL_ROOT = Path(__file__).resolve().parents[2]
PROFILES_DIR = SKILL_ROOT / "references" / "profiles"
EXAMPLES_DIR = SKILL_ROOT / "references" / "examples"
CONVENTIONS_FILE = SKILL_ROOT / "references" / "conventions.md"
SERVER_SCRIPTS_DIR = SKILL_ROOT / "scripts" / "server-scripts"
RUN_SINGLE_TASK = (
    "/public/home/liuzhh8/.claude/skills/vllm-perf-validation-single/"
    "scripts/ops/run_single_task.sh"
)


def normalize_name(name):
    return name.strip().strip("/")


def detect_precision(model_name):
    upper = model_name.upper()
    if "W8A8" in upper or "INT8" in upper:
        return "int8"
    if "W8A16" in upper or "FP8" in upper:
        return "fp8"
    return "bf16"


def precision_suffix(precision):
    if precision == "int8":
        return "int8"
    if precision == "fp8":
        return "fp8"
    return ""


def clean_version(version):
    return version.replace(".", "")


def derive_model_short(model_name, precision=None):
    name = normalize_name(model_name)
    precision = precision or detect_precision(name)
    suffix = precision_suffix(precision)

    m = re.search(r"(?i)\bGLM-([0-9]+(?:\.[0-9]+)?)", name)
    if m:
        return "glm{}{}".format(clean_version(m.group(1)), suffix)

    m = re.search(r"(?i)\bQwen([0-9]+(?:\.[0-9]+)?)-([0-9]+)B", name)
    if m:
        return "qwen{}b{}{}".format(clean_version(m.group(1)), m.group(2), suffix)

    m = re.search(
        r"(?i)\bDeepSeek-R1-Distill-([A-Za-z0-9.]+)-([0-9]+)B",
        name,
    )
    if m:
        base = re.sub(r"[^a-z0-9]", "", m.group(1).lower())
        return "dsr1distill{}b{}{}".format(base, m.group(2), suffix)

    # Conservative fallback: alnum-only basename + precision suffix.
    base = re.sub(r"[^a-z0-9]", "", name.lower())
    return "{}{}".format(base, suffix)


def default_port(model_name):
    name = normalize_name(model_name)
    if re.search(r"(?i)\bGLM-4\.7\b", name):
        return 9348
    if re.search(r"(?i)\bGLM-5\b", name) and not re.search(r"(?i)\bGLM-5\.1\b", name):
        return 9349
    if re.search(r"(?i)\bGLM-5\.1\b", name):
        return 9350
    return None


def host_to_container_path(host_path):
    path = host_path.rstrip("/")
    mappings = [
        ("/public/opendas/DL_DATA/llm-models", "/model"),
        ("/public4/share", "/model1"),
        ("/public4/opendas/DL_DATA", "/model2"),
    ]
    for host_root, container_root in mappings:
        if path == host_root:
            return container_root
        if path.startswith(host_root + "/"):
            return container_root + path[len(host_root) :]
    return None


def relative_to_skill(path):
    p = Path(path)
    try:
        return str(p.resolve().relative_to(SKILL_ROOT)).replace("\\", "/")
    except ValueError:
        return None


def resolve_service_script(server_script, overwrite=False):
    src = Path(server_script)
    if not src.is_absolute():
        src = (SKILL_ROOT / server_script).resolve()
    if not src.exists():
        raise SystemExit("server_script 不存在: {}".format(src))

    rel = relative_to_skill(str(src))
    if rel and rel.startswith("scripts/server-scripts/"):
        return rel, src, False

    dest = SERVER_SCRIPTS_DIR / src.name
    if dest.exists() and not overwrite:
        raise SystemExit(
            "目标服务脚本已存在: {}；如需覆盖请传 --overwrite".format(dest)
        )
    return "scripts/server-scripts/{}".format(src.name), src, True


def shell_quote(value):
    return "'" + str(value).replace("'", "'\\''") + "'"


def read_text(path):
    if not Path(path).exists():
        return ""
    return Path(path).read_text(encoding="utf-8")


def extract_vllm_params(script_text):
    params = {}
    pairs = [
        ("max_model_len", r"--max-model-len\s+([0-9]+)"),
        ("gpu_memory_utilization", r"--gpu-memory-utilization\s+([0-9.]+)"),
        ("quantization", r"(?:^|\s)-q\s+([A-Za-z0-9_]+)"),
        ("dtype", r"--dtype\s+([A-Za-z0-9_]+)"),
        ("max_num_seqs", r"--max-num-seqs\s+([0-9]+)"),
        ("max_num_batched_tokens", r"--max[-_]num[-_]batched[-_]tokens\s+([0-9]+)"),
        ("kv_cache_dtype", r"--kv-cache-dtype\s+([A-Za-z0-9_]+)"),
    ]
    for key, pattern in pairs:
        m = re.search(pattern, script_text, re.MULTILINE)
        if m:
            params[key] = m.group(1)
    return params


def extract_env_vars(script_text):
    result = []
    for match in re.finditer(r"^\s*export\s+([A-Za-z_][A-Za-z0-9_]*)=", script_text, re.MULTILINE):
        name = match.group(1)
        if name not in result:
            result.append(name)
    return result


def validate_server_script(script_text):
    warnings = []
    if "MODEL_PATH" not in script_text:
        warnings.append("未检测到 MODEL_PATH 参数化")
    if "GPU_RANGE" not in script_text:
        warnings.append("未检测到 GPU_RANGE 参数化")
    if "PORT" not in script_text:
        warnings.append("未检测到 PORT 参数化")
    if "TP" not in script_text and "TP_SIZE" not in script_text:
        warnings.append("未检测到 TP 参数化")
    return warnings


def existing_short_mapping(short_name):
    text = read_text(CONVENTIONS_FILE)
    for line in text.splitlines():
        parts = [p.strip() for p in line.strip().strip("|").split("|")]
        if len(parts) >= 2 and parts[1] == short_name:
            return parts[0]
    return None


def update_conventions(model_name, model_short, precision, port):
    text = read_text(CONVENTIONS_FILE)

    def insert_row_after_table_heading(current_text, heading_pattern, row):
        lines = current_text.splitlines()
        if row in lines:
            return current_text
        row_parts = [p.strip() for p in row.strip().strip("|").split("|")]
        heading_idx = None
        for idx, line in enumerate(lines):
            if re.search(heading_pattern, line):
                heading_idx = idx
                break
        if heading_idx is None:
            return current_text.rstrip() + "\n\n" + row + "\n"

        table_started = False
        insert_idx = None
        for idx in range(heading_idx + 1, len(lines)):
            line = lines[idx]
            if line.startswith("|"):
                table_started = True
                line_parts = [p.strip() for p in line.strip().strip("|").split("|")]
                if (
                    len(row_parts) >= 2
                    and len(line_parts) >= 2
                    and line_parts[0] == row_parts[0]
                    and line_parts[1] == row_parts[1]
                ):
                    return current_text
                insert_idx = idx + 1
                continue
            if table_started:
                break
        if insert_idx is None:
            insert_idx = len(lines)
        lines.insert(insert_idx, row)
        return "\n".join(lines) + "\n"

    entry = "| {} | {} | {} |".format(model_name, model_short, precision)
    text = insert_row_after_table_heading(text, r"MODEL_SHORT", entry)

    port_label = "{} 系列".format(model_name.split("-W", 1)[0].split("-Channel", 1)[0])
    port_row = "| {} | {} |".format(port_label, port)
    if port and port_row not in text:
        text = insert_row_after_table_heading(text, r"端口|默认端口", port_row)

    CONVENTIONS_FILE.write_text(text, encoding="utf-8")


def yaml_quote(value):
    return '"{}"'.format(str(value).replace('"', '\\"'))


def write_profile(args, service_script, vllm_params, env_vars):
    profile = PROFILES_DIR / "{}.yaml".format(args.model_short)
    if profile.exists() and not args.overwrite:
        raise SystemExit("Profile 已存在: {}；如需覆盖请传 --overwrite".format(profile))
    lines = [
        "# 模型 Profile: {}".format(args.model_name),
        "# 自动生成于: {}".format(datetime.now().strftime("%Y-%m-%d %H:%M:%S")),
        "",
        "model:",
        "  display_name: {}".format(yaml_quote(args.model_name)),
        "  short_name: {}".format(yaml_quote(args.model_short)),
        "  host_model_path: {}".format(yaml_quote(args.host_model_path)),
        "  container_model_path: {}".format(yaml_quote(args.container_model_path)),
        "  served_model_id: null",
        "  bench_model_id: null",
        "  precision: {}".format(yaml_quote(args.precision)),
        "",
        "resource:",
        "  default_tp: {}".format(args.tp),
        "  min_gpu: {}".format(args.tp),
        "  default_port: {}".format(args.port),
        "",
        "service:",
        "  script: {}".format(yaml_quote(service_script)),
        "  vllm_params:",
    ]
    if vllm_params:
        for key in sorted(vllm_params):
            value = vllm_params[key]
            if re.match(r"^[0-9.]+$", value):
                lines.append("    {}: {}".format(key, value))
            else:
                lines.append("    {}: {}".format(key, yaml_quote(value)))
    else:
        lines.append("    {}")
    lines.extend(["  env_vars:"])
    if env_vars:
        lines.extend(["    - {}".format(name) for name in env_vars])
    else:
        lines.append("    []")
    lines.extend(
        [
            "",
            "health_check:",
            '  endpoint: "/v1/chat/completions"',
            '  prompt: "\u4f60\u597d"',
            "  timeout_seconds: {}".format(args.timeout),
            "",
        ]
    )
    profile.write_text("\n".join(lines), encoding="utf-8")
    return profile


def write_example(args, service_script):
    example = EXAMPLES_DIR / "{}-test-task.yaml".format(args.model_short)
    if example.exists() and not args.overwrite:
        raise SystemExit("Example 已存在: {}；如需覆盖请传 --overwrite".format(example))
    content = """task:
  name: vllm_perf_{short}
  run_id: auto
  owner: liuzhihuan
  description: "{model_name} custom smoke"

mode: single

paths:
  skill_host_root: /public/home/liuzhh8/.claude/skills/vllm-perf-validation-single
  skill_container_root: /mnt/.claude/skills/vllm-perf-validation-single
  output_host_root: /public/home/liuzhh8/skilltest/vllm-perf-validation-single
  output_container_root: /mnt/skilltest/vllm-perf-validation-single

image:
  name: null
  pull_policy: if_not_present

node:
  ip: null
  dcu_type: null
  gpu_count: 8

container:
  name_template: "lzh-agent-test-<MMDD>-<MODEL_SHORT>-<IMAGE_PREFIX>"

models:
  - name: "{model_name}"
    model_short: "{short}"
    host_model_path: {host_model_path}
    container_model_path: {container_model_path}
    served_model_id: null
    bench_model_id: null
    tp: {tp}
    port: {port}
    gpu_range: "{gpu_range}"
    service_script: {service_script}

service:
  health_check:
    endpoint: /v1/chat/completions
    timeout_seconds: {timeout}

test:
  mode: custom
  params:
    input_lens: "512"
    output_len: 32
    concurrencies: "1"
    num_prompts_mult: 1
    percentiles: "50,95,99"

output:
  work_dir: /public/home/liuzhh8/skilltest/vllm-perf-validation-single/work_dirs
  report_dir: /public/home/liuzhh8/skilltest/vllm-perf-validation-single/reports
  csv_dir: /public/home/liuzhh8/skilltest/vllm-perf-validation-single/csvs
""".format(
        short=args.model_short,
        model_name=args.model_name,
        host_model_path=args.host_model_path,
        container_model_path=args.container_model_path,
        service_script=service_script,
        tp=args.tp,
        port=args.port,
        gpu_range=args.gpu_range,
        timeout=args.timeout,
    )
    example.write_text(content, encoding="utf-8")
    return example


def print_run_single_task(args, service_script):
    command = [
        "bash",
        RUN_SINGLE_TASK,
        "--node",
        "<NODE>",
        "--image",
        "<IMAGE>",
        "--model-name",
        args.model_name,
        "--model-short",
        args.model_short,
        "--host-model-path",
        args.host_model_path,
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
        "--test-mode",
        "custom",
        "--input-lens",
        "512",
        "--output-len",
        "32",
        "--concurrencies",
        "1",
        "--num-prompts-mult",
        "1",
        "--percentiles",
        "50,95,99",
        "--timeout",
        str(args.timeout),
        "--image-prefix",
        "<IMAGE_PREFIX>",
        "--dry-run",
    ]
    print("RUN_SINGLE_TASK_DRY_RUN_CMD=")
    print(" \\\n  ".join(shell_quote(x) if any(c in x for c in " <>") else x for x in command))


def is_glm_model(model_name):
    return re.search(r"(?i)\bGLM-", model_name) is not None


def infer_tp_from_script(script_text):
    patterns = [
        r"(?:^|\s)-tp\s+([0-9]+)(?:\s|\\|$)",
        r"--tensor-parallel-size\s+([0-9]+)(?:\s|\\|$)",
        r"^\s*export\s+TP_SIZE=([0-9]+)\s*$",
        r"^\s*export\s+TP=([0-9]+)\s*$",
        r"^\s*TP_SIZE=([0-9]+)\s*$",
        r"^\s*TP=([0-9]+)\s*$",
        r"^\s*export\s+TP_SIZE=\$\{TP:-([0-9]+)\}\s*$",
        r"^\s*export\s+TP=\$\{TP:-([0-9]+)\}\s*$",
    ]
    for pattern in patterns:
        m = re.search(pattern, script_text, re.MULTILINE)
        if m:
            return int(m.group(1))
    return None


def default_gpu_range_for_tp(tp):
    return ",".join(str(i) for i in range(int(tp)))


def validate_server_script(script_text):
    warnings = []
    if not re.search(r"vllm\s+serve[\s\S]*\$\{?MODEL_PATH", script_text):
        warnings.append("server script does not pass MODEL_PATH to vllm serve")
    if "GPU_RANGE" not in script_text:
        warnings.append("server script does not expose GPU_RANGE")
    if not re.search(r"--port\s+['\"]?\$\{?PORT", script_text):
        warnings.append("server script does not pass PORT to vllm serve")
    if not re.search(r"(?:-tp|--tensor-parallel-size)\s+['\"]?\$\{?(?:TP|TP_SIZE)", script_text):
        warnings.append("server script does not pass TP/TP_SIZE to vllm serve")
    return warnings


def parse_args():
    parser = argparse.ArgumentParser(description="Register a model for vLLM perf validation")
    parser.add_argument("--model-name", required=True)
    parser.add_argument("--host-model-path", required=True)
    parser.add_argument("--server-script", required=True)
    parser.add_argument("--model-short")
    parser.add_argument("--container-model-path")
    parser.add_argument("--port", type=int)
    parser.add_argument("--tp", type=int)
    parser.add_argument("--gpu-range")
    parser.add_argument("--precision")
    parser.add_argument("--timeout", type=int)
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--allow-static-server-script", action="store_true")
    return parser.parse_args()


def enrich_args(args, script_text=""):
    args.model_name = normalize_name(args.model_name)
    args.host_model_path = args.host_model_path.rstrip("/")
    args.precision = args.precision or detect_precision(args.model_name)
    args.model_short = args.model_short or derive_model_short(args.model_name, args.precision)
    if not re.match(r"^[a-z0-9]+$", args.model_short):
        raise SystemExit("MODEL_SHORT 只能包含小写字母和数字: {}".format(args.model_short))
    if not args.container_model_path:
        args.container_model_path = host_to_container_path(args.host_model_path)
    if not args.container_model_path:
        raise SystemExit("无法从 host_model_path 推导容器路径，请显式传 --container-model-path")
    args.port = args.port or default_port(args.model_name)
    if args.port is None:
        raise SystemExit("非 GLM 模型不会自动分配端口，请显式传 --port")
    if args.tp is None:
        if is_glm_model(args.model_name):
            args.tp = 8
        else:
            args.tp = infer_tp_from_script(script_text)
            if args.tp is None:
                raise SystemExit("non-GLM model requires --tp or a server script with static TP")
    if args.gpu_range is None:
        if is_glm_model(args.model_name):
            args.gpu_range = "0,1,2,3,4,5,6,7"
        else:
            args.gpu_range = default_gpu_range_for_tp(args.tp)
    if args.timeout is None:
        if args.model_short.startswith("glm5") and not args.model_short.startswith("glm51"):
            args.timeout = 3600
        else:
            args.timeout = 2400
    return args


def main():
    args = parse_args()
    service_script, src, should_copy = resolve_service_script(
        args.server_script, overwrite=args.overwrite
    )
    script_text = read_text(src)
    args = enrich_args(args, script_text)
    existing = existing_short_mapping(args.model_short)
    if existing and existing != args.model_name:
        raise SystemExit(
            "MODEL_SHORT 冲突: {} 已映射到 {}，请显式传入其他 --model-short".format(
                args.model_short, existing
            )
        )

    vllm_params = extract_vllm_params(script_text)
    env_vars = extract_env_vars(script_text)
    warnings = validate_server_script(script_text)
    if warnings and not args.dry_run and not args.allow_static_server_script:
        raise SystemExit(
            "server script is not parameterized; fix it or pass --allow-static-server-script"
        )

    print("MODEL_NAME={}".format(args.model_name))
    print("MODEL_SHORT={}".format(args.model_short))
    print("PRECISION={}".format(args.precision))
    print("HOST_MODEL_PATH={}".format(args.host_model_path))
    print("CONTAINER_MODEL_PATH={}".format(args.container_model_path))
    print("PORT={}".format(args.port))
    print("TP={}".format(args.tp))
    print("GPU_RANGE={}".format(args.gpu_range))
    print("SERVICE_SCRIPT={}".format(service_script))
    for warning in warnings:
        print("WARN={}".format(warning))

    if args.dry_run:
        print("DRY_RUN=1，不写入任何文件。")
        print_run_single_task(args, service_script)
        return 0

    PROFILES_DIR.mkdir(parents=True, exist_ok=True)
    EXAMPLES_DIR.mkdir(parents=True, exist_ok=True)
    SERVER_SCRIPTS_DIR.mkdir(parents=True, exist_ok=True)
    if should_copy:
        dest = SERVER_SCRIPTS_DIR / Path(service_script).name
        shutil.copyfile(str(src), str(dest))
        try:
            os.chmod(str(dest), 0o755)
        except OSError:
            pass
        print("COPIED_SERVER_SCRIPT={}".format(dest))

    profile = write_profile(args, service_script, vllm_params, env_vars)
    example = write_example(args, service_script)
    update_conventions(args.model_name, args.model_short, args.precision, args.port)
    print("PROFILE={}".format(profile))
    print("EXAMPLE={}".format(example))
    print("CONVENTIONS={}".format(CONVENTIONS_FILE))
    print_run_single_task(args, service_script)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
