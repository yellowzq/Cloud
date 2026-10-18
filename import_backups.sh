#!/usr/bin/env bash
# 从备份恢复 RustFS 数据、证书与静态站点
# 用法: bash import_backups.sh [备份目录] [时间戳]
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
BACKUP_DIR="${1:-$SCRIPT_DIR/backups}"
VOLUMES=(rustfs-data letsencrypt-certs letsencrypt-www)
COMPOSE=(docker compose -p "$PROJECT" -f docker-compose-personal.yaml)

if [ ! -d "$BACKUP_DIR" ]; then
    echo "❌ 错误: 备份目录不存在: $BACKUP_DIR"
    exit 1
fi

STAMP="${2:-}"
if [ -z "$STAMP" ]; then
    LATEST="$(ls -1 "$BACKUP_DIR"/rustfs-data-*.tar.gz 2>/dev/null | sort | tail -n 1 || true)"
    if [ -z "$LATEST" ]; then
        echo "❌ 错误: 未找到 rustfs-data 备份"
        exit 1
    fi
    STAMP="$(basename "$LATEST" .tar.gz)"
    STAMP="${STAMP#rustfs-data-}"
fi

echo "📥 恢复备份: $BACKUP_DIR (${STAMP})"

if [ -f "$BACKUP_DIR/SHA256SUMS-${STAMP}" ]; then
    docker run --rm -v "$BACKUP_DIR:/backup:ro" alpine sh -c \
        "cd /backup && sha256sum -c 'SHA256SUMS-${STAMP}'"
fi

WAS_RUNNING=false
cleanup() {
    if [ "$WAS_RUNNING" = true ]; then
        "${COMPOSE[@]}" start >/dev/null
    fi
}
trap cleanup EXIT

if [ -n "$("${COMPOSE[@]}" ps --status running -q)" ]; then
    WAS_RUNNING=true
    echo "🛑 停止服务..."
    "${COMPOSE[@]}" stop
fi

for vol in "${VOLUMES[@]}"; do
    archive="$BACKUP_DIR/${vol}-${STAMP}.tar.gz"
    if [ ! -f "$archive" ]; then
        echo "⚠️  跳过不存在的备份: $archive"
        continue
    fi
    echo "📦 恢复卷 ${vol}..."
    docker volume create "${PROJECT}_${vol}" >/dev/null
    docker run --rm \
        -v "${PROJECT}_${vol}:/data" \
        -v "$BACKUP_DIR:/backup:ro" \
        alpine sh -c "tar xzf '/backup/${vol}-${STAMP}.tar.gz' -C /data"
done

if [ -f "$BACKUP_DIR/web-content-${STAMP}.tar.gz" ] && [ -n "${WEB_DATA_DIR:-}" ]; then
    echo "📦 恢复静态站点 $WEB_DATA_DIR..."
    docker run --rm -v "$WEB_DATA_DIR:/data" -v "$BACKUP_DIR:/backup:ro" alpine sh -c \
        "tar xzf '/backup/web-content-${STAMP}.tar.gz' -C /data"
fi

echo "✅ 恢复完成"
