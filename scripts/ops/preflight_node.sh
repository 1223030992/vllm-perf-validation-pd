#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
用法:
  preflight_node.sh --node NODE --image IMAGE --ports "9348 9350" \
    --host-model-paths "/path/a /path/b" --container-names "name-a name-b"

选项:
  --dry-run     只打印命令，不执行远端检查。

说明:
  正式调用和诊断调用都应使用参数形式 --dry-run，不要使用环境变量前缀。
  旧版 dry-run 环境变量仅保留为兼容脚本，不作为推荐入口。
USAGE
}

NODE=""
IMAGE=""
PORTS=""
HOST_MODEL_PATHS=""
CONTAINER_NAMES=""
DRY_RUN="${DRY_RUN:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --ports) PORTS="$2"; shift 2 ;;
    --host-model-paths) HOST_MODEL_PATHS="$2"; shift 2 ;;
    --container-names) CONTAINER_NAMES="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$NODE" ]] || { echo "缺少参数: --node" >&2; exit 2; }
[[ -n "$IMAGE" ]] || { echo "缺少参数: --image" >&2; exit 2; }

run_ssh() {
  local label="$1"
  local cmd="$2"
  echo "== $label =="
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf 'ssh %q %q\n' "$NODE" "$cmd"
    return 0
  fi
  ssh "$NODE" "$cmd"
}

run_ssh "节点信息" "hostname && uname -a"
run_ssh "DCU/GPU 状态" "/opt/hyhal/bin/hy-smi 2>/dev/null || rocm-smi --showid 2>/dev/null || nvidia-smi -L 2>/dev/null || (test -e /dev/kfd && echo '发现 KFD 设备')"
run_ssh "Docker 版本" "docker --version"
run_ssh "镜像检查" "docker image inspect '$IMAGE' --format '{{.RepoTags}}' 2>/dev/null || echo '镜像不存在'"

for port in $PORTS; do
  run_ssh "端口检查 $port" "ss -tlnp 2>/dev/null | grep ':$port ' || echo '端口 $port 空闲'"
done

for path in $HOST_MODEL_PATHS; do
  run_ssh "宿主机模型路径 $path" "test -d '$path' && echo '模型目录存在' || echo '模型目录不存在'"
done

for name in $CONTAINER_NAMES; do
  run_ssh "容器名冲突 $name" "docker ps -a --format '{{.Names}}' | grep -Fx '$name' || echo '无容器名冲突'"
done
