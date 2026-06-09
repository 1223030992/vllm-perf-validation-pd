#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ensure_workspace.sh --node NODE --user USER [--abbr ABBR] [options]

Options:
  --home-root PATH
  --host-home-root PATH
  --skill-host-root PATH
  --output-host-root PATH
  --output-container-root PATH
  --container-prefix PREFIX
  --assume-yes
  --dry-run

Checks and creates the host output workspace:
  <OUTPUT_HOST_ROOT>/{work_dirs,reports,logs,csvs,tmp}
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/runtime_config.sh"

quote_sh() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

NODE=""
SKILL_USER=""
USER_ABBR=""
HOME_ROOT=""
HOST_HOME_ROOT=""
SKILL_HOST_ROOT=""
OUTPUT_HOST_ROOT=""
OUTPUT_CONTAINER_ROOT="${OUTPUT_CONTAINER_ROOT:-}"
CONTAINER_PREFIX=""
ASSUME_YES=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  if runtime_config_parse_common_arg "$1" "${2-}"; then
    shift 2
    continue
  fi
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --assume-yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$NODE" ]] || { echo "missing --node" >&2; exit 2; }
resolve_runtime_config

remote_check="test -d $(quote_sh "$OUTPUT_HOST_ROOT")"
remote_create="mkdir -p $(quote_sh "$OUTPUT_HOST_ROOT/work_dirs") $(quote_sh "$OUTPUT_HOST_ROOT/reports") $(quote_sh "$OUTPUT_HOST_ROOT/logs") $(quote_sh "$OUTPUT_HOST_ROOT/csvs") $(quote_sh "$OUTPUT_HOST_ROOT/tmp")"

echo "== workspace =="
print_runtime_config

if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY_RUN=1, no workspace will be created."
  printf 'ssh %q %q\n' "$NODE" "$remote_check"
  printf 'ssh %q %q\n' "$NODE" "$remote_create"
  exit 0
fi

if ssh "$NODE" "$remote_check" >/dev/null 2>&1; then
  echo "WORKSPACE_EXISTS=1"
  echo "WORKSPACE_CREATED=0"
  echo "OUTPUT_HOST_ROOT=$OUTPUT_HOST_ROOT"
  exit 0
fi

echo "WORKSPACE_EXISTS=0"
if [[ "$ASSUME_YES" != "1" ]]; then
  printf 'Workspace does not exist: %s. Create it? [type yes to continue]: ' "$OUTPUT_HOST_ROOT" >&2
  read -r answer
  case "$answer" in
    yes|YES|y|Y) ;;
    *) echo "User did not confirm workspace creation; stop." >&2; exit 1 ;;
  esac
fi

ssh "$NODE" "$remote_create"
echo "WORKSPACE_CREATED=1"
echo "OUTPUT_HOST_ROOT=$OUTPUT_HOST_ROOT"
