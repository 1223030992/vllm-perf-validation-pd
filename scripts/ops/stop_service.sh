#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  stop_service.sh --node NODE --container NAME --port PORT [--state STATE] [--dry-run]

Stops the container with docker stop, verifies the service port is released, and
updates state.json when --state is provided. This script never runs docker rm.
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
    echo "DRY_RUN: restore artifact permissions in container:"
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/runtime_config.sh"
SKILL_USER=""
USER_ABBR=""
HOME_ROOT=""
HOST_HOME_ROOT=""
SKILL_HOST_ROOT="${SKILL_HOST_ROOT:-}"
OUTPUT_HOST_ROOT="${OUTPUT_HOST_ROOT:-}"
OUTPUT_CONTAINER_ROOT="${OUTPUT_CONTAINER_ROOT:-}"
CONTAINER_PREFIX=""
DRY_RUN="${DRY_RUN:-0}"

while [[ $# -gt 0 ]]; do
  if runtime_config_parse_common_arg "$1" "${2-}"; then
    shift 2
    continue
  fi
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$NODE" ]] || { echo "missing argument: --node" >&2; exit 2; }
[[ -n "$CONTAINER" ]] || { echo "missing argument: --container" >&2; exit 2; }
[[ -n "$PORT" ]] || { echo "missing argument: --port" >&2; exit 2; }
resolve_runtime_config

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
  echo "WARN: failed to update state.json, continuing stop flow: $STATE_HOST" >&2
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
    echo "WARN: failed to restore artifact permissions; continuing container stop." >&2
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
  printf 'ssh %q %q\n' "$NODE" "ss -tlnp 2>/dev/null | grep ':$PORT ' || echo 'port $PORT released'"
  if [[ -n "$STATE_HOST" ]]; then
    printf 'python3 %q --state %q --set status=STOPPED --set service.port_released=true --set timing.stop_epoch=<epoch>\n' "$SKILL_HOST_ROOT/scripts/ops/update_state.py" "$STATE_HOST"
  fi
  exit 0
fi

restore_permissions_remote || true
update_state_local --set "status=STOPPING" || true

if ! ssh "$NODE" "docker stop $(quote_sh "$CONTAINER")"; then
  update_state_local --set "status=STOP_FAILED" --set "failure.reason=docker_stop_failed" || true
  echo "docker stop failed: $CONTAINER" >&2
  exit 1
fi
sleep 5

if ssh "$NODE" "ss -tlnp 2>/dev/null | grep ':$PORT '" >/dev/null 2>&1; then
  update_state_local --set "status=STOP_FAILED" --set "failure.reason=port_still_in_use_after_stop" || true
  echo "port still in use after stop: $PORT" >&2
  exit 1
fi

STOP_TS="$(date +%s)"
update_state_local \
  --set "status=STOPPED" \
  --set "service.port_released=true" \
  --set "timing.stop_epoch=$STOP_TS" \
  --set "paths.state_file_host=$STATE_HOST" || true

echo "port $PORT released"
if [[ -n "$STATE_HOST" ]]; then
  echo "STATE_HOST=$STATE_HOST"
fi
