#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  preflight_pd_node.sh --prefill-node NODE --decode-node NODE --proxy-node NODE \
    --image IMAGE [--image-id IMAGE_ID] \
    --prefill-port PORT --decode-port PORT --proxy-port PORT \
    --host-model-path PATH [--network-ifname IFNAME] [--nccl-ib-hca HCA] \
    --skill-host-root PATH --prefill-server-script PATH \
    --decode-server-script PATH --proxy-launcher-script PATH \
    --mooncake-proxy-script PATH [--dry-run]
USAGE
}

PREFILL_NODE=""; DECODE_NODE=""; PROXY_NODE=""; IMAGE=""; EXPECTED_IMAGE_ID=""; PREFILL_PORT=""
DECODE_PORT=""; PROXY_PORT=""; HOST_MODEL_PATH=""; NETWORK_IFNAME=""; NCCL_IB_HCA=""
SKILL_HOST_ROOT=""; PREFILL_SERVER_SCRIPT=""; DECODE_SERVER_SCRIPT=""
PROXY_LAUNCHER_SCRIPT=""; MOONCAKE_PROXY_SCRIPT=""; DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefill-node) PREFILL_NODE="$2"; shift 2 ;;
    --decode-node) DECODE_NODE="$2"; shift 2 ;;
    --proxy-node) PROXY_NODE="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --image-id) EXPECTED_IMAGE_ID="${2#sha256:}"; shift 2 ;;
    --prefill-port) PREFILL_PORT="$2"; shift 2 ;;
    --decode-port) DECODE_PORT="$2"; shift 2 ;;
    --proxy-port) PROXY_PORT="$2"; shift 2 ;;
    --host-model-path) HOST_MODEL_PATH="$2"; shift 2 ;;
    --network-ifname) NETWORK_IFNAME="$2"; shift 2 ;;
    --nccl-ib-hca) NCCL_IB_HCA="$2"; shift 2 ;;
    --skill-host-root) SKILL_HOST_ROOT="$2"; shift 2 ;;
    --prefill-server-script) PREFILL_SERVER_SCRIPT="$2"; shift 2 ;;
    --decode-server-script) DECODE_SERVER_SCRIPT="$2"; shift 2 ;;
    --proxy-launcher-script) PROXY_LAUNCHER_SCRIPT="$2"; shift 2 ;;
    --mooncake-proxy-script) MOONCAKE_PROXY_SCRIPT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "unknown_arg=$1" >&2; usage; exit 2 ;;
  esac
done

for var in PREFILL_NODE DECODE_NODE PROXY_NODE IMAGE PREFILL_PORT DECODE_PORT PROXY_PORT HOST_MODEL_PATH SKILL_HOST_ROOT PREFILL_SERVER_SCRIPT DECODE_SERVER_SCRIPT PROXY_LAUNCHER_SCRIPT MOONCAKE_PROXY_SCRIPT; do
  [[ -n "${!var}" ]] || { echo "missing_arg=$var" >&2; exit 2; }
done

quote_sh() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
run_ssh() {
  local node="$1" label="$2" cmd="$3"
  echo "== ${node}: ${label} =="
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'ssh %q %q\n' "$node" "$cmd"
  else
    ssh "${SSH_OPTS[@]}" "$node" "$cmd"
  fi
}

check_node_access() {
  local node="$1" output=""
  if [[ "$DRY_RUN" == "1" ]]; then
    run_ssh "$node" ssh_access "true"
    run_ssh "$node" docker_cli "command -v docker >/dev/null || (echo 'DOCKER_UNAVAILABLE' >&2; exit 1)"
    run_ssh "$node" docker_access "docker info >/dev/null || (echo 'DOCKER_UNAVAILABLE_OR_PERMISSION_DENIED' >&2; exit 1)"
    return 0
  fi

  if ! output="$(ssh "${SSH_OPTS[@]}" "$node" true 2>&1)"; then
    if grep -Eqi 'permission denied|authentication failed|publickey' <<<"$output"; then
      echo "SSH_AUTH_FAILED: node=$node detail=$output" >&2
    else
      echo "NODE_UNREACHABLE: node=$node detail=$output" >&2
    fi
    return 1
  fi
  if ! output="$(ssh "${SSH_OPTS[@]}" "$node" "command -v docker" 2>&1)"; then
    echo "DOCKER_UNAVAILABLE: node=$node detail=$output" >&2
    return 1
  fi
  if ! output="$(ssh "${SSH_OPTS[@]}" "$node" "docker info >/dev/null" 2>&1)"; then
    if grep -Eqi 'permission denied|got permission denied|access denied' <<<"$output"; then
      echo "DOCKER_PERMISSION_DENIED: node=$node detail=$output" >&2
    else
      echo "DOCKER_UNAVAILABLE: node=$node detail=$output" >&2
    fi
    return 1
  fi
  echo "NODE_ACCESS_READY=$node"
}

check_node() {
  local node="$1"
  run_ssh "$node" node_info "hostname && uname -a"
  run_ssh "$node" model_path "test -d $(quote_sh "$HOST_MODEL_PATH") || (echo 'HOST_MODEL_PATH_NOT_FOUND: $HOST_MODEL_PATH' >&2; exit 1)"
  if [[ -n "$NETWORK_IFNAME" ]]; then
    run_ssh "$node" network_ifname "(ip link show $(quote_sh "$NETWORK_IFNAME") || ifconfig $(quote_sh "$NETWORK_IFNAME")) >/dev/null 2>&1 || echo 'WARN_NETWORK_IFNAME_NOT_FOUND: $NETWORK_IFNAME'"
  fi
  if [[ -n "$NCCL_IB_HCA" ]]; then
    run_ssh "$node" infiniband_hca "if test -d /sys/class/infiniband; then for hca in \$(printf '%s' $(quote_sh "$NCCL_IB_HCA") | tr ',' ' '); do test -e \"/sys/class/infiniband/\$hca\" || echo \"WARN_NCCL_IB_HCA_NOT_FOUND: \$hca\"; done; else echo 'WARN_INFINIBAND_SYSFS_UNAVAILABLE'; fi"
  fi
}

read_image_id() {
  local node="$1" actual
  if ! actual="$(ssh "${SSH_OPTS[@]}" "$node" "docker image inspect $(quote_sh "$IMAGE") --format '{{.Id}}'" 2>&1)"; then
    if grep -Eqi 'permission denied|authentication failed|publickey' <<<"$actual"; then
      echo "SSH_AUTH_FAILED: node=$node detail=$actual" >&2
    elif grep -Eqi 'connection refused|connection timed out|no route to host|could not resolve|name or service not known' <<<"$actual"; then
      echo "NODE_UNREACHABLE: node=$node detail=$actual" >&2
    elif grep -Eqi 'permission denied.*docker|docker.sock' <<<"$actual"; then
      echo "DOCKER_PERMISSION_DENIED: node=$node detail=$actual" >&2
    elif grep -Eqi 'no such image|no such object' <<<"$actual"; then
      echo "DOCKER_IMAGE_MISSING: image=$IMAGE node=$node" >&2
    else
      echo "DOCKER_UNAVAILABLE: node=$node detail=$actual" >&2
    fi
    return 1
  fi
  actual="${actual#sha256:}"
  [[ "$actual" =~ ^[A-Fa-f0-9]{12,64}$ ]] || {
    echo "DOCKER_IMAGE_ID_INVALID: node=$node actual=$actual" >&2
    return 1
  }
  printf '%s\n' "$actual"
}

check_images() {
  local prefill_id decode_id
  if [[ "$DRY_RUN" == "1" ]]; then
    run_ssh "$PREFILL_NODE" docker_image "docker image inspect $(quote_sh "$IMAGE") --format 'PREFILL_IMAGE_ID={{.Id}}' || (echo 'DOCKER_IMAGE_MISSING: $IMAGE' >&2; exit 1)"
    if [[ "$DECODE_NODE" != "$PREFILL_NODE" ]]; then
      run_ssh "$DECODE_NODE" docker_image "docker image inspect $(quote_sh "$IMAGE") --format 'DECODE_IMAGE_ID={{.Id}}' || (echo 'DOCKER_IMAGE_MISSING: $IMAGE' >&2; exit 1)"
    fi
    echo "IMAGE_ID_CONSISTENCY_CHECK=deferred"
    [[ -z "$EXPECTED_IMAGE_ID" ]] || echo "EXPECTED_IMAGE_ID=$EXPECTED_IMAGE_ID"
    return 0
  fi

  prefill_id="$(read_image_id "$PREFILL_NODE")" || return 1
  if [[ "$DECODE_NODE" == "$PREFILL_NODE" ]]; then
    decode_id="$prefill_id"
  else
    decode_id="$(read_image_id "$DECODE_NODE")" || return 1
  fi
  echo "PREFILL_IMAGE_ID=$prefill_id"
  echo "DECODE_IMAGE_ID=$decode_id"
  if [[ -n "$EXPECTED_IMAGE_ID" ]]; then
    [[ "$prefill_id" == "$EXPECTED_IMAGE_ID"* ]] || {
      echo "DOCKER_IMAGE_ID_MISMATCH: role=prefill expected=$EXPECTED_IMAGE_ID actual=${prefill_id:0:12}" >&2
      return 1
    }
    [[ "$decode_id" == "$EXPECTED_IMAGE_ID"* ]] || {
      echo "DOCKER_IMAGE_ID_MISMATCH: role=decode expected=$EXPECTED_IMAGE_ID actual=${decode_id:0:12}" >&2
      return 1
    }
  fi
  [[ "$prefill_id" == "$decode_id" ]] || {
    echo "PD_IMAGE_ID_MISMATCH: prefill=${prefill_id:0:12} decode=${decode_id:0:12}" >&2
    return 1
  }
  echo "PD_IMAGE_ID_MATCH=1"
}

check_port_free() {
  local node="$1" port="$2"
  run_ssh "$node" "port_${port}" "python3 -c \"import socket; s=socket.socket(); s.bind(('0.0.0.0',$port)); s.close()\" || (echo 'PORT_IN_USE: $port' >&2; exit 1); echo 'PORT_FREE: $port'"
}

check_file() {
  local node="$1" label="$2" relative="$3"
  local full="${SKILL_HOST_ROOT%/}/${relative#./}"
  run_ssh "$node" "$label" "test -f $(quote_sh "$full") || (echo 'REQUIRED_SCRIPT_NOT_FOUND: $full' >&2; exit 1)"
}

check_node_access "$PREFILL_NODE"
[[ "$DECODE_NODE" == "$PREFILL_NODE" ]] || check_node_access "$DECODE_NODE"
if [[ "$PROXY_NODE" != "$PREFILL_NODE" && "$PROXY_NODE" != "$DECODE_NODE" ]]; then
  check_node_access "$PROXY_NODE"
fi
check_images
check_node "$PREFILL_NODE"
[[ "$DECODE_NODE" == "$PREFILL_NODE" ]] || check_node "$DECODE_NODE"
check_port_free "$PREFILL_NODE" "$PREFILL_PORT"
check_port_free "$DECODE_NODE" "$DECODE_PORT"
check_port_free "$PROXY_NODE" "$PROXY_PORT"
check_file "$PREFILL_NODE" prefill_server_script "$PREFILL_SERVER_SCRIPT"
check_file "$DECODE_NODE" decode_server_script "$DECODE_SERVER_SCRIPT"
check_file "$PROXY_NODE" proxy_launcher_script "$PROXY_LAUNCHER_SCRIPT"
check_file "$PROXY_NODE" mooncake_proxy_script "$MOONCAKE_PROXY_SCRIPT"
