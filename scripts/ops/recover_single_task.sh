#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
用法:
  recover_single_task.sh --state STATE [--node NODE] [--container NAME] [--port PORT] [--report-dir DIR] [--run-id ID]

说明:
  仅用于 run_single_task.sh 在 stop/report 阶段失败后的受控恢复。
  本脚本仍只调用 scripts/ops 下的 stop_service.sh、render_report.py 和 show_state.sh，
  不手写 docker stop，不执行 docker rm。
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_HOST_ROOT="${OUTPUT_HOST_ROOT:-/public/home/liuzhh8/skilltest/vllm-perf-validation-single}"

STATE=""
NODE=""
CONTAINER=""
PORT=""
REPORT_DIR=""
RUN_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state) STATE="$2"; shift 2 ;;
    --node) NODE="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --report-dir) REPORT_DIR="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$STATE" ]] || { echo "缺少参数: --state" >&2; exit 2; }

state_get() {
  local path="$1"
  python3 - "$STATE" "$path" <<'PY'
import json
import sys

state_file, dotted = sys.argv[1], sys.argv[2]
with open(state_file, "r", encoding="utf-8-sig") as f:
    data = json.load(f)
cur = data
for key in dotted.split("."):
    if not isinstance(cur, dict) or key not in cur:
        print("")
        sys.exit(0)
    cur = cur[key]
print(cur if cur is not None else "")
PY
}

[[ -n "$NODE" ]] || NODE="$(state_get node)"
[[ -n "$CONTAINER" ]] || CONTAINER="$(state_get container.name)"
[[ -n "$PORT" ]] || PORT="$(state_get model.port)"
CSV_HOST="$(state_get paths.csv_file_host)"
if [[ -z "$CSV_HOST" ]]; then
  CSV_HOST="$(state_get paths.csv_file)"
fi
if [[ -z "$REPORT_DIR" ]]; then
  REPORT_DIR="${OUTPUT_HOST_ROOT}/reports"
fi
if [[ -z "$RUN_ID" ]]; then
  report_json="$(state_get paths.report_json_host)"
  if [[ -n "$report_json" ]]; then
    RUN_ID="$(basename "$report_json" .json)"
  else
    RUN_ID="$(basename "$(dirname "$STATE")")"
  fi
fi

for var in NODE CONTAINER PORT CSV_HOST RUN_ID REPORT_DIR; do
  [[ -n "${!var}" ]] || { echo "state 中缺少恢复所需字段: ${var}" >&2; exit 2; }
done

echo "== recover_stop_service =="
SKILL_HOST_ROOT="$SKILL_ROOT" bash "$SCRIPT_DIR/stop_service.sh" \
  --node "$NODE" \
  --container "$CONTAINER" \
  --port "$PORT" \
  --state "$STATE"

echo "== recover_render_report =="
python3 "$SCRIPT_DIR/render_report.py" \
  --run-id "$RUN_ID" \
  --state "$STATE" \
  --csv "$CSV_HOST" \
  --report-dir "$REPORT_DIR"

echo "== recover_show_state =="
bash "$SCRIPT_DIR/show_state.sh" --state "$STATE"
