#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
用法:
  stop_service.sh --node NODE --container NAME --port PORT [--state STATE]

选项:
  --dry-run

说明:
  本脚本只执行 docker stop 并验证端口释放，永远不会执行 docker rm。
  如果传入的 state 是容器路径 /mnt/skilltest/...，脚本会自动转换为宿主机路径
  /public/home/liuzhh8/skilltest/... 后再更新 state.json。
USAGE
}

quote_sh() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

run_in_container() {
  local script="$1"
  local docker_cmd
  docker_cmd="docker exec -i $(quote_sh "$CONTAINER") bash -ic 'tmp=/tmp/vllm_ops_stop_\$\$.sh; cat > \"\$tmp\"; bash \"\$tmp\"; rc=\$?; rm -f \"\$tmp\"; exit \$rc'"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "即将在容器内归还运行产物权限:"
    printf 'ssh %q %q\n' "$NODE" "$docker_cmd"
    echo "--- container script ---"
    printf '%s\n' "$script"
    return 0
  fi
  printf '%s\n' "$script" | ssh "$NODE" "$docker_cmd"
}

NODE=""
CONTAINER=""
PORT=""
STATE=""
SKILL_HOST_ROOT="${SKILL_HOST_ROOT:-/public/home/liuzhh8/.claude/skills/vllm-perf-validation-single}"
OUTPUT_CONTAINER_ROOT="${OUTPUT_CONTAINER_ROOT:-/mnt/skilltest/vllm-perf-validation-single}"
OUTPUT_HOST_ROOT="${OUTPUT_HOST_ROOT:-/public/home/liuzhh8/skilltest/vllm-perf-validation-single}"
DRY_RUN="${DRY_RUN:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$NODE" ]] || { echo "缺少参数: --node" >&2; exit 2; }
[[ -n "$CONTAINER" ]] || { echo "缺少参数: --container" >&2; exit 2; }
[[ -n "$PORT" ]] || { echo "缺少参数: --port" >&2; exit 2; }

state_host_path() {
  local state="$1"
  if [[ "$state" == "$OUTPUT_CONTAINER_ROOT"* ]]; then
    printf '%s%s\n' "$OUTPUT_HOST_ROOT" "${state#$OUTPUT_CONTAINER_ROOT}"
  else
    printf '%s\n' "$state"
  fi
}

state_container_path() {
  local state="$1"
  if [[ "$state" == "$OUTPUT_HOST_ROOT"* ]]; then
    printf '%s%s\n' "$OUTPUT_CONTAINER_ROOT" "${state#$OUTPUT_HOST_ROOT}"
  else
    printf '%s\n' "$state"
  fi
}

update_state_local() {
  if [[ -z "$STATE_HOST" ]]; then
    return 0
  fi
  if python3 "$SKILL_HOST_ROOT/scripts/ops/update_state.py" --state "$STATE_HOST" "$@"; then
    return 0
  fi
  echo "警告: state.json 更新失败，但不立即中断 stop 流程: $STATE_HOST" >&2
  return 1
}

restore_permissions_remote() {
  if [[ -z "$STATE_CONTAINER" ]]; then
    return 0
  fi
  WORK_DIR_CONTAINER="$(dirname "$STATE_CONTAINER")"
  local script
  script=$(cat <<EOF
set -euo pipefail
WORK_DIR=$(quote_sh "$WORK_DIR_CONTAINER")
if [[ -d "\$WORK_DIR" ]]; then
  HOST_OWNER=\$(stat -c '%u:%g' /mnt 2>/dev/null || true)
  if [[ -n "\$HOST_OWNER" ]]; then
    chown -R "\$HOST_OWNER" "\$WORK_DIR" 2>/dev/null || true
  fi
  chmod -R u+rwX,go+rX "\$WORK_DIR" 2>/dev/null || true
fi
EOF
)
  run_in_container "$script" || {
    echo "警告: 容器内产物权限归还失败，继续尝试停止容器。" >&2
    return 1
  }
}

STATE_HOST=""
STATE_CONTAINER=""
if [[ -n "$STATE" ]]; then
  STATE_HOST="$(state_host_path "$STATE")"
  STATE_CONTAINER="$(state_container_path "$STATE")"
fi

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  restore_permissions_remote || true
  if [[ -n "$STATE_HOST" ]]; then
    printf 'python3 %q --state %q --set status=STOPPING\n' "$SKILL_HOST_ROOT/scripts/ops/update_state.py" "$STATE_HOST"
  fi
  printf 'ssh %q %q\n' "$NODE" "docker stop $(quote_sh "$CONTAINER")"
  printf 'ssh %q %q\n' "$NODE" "ss -tlnp | grep ':$PORT ' || echo '端口 $PORT 已释放'"
  if [[ -n "$STATE_HOST" ]]; then
    printf 'python3 %q --state %q --set status=STOPPED --set service.port_released=true --set timing.stop_epoch=<epoch>\n' "$SKILL_HOST_ROOT/scripts/ops/update_state.py" "$STATE_HOST"
  fi
  exit 0
fi

restore_permissions_remote || true
update_state_local --set "status=STOPPING" || true

if ! ssh "$NODE" "docker stop $(quote_sh "$CONTAINER")"; then
  update_state_local --set "status=STOP_FAILED" --set "failure.reason=docker_stop_failed" || true
  echo "docker stop 执行失败: $CONTAINER" >&2
  exit 1
fi
sleep 5

if ssh "$NODE" "ss -tlnp 2>/dev/null | grep ':$PORT '" >/dev/null 2>&1; then
  update_state_local --set "status=STOP_FAILED" --set "failure.reason=port_still_in_use_after_stop" || true
  echo "停止容器后端口仍被占用: $PORT" >&2
  exit 1
fi

STOP_TS="$(date +%s)"
update_state_local \
  --set "status=STOPPED" \
  --set "service.port_released=true" \
  --set "timing.stop_epoch=$STOP_TS" \
  --set "paths.state_file_host=$STATE_HOST" || true

echo "端口 $PORT 已释放"
if [[ -n "$STATE_HOST" ]]; then
  echo "STATE_HOST=$STATE_HOST"
fi
