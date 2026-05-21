#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
用法:
  create_container.sh --node NODE --image IMAGE --model-short MODEL_SHORT

选项:
  --date MMDD              覆盖容器名中的日期。
  --image-prefix PREFIX    覆盖容器名中的镜像短标识。
  --name NAME              使用已经生成且符合规范的容器名。
  --dry-run                只打印命令，不创建容器。
  --allow-image-prefix-fallback
                           镜像 inspect 失败时允许退回 tag 前 4 位。

环境变量兼容:
  旧版 dry-run 和 image-prefix fallback 环境变量仍兼容；正式调用请使用参数形式。

自动生成的容器名格式:
  lzh-agent-test-<MMDD>-<MODEL_SHORT>-<IMAGE_PREFIX>
USAGE
}

NODE=""
IMAGE=""
MODEL_SHORT=""
DATE_PART="$(date +%m%d)"
IMAGE_PREFIX=""
CONTAINER_NAME=""
DRY_RUN="${DRY_RUN:-0}"
IMAGE_PREFIX_FALLBACK="${IMAGE_PREFIX_FALLBACK:-0}"

tag_prefix_from_image() {
  local image="$1"
  local image_base
  image_base="${image##*:}"
  image_base="${image_base##*/}"
  image_base="${image_base//[^A-Za-z0-9]/}"
  printf '%s\n' "${image_base:0:4}"
}

inspect_image_prefix() {
  local image_id
  image_id="$(ssh "$NODE" "docker image inspect $(printf '%q' "$IMAGE") --format '{{.Id}}'" 2>/dev/null | head -1 || true)"
  image_id="${image_id#sha256:}"
  image_id="${image_id//[^A-Za-z0-9]/}"
  if [[ ${#image_id} -ge 4 ]]; then
    printf '%s\n' "${image_id:0:4}"
    return 0
  fi
  if [[ "${IMAGE_PREFIX_FALLBACK:-0}" == "1" ]]; then
    echo "警告: 无法通过 docker image inspect 解析 Image ID，退回使用镜像 tag 前 4 位。" >&2
    tag_prefix_from_image "$IMAGE"
    return 0
  fi
  echo "无法通过 docker image inspect 解析镜像 ID，请确认镜像存在或显式传入 --image-prefix。" >&2
  return 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --model-short) MODEL_SHORT="$2"; shift 2 ;;
    --date) DATE_PART="$2"; shift 2 ;;
    --image-prefix) IMAGE_PREFIX="$2"; shift 2 ;;
    --name) CONTAINER_NAME="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --allow-image-prefix-fallback) IMAGE_PREFIX_FALLBACK=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$NODE" ]] || { echo "缺少参数: --node" >&2; exit 2; }
[[ -n "$IMAGE" ]] || { echo "缺少参数: --image" >&2; exit 2; }
[[ -n "$MODEL_SHORT" ]] || { echo "缺少参数: --model-short" >&2; exit 2; }

if [[ -z "$IMAGE_PREFIX" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN 模式不会连接节点解析 Image ID；请传入 --image-prefix 以验证最终容器名。" >&2
    IMAGE_PREFIX="AUTO"
  else
    IMAGE_PREFIX="$(inspect_image_prefix)"
  fi
fi

if [[ -z "$CONTAINER_NAME" ]]; then
  CONTAINER_NAME="lzh-agent-test-${DATE_PART}-${MODEL_SHORT}-${IMAGE_PREFIX}"
fi

if ! [[ "$CONTAINER_NAME" =~ ^lzh-agent-test-[0-9]{4}-[a-z0-9]+-[A-Za-z0-9]{4,}$ ]]; then
  echo "容器名不符合规范: $CONTAINER_NAME" >&2
  exit 2
fi

remote_check="docker ps -a --format '{{.Names}}' | grep -Fx '$CONTAINER_NAME'"
remote_run="docker run -itd --name=$CONTAINER_NAME \
  --privileged --network=host \
  --device=/dev/kfd --device=/dev/dri \
  --ipc=host --group-add video \
  --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
  --ulimit stack=-1:-1 --ulimit memlock=-1:-1 \
  -v /public/home/liuzhh8:/mnt \
  -v /module/:/module:ro \
  -v /public/opendas/DL_DATA/llm-models/:/model:ro \
  -v /public4/share/:/model1:ro \
  -v /public4/opendas/DL_DATA/:/model2:ro \
  -v /opt/hyhal:/opt/hyhal:ro \
  $IMAGE bash"

echo "CONTAINER_NAME=$CONTAINER_NAME"
echo "IMAGE_PREFIX=$IMAGE_PREFIX"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  printf 'ssh %q %q\n' "$NODE" "$remote_check"
  printf 'ssh %q %q\n' "$NODE" "$remote_run"
  exit 0
fi

if ssh "$NODE" "$remote_check" >/dev/null 2>&1; then
  echo "容器已存在: $CONTAINER_NAME" >&2
  exit 1
fi

ssh "$NODE" "$remote_run"
