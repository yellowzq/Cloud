#!/usr/bin/env bash
# 备份 RustFS 数据、证书与静态站点
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f .env ]; then
    echo "❌ 错误: 未找到 .env 文件"
    exit 1
fi

set -o allexport
. ./.env
set +o allexport

PROJECT="${COMPOSE_PROJECT_NAME:-storage-net}"
BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/backups}"
VOLUMES=(rustfs-data letsencrypt-certs letsencrypt-www)
COMPOSE=(docker compose -p "$PROJECT" -f docker-compose-personal.yaml)

umask 077
mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"

WAS_RUNNING=false
cleanup() {
    if [ "$WAS_RUNNING" = true ]; then
        "${COMPOSE[@]}" start >/dev/null
    fi
}
trap cleanup EXIT

if [ -n "$("${COMPOSE[@]}" ps --status running -q)" ]; then
    WAS_RUNNING=true
    echo "🛑 停止服务以保证数据一致性..."
    "${COMPOSE[@]}" stop
fi

for vol in "${VOLUMES[@]}"; do
    if ! docker volume inspect "${PROJECT}_${vol}" >/dev/null 2>&1; then
        echo "⚠️  跳过不存在的卷: ${PROJECT}_${vol}"
        continue
    fi
    echo "📦 备份卷 ${vol}..."
    docker run --rm \
        -v "${PROJECT}_${vol}:/data:ro" \
        -v "$BACKUP_DIR:/backup" \
        alpine sh -c "umask 077; tar czf '/backup/${vol}-${STAMP}.tar.gz' -C /data ."
done

if [ -n "${WEB_DATA_DIR:-}" ] && [ -d "$WEB_DATA_DIR" ]; then
    echo "📦 备份静态站点 $WEB_DATA_DIR..."
    docker run --rm -v "$WEB_DATA_DIR:/data:ro" -v "$BACKUP_DIR:/backup" alpine sh -c \
        "umask 077; tar czf '/backup/web-content-${STAMP}.tar.gz' -C /data ."
fi

docker run --rm -v "$BACKUP_DIR:/backup" alpine sh -c \
    "umask 077; cd /backup && sha256sum ./*${STAMP}*.tar.gz > 'SHA256SUMS-${STAMP}'"

echo "✅ 备份完成: $BACKUP_DIR (${STAMP})"
ls -lh "$BACKUP_DIR"/*"$STAMP"*
