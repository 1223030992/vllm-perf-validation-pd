#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  preflight_pd_node.sh --prefill-node NODE --decode-node NODE --proxy-node NODE \
    --image IMAGE --prefill-port PORT --decode-port PORT --proxy-port PORT \
    --host-model-path PATH --network-ifname IFNAME --nccl-ib-hca HCA \
    --skill-host-root PATH --mooncake-proxy-script PATH [--dry-run]
USAGE
}

PREFILL_NODE=""; DECODE_NODE=""; PROXY_NODE=""; IMAGE=""
PREFILL_PORT=""; DECODE_PORT=""; PROXY_PORT=""; HOST_MODEL_PATH=""
NETWORK_IFNAME=""; NCCL_IB_HCA=""; SKILL_HOST_ROOT=""; MOONCAKE_PROXY_SCRIPT=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefill-node) PREFILL_NODE="$2"; shift 2 ;;
    --decode-node) DECODE_NODE="$2"; shift 2 ;;
    --proxy-node) PROXY_NODE="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --prefill-port) PREFILL_PORT="$2"; shift 2 ;;
    --decode-port) DECODE_PORT="$2"; shift 2 ;;
    --proxy-port) PROXY_PORT="$2"; shift 2 ;;
    --host-model-path) HOST_MODEL_PATH="$2"; shift 2 ;;
    --network-ifname) NETWORK_IFNAME="$2"; shift 2 ;;
    --nccl-ib-hca) NCCL_IB_HCA="$2"; shift 2 ;;
    --skill-host-root) SKILL_HOST_ROOT="$2"; shift 2 ;;
    --mooncake-proxy-script) MOONCAKE_PROXY_SCRIPT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
for var in PREFILL_NODE DECODE_NODE PROXY_NODE IMAGE PREFILL_PORT DECODE_PORT PROXY_PORT HOST_MODEL_PATH NETWORK_IFNAME SKILL_HOST_ROOT MOONCAKE_PROXY_SCRIPT; do
  [[ -n "${!var}" ]] || { echo "missing argument: $var" >&2; exit 2; }
done

quote_sh() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
run_ssh() {
  local node="$1" label="$2" cmd="$3"
  echo "== ${node}: ${label} =="
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'ssh %q %q\n' "$node" "$cmd"
  else
    ssh "$node" "$cmd"
  fi
}
check_node() {
  local node="$1"
  run_ssh "$node" node_info "hostname && uname -a"
  run_ssh "$node" docker_image "docker image inspect $(quote_sh "$IMAGE") --format '{{.RepoTags}}' 2>/dev/null || echo 'WARN: image not found locally'"
  run_ssh "$node" model_path "test -d $(quote_sh "$HOST_MODEL_PATH") && echo 'model path exists' || echo 'WARN: model path not found'"
  run_ssh "$node" network_ifname "(ip link show $(quote_sh "$NETWORK_IFNAME") || ifconfig $(quote_sh "$NETWORK_IFNAME")) >/dev/null 2>&1 && echo 'network interface exists' || (echo 'NETWORK_IFNAME_NOT_FOUND: $NETWORK_IFNAME' >&2; exit 1)"
  if [[ -n "$NCCL_IB_HCA" ]]; then
    run_ssh "$node" infiniband_hca "echo configured NCCL_IB_HCA=$(quote_sh "$NCCL_IB_HCA"); ls /sys/class/infiniband 2>/dev/null || true"
  fi
}
check_port() {
  run_ssh "$1" "port_$2" "ss -tlnp 2>/dev/null | grep ':$2 ' || echo 'port $2 is free'"
}
check_node "$PREFILL_NODE"
[[ "$DECODE_NODE" == "$PREFILL_NODE" ]] || check_node "$DECODE_NODE"
check_port "$PREFILL_NODE" "$PREFILL_PORT"
check_port "$DECODE_NODE" "$DECODE_PORT"
check_port "$PROXY_NODE" "$PROXY_PORT"
run_ssh "$PROXY_NODE" mooncake_proxy_script "test -f $(quote_sh "${SKILL_HOST_ROOT%/}/${MOONCAKE_PROXY_SCRIPT#./}") && echo 'mooncake proxy script exists' || echo 'WARN: mooncake proxy script not found; add mooncake examples before real run'"
