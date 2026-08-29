#!/usr/bin/env bash
# 本地构建发布（fork-sync-kit）—— 合入后：本地构建镜像 → 推 model.publib.cn →（可选）NAS 更新
# 方案见 OMNIROUTE_FORK_SYNC_CN.md §4.4；配置见 sync.conf（OMNI_* / NAS_*）。
#
# 用法:
#   release.sh <上游版本号> [--push] [--nas]     # 例: release.sh 3.8.52
#     （不带 --push/--nas 时只本地构建并打 tag，便于先本机验证）
set -euo pipefail

KIT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$KIT_DIR/.." && pwd)"
CONF="$KIT_DIR/sync.conf"
[[ -f "$CONF" ]] || { echo "[release] 错误: 缺少 $CONF" >&2; exit 2; }
# shellcheck source=/dev/null
source "$CONF"
: "${OMNI_REGISTRY:?sync.conf 缺少 OMNI_REGISTRY}"
: "${OMNI_IMAGE_PATH:?sync.conf 缺少 OMNI_IMAGE_PATH}"
: "${OMNI_IMAGE_TAG_SUFFIX:?sync.conf 缺少 OMNI_IMAGE_TAG_SUFFIX}"

ver="${1:?用法: release.sh <上游版本号> [--push] [--nas]}"
ver_num="$(echo "$ver" | tr -cd '0-9.')"
tag="${OMNI_REGISTRY}/${OMNI_IMAGE_PATH}:${ver_num}-${OMNI_IMAGE_TAG_SUFFIX}"
PUSH=0; NAS=0
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --push) PUSH=1; shift ;;
    --nas)  NAS=1; shift ;;
    *) echo "[release] 未知参数: $1" >&2; exit 2 ;;
  esac
done

echo "[release] 构建 ${tag}（Dockerfile target: runner-base，见 OMNIROUTE_DEPLOYMENT_CN.md §4.4）"
docker build --pull --target runner-base -t "$tag" "$REPO_ROOT"

if [[ $PUSH -eq 1 ]]; then
  echo "[release] 推送 $tag"
  docker push "$tag"
else
  echo "[release] 未推送（无 --push）。验证后手动: docker push $tag"
fi

manual_nas_steps() {
  cat <<EOF
[release] NAS 更新（手工步骤，见 deploy/nas）:
  1. 修改 NAS 上 $NAS_DIR/.env 的 OMNIROUTE_IMAGE=$tag
  2. cd $NAS_DIR && docker compose pull && docker compose up -d
  3. 验证: curl -fsS ${NAS_HEALTH_URL:-http://127.0.0.1:20128/healthz}
EOF
}

if [[ $NAS -eq 1 ]]; then
  if [[ -z "${NAS_SSH_HOST:-}" ]]; then
    echo "[release] 未配置 NAS_SSH_HOST，改为打印手工步骤" >&2
    manual_nas_steps
  else
    # UGREEN SSH 对 /volume1 绝对路径有限制（deploy/nas/AGENT_DEPLOY.md），失败时请走手工步骤
    ssh "$NAS_SSH_HOST" "cd '$NAS_DIR' \
      && sed -i.bak 's|^OMNIROUTE_IMAGE=.*|OMNIROUTE_IMAGE=$tag|' .env \
      && docker compose pull && docker compose up -d"
    sleep 5
    ssh "$NAS_SSH_HOST" "curl -fsS '${NAS_HEALTH_URL:-http://127.0.0.1:20128/healthz}'" \
      && echo "[release] NAS 健康检查通过: $tag" \
      || { echo "[release] 错误: NAS 健康检查未通过，请回滚 OMNIROUTE_IMAGE 并 compose up -d" >&2; exit 1; }
  fi
else
  manual_nas_steps
fi
echo "[release] 完成: $tag"
