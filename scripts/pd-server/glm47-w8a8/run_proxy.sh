#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  run_proxy.sh --proxy-script PATH --prefill-url URL \
    --prefill-transfer-port PORT --decode-url URL --port PORT
USAGE
}

PROXY_SCRIPT=""; PREFILL_URL=""; PREFILL_TRANSFER_PORT=""; DECODE_URL=""; PORT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --proxy-script) PROXY_SCRIPT="$2"; shift 2 ;;
    --prefill-url) PREFILL_URL="$2"; shift 2 ;;
    --prefill-transfer-port) PREFILL_TRANSFER_PORT="$2"; shift 2 ;;
    --decode-url) DECODE_URL="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) echo "unknown_arg=$1" >&2; usage; exit 2 ;;
  esac
done

for var in PROXY_SCRIPT PREFILL_URL PREFILL_TRANSFER_PORT DECODE_URL PORT; do
  [[ -n "${!var}" ]] || { echo "missing_arg=$var" >&2; exit 2; }
done
[[ -f "$PROXY_SCRIPT" ]] || { echo "proxy_script_missing=$PROXY_SCRIPT" >&2; exit 1; }

prefill_host="${PREFILL_URL#*://}"
prefill_host="${prefill_host%%:*}"
decode_host="${DECODE_URL#*://}"
decode_host="${decode_host%%:*}"
export NO_PROXY="127.0.0.1,localhost,${prefill_host},${decode_host}${NO_PROXY:+,${NO_PROXY}}"
export no_proxy="$NO_PROXY"
export PYTHONUNBUFFERED=1

exec python3 -u "$PROXY_SCRIPT" \
  --prefill "$PREFILL_URL" "$PREFILL_TRANSFER_PORT" \
  --decode "$DECODE_URL" \
  --port "$PORT"
