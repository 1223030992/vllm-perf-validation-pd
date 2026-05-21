#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
用法:
  show_state.sh --state STATE [--node NODE] [--full]

说明:
  固定入口读取 state.json，避免使用 python3 -c 触发额外权限询问。
  如果传入 --node，会在目标节点宿主机执行读取。
USAGE
}

quote_sh() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

state_host_path() {
  local state="$1"
  local output_container_root="${OUTPUT_CONTAINER_ROOT:-/mnt/skilltest/vllm-perf-validation-single}"
  local output_host_root="${OUTPUT_HOST_ROOT:-/public/home/liuzhh8/skilltest/vllm-perf-validation-single}"
  if [[ "$state" == "$output_container_root"* ]]; then
    printf '%s%s\n' "$output_host_root" "${state#$output_container_root}"
  else
    printf '%s\n' "$state"
  fi
}

NODE=""
STATE=""
FULL=0
SKILL_HOST_ROOT="${SKILL_HOST_ROOT:-/public/home/liuzhh8/.claude/skills/vllm-perf-validation-single}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --full) FULL=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$STATE" ]] || { echo "缺少参数: --state" >&2; exit 2; }
STATE_HOST="$(state_host_path "$STATE")"

FULL_ARG=""
if [[ "$FULL" == "1" ]]; then
  FULL_ARG=" --full"
fi

if [[ -n "$NODE" ]]; then
  ssh "$NODE" "python3 $(quote_sh "$SKILL_HOST_ROOT/scripts/ops/show_state.py") --state $(quote_sh "$STATE_HOST")$FULL_ARG"
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  python3 "$SCRIPT_DIR/show_state.py" --state "$STATE_HOST" ${FULL_ARG}
fi
