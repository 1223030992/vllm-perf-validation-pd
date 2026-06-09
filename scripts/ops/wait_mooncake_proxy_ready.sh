#!/usr/bin/env bash
set -euo pipefail
quote_sh() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
NODE=""; CONTAINER=""; PORT=""; STATE=""; TIMEOUT=600; INTERVAL=10; DRY_RUN=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/runtime_config.sh"
SKILL_USER=""; USER_ABBR=""; HOME_ROOT=""; HOST_HOME_ROOT=""; SKILL_HOST_ROOT=""; OUTPUT_HOST_ROOT="${OUTPUT_HOST_ROOT:-}"; OUTPUT_CONTAINER_ROOT="${OUTPUT_CONTAINER_ROOT:-}"; CONTAINER_PREFIX=""
while [[ $# -gt 0 ]]; do
  if runtime_config_parse_common_arg "$1" "${2-}"; then shift 2; continue; fi
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
for var in NODE CONTAINER PORT STATE; do [[ -n "${!var}" ]] || { echo "missing argument: $var" >&2; exit 2; }; done
resolve_runtime_config
remote_script=$(cat <<EOF
set -euo pipefail
PORT=$(quote_sh "$PORT"); STATE=$(quote_sh "$STATE"); TIMEOUT=$(quote_sh "$TIMEOUT"); INTERVAL=$(quote_sh "$INTERVAL"); SKILL_CONTAINER_ROOT=$(quote_sh "$SKILL_CONTAINER_ROOT")
START=\$(date +%s)
while true; do
  ELAPSED=\$((\$(date +%s) - START))
  MODELS_JSON=\$(curl -sS -m 10 "http://127.0.0.1:\$PORT/v1/models" 2>/dev/null || true)
  SERVED_MODEL_ID=\$(python3 - "\$MODELS_JSON" <<'PY' 2>/dev/null || true
import json, sys
try:
    rows = json.loads(sys.argv[1]).get("data") or []
    print(rows[0].get("id") if rows else "")
except Exception:
    print("")
PY
)
  if ss -tlnp 2>/dev/null | grep -q ":\$PORT "; then
    python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" --set "pd.proxy.status=READY" --set "pd.proxy.readiness_duration_seconds=\$ELAPSED" --set "pd.proxy.models_json_summary=\$MODELS_JSON" --set "pd.proxy.served_model_id=\$SERVED_MODEL_ID"
    echo "PROXY_READY=1"; echo "PROXY_SERVED_MODEL_ID=\$SERVED_MODEL_ID"; exit 0
  fi
  if (( ELAPSED >= TIMEOUT )); then
    python3 "\$SKILL_CONTAINER_ROOT/scripts/ops/update_state.py" --state "\$STATE" --set "pd.proxy.status=TIMEOUT" --set "failure.reason=proxy_ready_timeout"
    echo "PROXY_READY_TIMEOUT after \$ELAPSED seconds" >&2; exit 1
  fi
  sleep "\$INTERVAL"
done
EOF
)
docker_cmd="docker exec -i $(quote_sh "$CONTAINER") bash -ic 'tmp=/tmp/vllm_pd_wait_proxy_\$\$.sh; cat > \"\$tmp\"; bash \"\$tmp\"; rc=\$?; rm -f \"\$tmp\"; exit \$rc'"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "即将检查 Mooncake proxy readiness:"
  printf 'ssh %q %q\n' "$NODE" "$docker_cmd"
  echo "--- container script ---"
  printf '%s\n' "$remote_script"
else
  printf '%s\n' "$remote_script" | ssh "$NODE" "$docker_cmd"
fi
