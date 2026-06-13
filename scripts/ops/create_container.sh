#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  create_container.sh --node NODE --image IMAGE --model-short MODEL_SHORT [options]

Options:
  --date MMDD
  --image-prefix PREFIX
  --user USER
  --abbr ABBR
  --home-root PATH
  --container-prefix PREFIX
  --host-home-root PATH
  --name NAME                 Use an already generated container name
  --host-model-path PATH      Mount this model directory read-only
  --container-model-path PATH Container mount target for the model
  --dry-run
  --allow-image-prefix-fallback

Container name format:
  <CONTAINER_PREFIX>-<MMDD>-<MODEL_SHORT>-<IMAGE_PREFIX>
USAGE
}

NODE=""
IMAGE=""
MODEL_SHORT=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/runtime_config.sh"
SKILL_USER=""
USER_ABBR=""
HOME_ROOT=""
HOST_HOME_ROOT=""
SKILL_HOST_ROOT=""
OUTPUT_HOST_ROOT=""
OUTPUT_CONTAINER_ROOT="${OUTPUT_CONTAINER_ROOT:-}"
DATE_PART="$(date +%m%d)"
IMAGE_PREFIX=""
CONTAINER_NAME=""
CONTAINER_NAME_EXPLICIT=0
HOST_MODEL_PATH=""
CONTAINER_MODEL_PATH=""
CONTAINER_PREFIX=""
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
    echo "WARN: docker image inspect failed; fallback to image tag prefix." >&2
    tag_prefix_from_image "$IMAGE"
    return 0
  fi
  echo "Cannot resolve image id; confirm image exists or pass --image-prefix." >&2
  return 1
}

validate_prefix() {
  local prefix="$1"
  if ! [[ "$prefix" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]]; then
    echo "Invalid container prefix: $prefix" >&2
    echo "Use lowercase letters, digits, and hyphens; start and end with alnum." >&2
    return 2
  fi
}

while [[ $# -gt 0 ]]; do
  if runtime_config_parse_common_arg "$1" "${2-}"; then
    shift 2
    continue
  fi
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --model-short) MODEL_SHORT="$2"; shift 2 ;;
    --date) DATE_PART="$2"; shift 2 ;;
    --image-prefix) IMAGE_PREFIX="$2"; shift 2 ;;
    --name) CONTAINER_NAME="$2"; CONTAINER_NAME_EXPLICIT=1; shift 2 ;;
    --host-model-path) HOST_MODEL_PATH="$2"; shift 2 ;;
    --container-model-path) CONTAINER_MODEL_PATH="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --allow-image-prefix-fallback) IMAGE_PREFIX_FALLBACK=1; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$NODE" ]] || { echo "missing argument: --node" >&2; exit 2; }
[[ -n "$IMAGE" ]] || { echo "missing argument: --image" >&2; exit 2; }
[[ -n "$MODEL_SHORT" ]] || { echo "missing argument: --model-short" >&2; exit 2; }
[[ -n "$HOST_MODEL_PATH" ]] || { echo "missing argument: --host-model-path" >&2; exit 2; }
[[ -n "$CONTAINER_MODEL_PATH" ]] || { echo "missing argument: --container-model-path" >&2; exit 2; }
resolve_runtime_config
validate_prefix "$CONTAINER_PREFIX"

if [[ -z "$IMAGE_PREFIX" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN does not inspect remote image id; pass --image-prefix to verify final container name." >&2
    IMAGE_PREFIX="AUTO"
  else
    IMAGE_PREFIX="$(inspect_image_prefix)"
  fi
fi

if [[ -z "$CONTAINER_NAME" ]]; then
  CONTAINER_NAME="${CONTAINER_PREFIX}-${DATE_PART}-${MODEL_SHORT}-${IMAGE_PREFIX}"
fi

if [[ "$CONTAINER_NAME_EXPLICIT" == "1" ]]; then
  python3 "$SCRIPT_DIR/container_name.py" --name "$CONTAINER_NAME" --prefix "$CONTAINER_PREFIX"
else
  python3 "$SCRIPT_DIR/container_name.py" --name "$CONTAINER_NAME" --prefix "$CONTAINER_PREFIX" \
    --legacy --date "$DATE_PART" --model-short "$MODEL_SHORT" --image-prefix "$IMAGE_PREFIX"
fi

remote_check="docker ps -a --format '{{.Names}}' | grep -Fx '$CONTAINER_NAME'"
remote_run="docker run -itd --name=$CONTAINER_NAME \
  --privileged --network=host \
  --device=/dev/kfd --device=/dev/dri \
  --ipc=host --group-add video \
  --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
  --ulimit stack=-1:-1 --ulimit memlock=-1:-1 \
  -v ${HOST_HOME_ROOT}:/mnt \
  -v /module/:/module:ro \
  -v ${HOST_MODEL_PATH}:${CONTAINER_MODEL_PATH}:ro \
  -v /opt/hyhal:/opt/hyhal:ro \
  $IMAGE bash"
remote_model_check="docker exec $CONTAINER_NAME test -d $(printf '%q' "$CONTAINER_MODEL_PATH")"

echo "CONTAINER_NAME=$CONTAINER_NAME"
echo "CONTAINER_PREFIX=$CONTAINER_PREFIX"
echo "HOST_HOME_ROOT=$HOST_HOME_ROOT"
echo "IMAGE_PREFIX=$IMAGE_PREFIX"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  printf 'ssh %q %q\n' "$NODE" "$remote_check"
  printf 'ssh %q %q\n' "$NODE" "$remote_run"
  printf 'ssh %q %q\n' "$NODE" "$remote_model_check"
  exit 0
fi

if ssh "$NODE" "$remote_check" >/dev/null 2>&1; then
  echo "container already exists: $CONTAINER_NAME" >&2
  exit 1
fi

CONTAINER_ID="$(ssh "$NODE" "$remote_run")"
echo "CONTAINER_ID=$CONTAINER_ID"
if ! ssh "$NODE" "$remote_model_check"; then
  echo "CONTAINER_MODEL_PATH_MISSING=$CONTAINER_MODEL_PATH" >&2
  echo "STOP_NEW_CONTAINER_AFTER_MODEL_CHECK_FAILURE=$CONTAINER_NAME" >&2
  ssh "$NODE" "docker stop $(printf '%q' "$CONTAINER_NAME")" >/dev/null 2>&1 || \
    echo "WARN_STOP_NEW_CONTAINER_FAILED=$CONTAINER_NAME" >&2
  exit 1
fi
echo "CONTAINER_MODEL_PATH_OK=$CONTAINER_MODEL_PATH"
