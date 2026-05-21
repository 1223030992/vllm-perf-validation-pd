#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
用法:
  run_single_task.sh --node NODE --image IMAGE --model-name NAME --model-short SHORT \
    --host-model-path PATH --container-model-path PATH --server-script SCRIPT \
    --port PORT --tp TP --gpu-range RANGE --test-mode custom \
    --input-lens "512" --output-len 32 --concurrencies "1" \
    --num-prompts-mult 1 --percentiles "50,95,99" [--assume-yes]

常用选项:
  --date MMDD                 覆盖容器名日期，默认当前 MMDD
  --image-prefix PREFIX       覆盖容器名镜像短标识
  --container NAME            指定已符合规范的容器名
  --run-id ID                 指定报告 run_id
  --timeout SECONDS           wait_vllm_ready 超时，默认 1800；glm51* 默认 2400
  --interval SECONDS          wait_vllm_ready 轮询间隔，默认 60
  --report-dir PATH           报告目录，默认宿主机 reports 目录
  --assume-yes                用户已授权时跳过脚本内确认
  --dry-run                   只打印将执行的步骤，不执行远端操作
  --allow-image-prefix-fallback
                              镜像 inspect 失败时允许退回 tag 前 4 位

说明:
  该脚本是 single 模式稳定入口，用于减少 Claude Code 对多条 Bash 命令的权限询问。
  内部仍按顺序调用 scripts/ops 下的低自由度脚本。
  正式执行时请使用绝对路径调用本脚本，不要使用 cd 后再调用相对路径。
USAGE
}

confirm_or_exit() {
  local message="$1"
  if [[ "$ASSUME_YES" == "1" ]]; then
    return 0
  fi
  printf '%s [输入 yes 继续]: ' "$message" >&2
  read -r answer
  case "$answer" in
    yes|YES|y|Y|是|确认) return 0 ;;
    *) echo "用户未确认，停止执行。" >&2; exit 1 ;;
  esac
}

tag_prefix_from_image() {
  local image="$1"
  local base
  base="${image##*:}"
  base="${base##*/}"
  base="$(printf '%s' "$base" | tr -cd 'A-Za-z0-9')"
  printf '%s\n' "${base:0:4}"
}

inspect_image_prefix() {
  local image_id
  image_id="$(ssh "$NODE" "docker image inspect $(printf '%q' "$IMAGE") --format '{{.Id}}'" 2>/dev/null | head -1 || true)"
  image_id="${image_id#sha256:}"
  image_id="$(printf '%s' "$image_id" | tr -cd 'A-Za-z0-9')"
  if [[ ${#image_id} -ge 4 ]]; then
    printf '%s\n' "${image_id:0:4}"
    return 0
  fi
  if [[ "$ALLOW_IMAGE_PREFIX_FALLBACK" == "1" ]]; then
    echo "警告: 无法通过 docker image inspect 解析 Image ID，退回使用镜像 tag 前 4 位。" >&2
    tag_prefix_from_image "$IMAGE"
    return 0
  fi
  echo "无法通过 docker image inspect 解析镜像 ID，请确认镜像存在或显式传入 --image-prefix。" >&2
  return 1
}

extract_value() {
  local key="$1"
  local file="$2"
  grep -E "^${key}=" "$file" | tail -1 | cut -d= -f2-
}

run_step_capture() {
  local name="$1"
  local outfile="$2"
  shift 2
  echo "== ${name} =="
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY_RUN_STEP:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@" 2>&1 | tee "$outfile"
}

NODE=""
IMAGE=""
MODEL_NAME=""
MODEL_SHORT=""
HOST_MODEL_PATH=""
CONTAINER_MODEL_PATH=""
SERVER_SCRIPT=""
PORT=""
TP=""
GPU_RANGE=""
TEST_MODE="custom"
MODE="single"
INPUT_LENS=""
OUTPUT_LEN=""
CONCURRENCIES=""
NUM_PROMPTS_MULT=""
PERCENTILES=""
REQUEST_RATE=""
DATE_PART="$(date +%m%d)"
IMAGE_PREFIX=""
CONTAINER=""
RUN_ID=""
TIMEOUT=1800
TIMEOUT_SET=0
INTERVAL=60
ASSUME_YES=0
DRY_RUN=0
ALLOW_IMAGE_PREFIX_FALLBACK=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OPS_VERSION="unknown"
if [[ -f "$SCRIPT_DIR/version.sh" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/version.sh"
fi
SKILL_CONTAINER_ROOT="${SKILL_CONTAINER_ROOT:-/mnt/.claude/skills/vllm-perf-validation-single}"
OUTPUT_CONTAINER_ROOT="${OUTPUT_CONTAINER_ROOT:-/mnt/skilltest/vllm-perf-validation-single}"
OUTPUT_HOST_ROOT="${OUTPUT_HOST_ROOT:-/public/home/liuzhh8/skilltest/vllm-perf-validation-single}"
REPORT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --model-name) MODEL_NAME="$2"; shift 2 ;;
    --model-short) MODEL_SHORT="$2"; shift 2 ;;
    --host-model-path) HOST_MODEL_PATH="$2"; shift 2 ;;
    --container-model-path) CONTAINER_MODEL_PATH="$2"; shift 2 ;;
    --server-script) SERVER_SCRIPT="$2"; shift 2 ;;
    --service-script) SERVER_SCRIPT="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --tp) TP="$2"; shift 2 ;;
    --TP) TP="$2"; shift 2 ;;
    --gpu-range) GPU_RANGE="$2"; shift 2 ;;
    --test-mode) TEST_MODE="$2"; shift 2 ;;
    --input-lens) INPUT_LENS="$2"; shift 2 ;;
    --output-len) OUTPUT_LEN="$2"; shift 2 ;;
    --concurrencies) CONCURRENCIES="$2"; shift 2 ;;
    --num-prompts-mult) NUM_PROMPTS_MULT="$2"; shift 2 ;;
    --percentiles) PERCENTILES="$2"; shift 2 ;;
    --request-rate) REQUEST_RATE="$2"; shift 2 ;;
    --date) DATE_PART="$2"; shift 2 ;;
    --image-prefix) IMAGE_PREFIX="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; TIMEOUT_SET=1; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --report-dir) REPORT_DIR="$2"; shift 2 ;;
    --assume-yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --allow-image-prefix-fallback) ALLOW_IMAGE_PREFIX_FALLBACK=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

for var in NODE IMAGE MODEL_NAME MODEL_SHORT HOST_MODEL_PATH CONTAINER_MODEL_PATH SERVER_SCRIPT PORT TP GPU_RANGE TEST_MODE; do
  [[ -n "${!var}" ]] || { echo "缺少参数: ${var}" >&2; exit 2; }
done

if [[ "$TEST_MODE" != "custom" ]]; then
  echo "run_single_task.sh 当前只封装 custom 单模型流程；其他模式继续使用 run_bench.sh。" >&2
  exit 2
fi

for var in INPUT_LENS OUTPUT_LEN CONCURRENCIES NUM_PROMPTS_MULT PERCENTILES; do
  [[ -n "${!var}" ]] || { echo "custom 模式缺少参数: ${var}" >&2; exit 2; }
done

if [[ "$MODE" != "single" ]]; then
  echo "run_single_task.sh only supports --mode single; got: $MODE" >&2
  exit 2
fi

if [[ "$TIMEOUT_SET" == "0" ]]; then
  if [[ "$MODEL_SHORT" == glm5* && "$MODEL_SHORT" != glm51* ]]; then
    TIMEOUT=3600
  elif [[ "$MODEL_SHORT" == glm51* ]]; then
    TIMEOUT=2400
  fi
fi

if [[ -z "$IMAGE_PREFIX" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN 模式不会连接节点解析 Image ID；请传入 --image-prefix 以验证最终容器名。" >&2
    IMAGE_PREFIX="AUTO"
  else
    IMAGE_PREFIX="$(inspect_image_prefix)"
  fi
fi
if [[ -z "$CONTAINER" ]]; then
  CONTAINER="lzh-agent-test-${DATE_PART}-${MODEL_SHORT}-${IMAGE_PREFIX}"
fi
if [[ -z "$RUN_ID" ]]; then
  RUN_ID="${MODEL_SHORT}-${TEST_MODE}-$(date +%Y%m%d)-${CONTAINER}"
fi
if [[ -z "$REPORT_DIR" ]]; then
  REPORT_DIR="${OUTPUT_HOST_ROOT}/reports"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "TASK_RUN_ID=$RUN_ID"
echo "CONTAINER_NAME=$CONTAINER"
echo "IMAGE_PREFIX=$IMAGE_PREFIX"
echo "OPS_VERSION=$OPS_VERSION"
echo "ENTRYPOINT=$0"
echo "REPORT_DIR=$REPORT_DIR"
echo "READY_TIMEOUT=$TIMEOUT"

if [[ "$DRY_RUN" == "1" ]]; then
  cat <<EOF
--dry-run 模式：仅打印 single custom 主流程，不执行真实 SSH/Docker/GPU 操作。

执行顺序:
  1. preflight_node.sh
  2. create_container.sh
  3. start_vllm_service.sh
  4. wait_vllm_ready.sh
  5. run_bench.sh
  6. render_report.py
  7. stop_service.sh
  8. render_report.py
  9. show_state.sh

关键参数:
  NODE=$NODE
  IMAGE=$IMAGE
  CONTAINER=$CONTAINER
  MODEL_NAME=$MODEL_NAME
  MODEL_SHORT=$MODEL_SHORT
  HOST_MODEL_PATH=$HOST_MODEL_PATH
  CONTAINER_MODEL_PATH=$CONTAINER_MODEL_PATH
  SERVER_SCRIPT=$SERVER_SCRIPT
  PORT=$PORT
  TP=$TP
  GPU_RANGE=$GPU_RANGE
  INPUT_LENS=$INPUT_LENS
  OUTPUT_LEN=$OUTPUT_LEN
  CONCURRENCIES=$CONCURRENCIES
  NUM_PROMPTS_MULT=$NUM_PROMPTS_MULT
  PERCENTILES=$PERCENTILES
  TIMEOUT=$TIMEOUT
  REPORT_DIR=$REPORT_DIR

本脚本真实执行时会从 start_vllm_service.sh 输出中读取 WORK_DIR/STATE/LOG，
从 wait_vllm_ready.sh 输出中读取 SERVED_MODEL_ID，
从 run_bench.sh 输出中读取 CSV_HOST，并在 stop 前后各生成一次报告。
EOF
  exit 0
fi

run_step_capture "preflight" "$TMP_DIR/preflight.out" \
  bash "$SCRIPT_DIR/preflight_node.sh" \
    --node "$NODE" \
    --image "$IMAGE" \
    --ports "$PORT" \
    --host-model-paths "$HOST_MODEL_PATH" \
    --container-names "$CONTAINER"

confirm_or_exit "即将创建容器、占用 GPU/端口并执行 single custom 测试。"

run_step_capture "create_container" "$TMP_DIR/create.out" \
  env IMAGE_PREFIX_FALLBACK="$ALLOW_IMAGE_PREFIX_FALLBACK" bash "$SCRIPT_DIR/create_container.sh" \
    --node "$NODE" \
    --image "$IMAGE" \
    --model-short "$MODEL_SHORT" \
    --date "$DATE_PART" \
    --image-prefix "$IMAGE_PREFIX" \
    --name "$CONTAINER"

run_step_capture "start_vllm_service" "$TMP_DIR/start.out" \
  env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" \
    OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" \
    OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" \
    bash "$SCRIPT_DIR/start_vllm_service.sh" \
      --node "$NODE" \
      --container "$CONTAINER" \
      --model-name "$MODEL_NAME" \
      --model-short "$MODEL_SHORT" \
      --container-model-path "$CONTAINER_MODEL_PATH" \
      --host-model-path "$HOST_MODEL_PATH" \
      --server-script "$SERVER_SCRIPT" \
      --image "$IMAGE" \
      --test-mode "$TEST_MODE" \
      --port "$PORT" \
      --tp "$TP" \
      --gpu-range "$GPU_RANGE"

WORK_DIR_CONTAINER="$(extract_value WORK_DIR_CONTAINER "$TMP_DIR/start.out")"
WORK_DIR_HOST="$(extract_value WORK_DIR_HOST "$TMP_DIR/start.out")"
LOG_CONTAINER="$(extract_value LOG_CONTAINER "$TMP_DIR/start.out")"
STATE_CONTAINER="$(extract_value STATE_CONTAINER "$TMP_DIR/start.out")"
STATE_HOST="$(extract_value STATE_HOST "$TMP_DIR/start.out")"

for var in WORK_DIR_CONTAINER WORK_DIR_HOST LOG_CONTAINER STATE_CONTAINER STATE_HOST; do
  [[ -n "${!var}" ]] || { echo "start_vllm_service 未输出必要字段: ${var}" >&2; exit 1; }
done

python3 "$SCRIPT_DIR/update_state.py" --state "$STATE_HOST" \
  --set "ops.version=$OPS_VERSION" \
  --set "ops.entrypoint=$0" \
  --set "ops.script_dir=$SCRIPT_DIR" \
  --set "timing.readiness_timeout_seconds=$TIMEOUT" \
  --set "test.mode=$TEST_MODE" \
  --set "test.params.input_lens=$INPUT_LENS" \
  --set "test.params.output_len=$OUTPUT_LEN" \
  --set "test.params.concurrencies=$CONCURRENCIES" \
  --set "test.params.num_prompts_mult=$NUM_PROMPTS_MULT" \
  --set "test.params.percentiles=$PERCENTILES" \
  --set "test.params.request_rate=$REQUEST_RATE" || true

run_step_capture "wait_vllm_ready" "$TMP_DIR/wait.out" \
  env VERBOSE=1 SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" \
    bash "$SCRIPT_DIR/wait_vllm_ready.sh" \
      --node "$NODE" \
      --container "$CONTAINER" \
      --port "$PORT" \
      --log "$LOG_CONTAINER" \
      --model-path "$CONTAINER_MODEL_PATH" \
      --state "$STATE_CONTAINER" \
      --timeout "$TIMEOUT" \
      --interval "$INTERVAL"

SERVED_MODEL_ID="$(extract_value SERVED_MODEL_ID "$TMP_DIR/wait.out")"
[[ -n "$SERVED_MODEL_ID" ]] || { echo "wait_vllm_ready 未输出 SERVED_MODEL_ID" >&2; exit 1; }

run_step_capture "run_bench" "$TMP_DIR/bench.out" \
  env SKILL_CONTAINER_ROOT="$SKILL_CONTAINER_ROOT" \
    OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" \
    OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" \
    IMAGE_NAME="$IMAGE" \
    INPUT_LENS="$INPUT_LENS" \
    OUTPUT_LEN="$OUTPUT_LEN" \
    CONCURRENCIES="$CONCURRENCIES" \
    NUM_PROMPTS_MULT="$NUM_PROMPTS_MULT" \
    PERCENTILES="$PERCENTILES" \
    REQUEST_RATE="$REQUEST_RATE" \
    bash "$SCRIPT_DIR/run_bench.sh" \
      --node "$NODE" \
      --container "$CONTAINER" \
      --test-mode "$TEST_MODE" \
      --served-model-id "$SERVED_MODEL_ID" \
      --port "$PORT" \
      --tp "$TP" \
      --work-dir "$WORK_DIR_CONTAINER" \
      --state "$STATE_CONTAINER"

CSV_HOST="$(extract_value CSV_HOST "$TMP_DIR/bench.out")"
[[ -n "$CSV_HOST" ]] || CSV_HOST="${WORK_DIR_HOST}/csvs/${TEST_MODE}/all.csv"

echo "== render_report_before_stop =="
if [[ "$DRY_RUN" == "1" ]]; then
  printf 'DRY_RUN_STEP: python3 %q --run-id %q --state %q --csv %q --report-dir %q\n' \
    "$SCRIPT_DIR/render_report.py" "$RUN_ID" "$STATE_HOST" "$CSV_HOST" "$REPORT_DIR"
else
  REPORT_BEFORE_RC=0
  set +e
  python3 "$SCRIPT_DIR/render_report.py" \
    --run-id "$RUN_ID" \
    --state "$STATE_HOST" \
    --csv "$CSV_HOST" \
    --report-dir "$REPORT_DIR" | tee "$TMP_DIR/report_before_stop.out"
  REPORT_BEFORE_RC=${PIPESTATUS[0]}
  set -e
  if [[ "$REPORT_BEFORE_RC" != "0" ]]; then
    echo "警告: 停止前报告生成失败，继续停止容器以释放资源。" >&2
  fi
fi

echo "== stop_service =="
STOP_RC=0
if [[ "$DRY_RUN" == "1" ]]; then
  printf 'DRY_RUN_STEP: bash %q --node %q --container %q --port %q --state %q\n' \
    "$SCRIPT_DIR/stop_service.sh" "$NODE" "$CONTAINER" "$PORT" "$STATE_HOST"
else
  set +e
  SKILL_HOST_ROOT="$SKILL_ROOT" \
    OUTPUT_CONTAINER_ROOT="$OUTPUT_CONTAINER_ROOT" \
    OUTPUT_HOST_ROOT="$OUTPUT_HOST_ROOT" \
    bash "$SCRIPT_DIR/stop_service.sh" \
      --node "$NODE" \
      --container "$CONTAINER" \
      --port "$PORT" \
      --state "$STATE_HOST" 2>&1 | tee "$TMP_DIR/stop.out"
  STOP_RC=${PIPESTATUS[0]}
  set -e
fi

if [[ "$STOP_RC" != "0" && "$DRY_RUN" != "1" ]]; then
  python3 "$SCRIPT_DIR/update_state.py" --state "$STATE_HOST" \
    --set "status=STOP_FAILED" \
    --set "failure.reason=stop_service_failed" \
    --set "failure.exit_code=$STOP_RC" || true
  echo "STOP_FAILED: stop_service.sh 返回 $STOP_RC；未执行手写 docker/ssh 回退。" >&2
  echo "可用 ops 恢复入口:" >&2
  echo "bash $SCRIPT_DIR/recover_single_task.sh --state $STATE_HOST --node $NODE --container $CONTAINER --port $PORT --report-dir $REPORT_DIR" >&2
fi

echo "== render_report_final =="
if [[ "$DRY_RUN" == "1" ]]; then
  printf 'DRY_RUN_STEP: python3 %q --run-id %q --state %q --csv %q --report-dir %q\n' \
    "$SCRIPT_DIR/render_report.py" "$RUN_ID" "$STATE_HOST" "$CSV_HOST" "$REPORT_DIR"
else
  REPORT_FINAL_RC=0
  set +e
  python3 "$SCRIPT_DIR/render_report.py" \
    --run-id "$RUN_ID" \
    --state "$STATE_HOST" \
    --csv "$CSV_HOST" \
    --report-dir "$REPORT_DIR" | tee "$TMP_DIR/report_final.out"
  REPORT_FINAL_RC=${PIPESTATUS[0]}
  set -e
  if [[ "$REPORT_FINAL_RC" != "0" ]]; then
    echo "警告: 最终报告生成失败，请检查 state/CSV 路径；主流程不会因此覆盖 benchmark/stop 结果。" >&2
  fi
fi

echo "== show_state =="
if [[ "$DRY_RUN" == "1" ]]; then
  printf 'DRY_RUN_STEP: bash %q --state %q\n' "$SCRIPT_DIR/show_state.sh" "$STATE_HOST"
else
  bash "$SCRIPT_DIR/show_state.sh" --state "$STATE_HOST" || true
fi

if [[ "$STOP_RC" != "0" ]]; then
  exit "$STOP_RC"
fi
