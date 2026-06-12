#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  prepare_pd_runtime.sh --role prefill|decode --node NODE --container NAME \
    --work-dir PATH --state PATH [--mooncake-wheel URL_OR_CONTAINER_PATH] \
    [--dry-run]
USAGE
}

quote_sh() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

ROLE=""; NODE=""; CONTAINER=""; WORK_DIR=""; STATE=""; MOONCAKE_WHEEL=""; DRY_RUN=0
SKILL_CONTAINER_ROOT="${SKILL_CONTAINER_ROOT:-/mnt/.claude/skills/vllm-perf-validation-pd}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --node) NODE="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --work-dir) WORK_DIR="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --mooncake-wheel) MOONCAKE_WHEEL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "unknown_arg=$1" >&2; usage; exit 2 ;;
  esac
done

for var in ROLE NODE CONTAINER WORK_DIR STATE; do
  [[ -n "${!var}" ]] || { echo "missing_arg=$var" >&2; exit 2; }
done
[[ "$ROLE" == "prefill" || "$ROLE" == "decode" ]] || { echo "invalid_role=$ROLE" >&2; exit 2; }

LOG="${WORK_DIR}/logs/mooncake-runtime-${ROLE}.log"
if [[ -n "$MOONCAKE_WHEEL" ]]; then
  INSTALL_BLOCK=$(cat <<'EOF'
echo "MOONCAKE_INSTALL role=$ROLE source=$WHEEL" | tee -a "$LOG"
if ! python3 -m pip install --no-cache-dir "$WHEEL" >>"$LOG" 2>&1; then
  python3 "$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "$STATE" \
    --set "status=RUNTIME_FAILED" --set "pd.runtime.$ROLE.status=FAILED" \
    --set "failure.reason=mooncake_install_failed" --set "failure.detail=$ROLE" \
    --set "pd.runtime.$ROLE.log_tail=$(tail -40 "$LOG" | head -c 4000)"
  echo "mooncake_install_failed role=$ROLE log=$LOG" >&2
  tail -40 "$LOG" >&2 || true
  exit 1
fi
EOF
)
else
  INSTALL_BLOCK='echo "MOONCAKE_INSTALL_SKIPPED role=$ROLE" | tee -a "$LOG"'
fi
remote_script=$(cat <<EOF
set -euo pipefail
ROLE=$(quote_sh "$ROLE"); STATE=$(quote_sh "$STATE"); LOG=$(quote_sh "$LOG")
WHEEL=$(quote_sh "$MOONCAKE_WHEEL"); SKILL_CONTAINER_ROOT=$(quote_sh "$SKILL_CONTAINER_ROOT")
mkdir -p "\$(dirname "\$LOG")"
: > "\$LOG"

verify_mooncake() {
  python3 - <<'PY'
import importlib.metadata
import mooncake.engine

version = "unknown"
for name in ("mooncake-transfer-engine", "mooncake_transfer_engine"):
    try:
        version = importlib.metadata.version(name)
        break
    except importlib.metadata.PackageNotFoundError:
        pass
print(version)
PY
}

python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" \
  --set "pd.runtime.\$ROLE.status=PREPARING" --set "pd.runtime.\$ROLE.log_file=\$LOG"

$INSTALL_BLOCK

if ! VERSION=\$(verify_mooncake 2>>"\$LOG"); then
  python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" \
    --set "status=RUNTIME_FAILED" --set "pd.runtime.\$ROLE.status=FAILED" \
    --set "failure.reason=mooncake_transfer_engine_missing" --set "failure.detail=\$ROLE" \
    --set "pd.runtime.\$ROLE.log_tail=\$(tail -40 "\$LOG" | head -c 4000)"
  echo "mooncake_transfer_engine_missing role=\$ROLE log=\$LOG" >&2
  tail -40 "\$LOG" >&2 || true
  exit 1
fi

python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" \
  --set "pd.runtime.\$ROLE.status=READY" --set "pd.runtime.\$ROLE.mooncake_version=\$VERSION" \
  --set "pd.runtime.\$ROLE.install_source=\$WHEEL"
echo "MOONCAKE_RUNTIME_READY role=\$ROLE version=\$VERSION"
echo "MOONCAKE_RUNTIME_LOG=\$LOG"
EOF
)

docker_cmd="docker exec -i $(quote_sh "$CONTAINER") bash -lc 'tmp=/tmp/vllm_pd_runtime_\$\$.sh; cat > \"\$tmp\"; bash \"\$tmp\"; rc=\$?; rm -f \"\$tmp\"; exit \$rc'"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY_RUN_RUNTIME_ROLE=$ROLE"
  printf 'ssh %q %q\n' "$NODE" "$docker_cmd"
  echo "--- container script ---"
  printf '%s\n' "$remote_script"
  exit 0
fi
printf '%s\n' "$remote_script" | ssh "$NODE" "$docker_cmd"
