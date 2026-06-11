#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  show_state.sh --state STATE [--node NODE] [--full]

Description:
  Controlled entrypoint for reading a PD task state.json.
  If --node is provided, the state file is read on that remote node.
USAGE
}

quote_sh() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

state_host_path() {
  local state="$1"
  if [[ "$state" == "$OUTPUT_CONTAINER_ROOT"* ]]; then
    printf '%s%s\n' "$OUTPUT_HOST_ROOT" "${state#$OUTPUT_CONTAINER_ROOT}"
  else
    printf '%s\n' "$state"
  fi
}

NODE=""
STATE=""
FULL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/runtime_config.sh"
SKILL_USER=""
USER_ABBR=""
HOME_ROOT=""
HOST_HOME_ROOT=""
SKILL_HOST_ROOT="${SKILL_HOST_ROOT:-}"
OUTPUT_HOST_ROOT="${OUTPUT_HOST_ROOT:-}"
CONTAINER_PREFIX=""

while [[ $# -gt 0 ]]; do
  if runtime_config_parse_common_arg "$1" "${2-}"; then
    shift 2
    continue
  fi
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --full) FULL=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "unknown_arg=$1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$STATE" ]] || { echo "missing_arg=--state" >&2; exit 2; }
resolve_runtime_config
STATE_HOST="$(state_host_path "$STATE")"

FULL_ARG=""
if [[ "$FULL" == "1" ]]; then
  FULL_ARG=" --full"
fi

if [[ -n "$NODE" ]]; then
  ssh "$NODE" "python3 $(quote_sh "$SKILL_HOST_ROOT/scripts/ops/show_state.py") --state $(quote_sh "$STATE_HOST")$FULL_ARG"
else
  python3 "$SCRIPT_DIR/show_state.py" --state "$STATE_HOST" ${FULL_ARG}
fi
