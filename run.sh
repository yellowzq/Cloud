#!/bin/bash
# 统一启动脚本 - 处理初始化和启动
# 用法：
#   bash run.sh init   # 首次运行，初始化证书
#   bash run.sh start  # 启动服务
#   bash run.sh        # 等同于 bash run.sh start

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# 加载环境变量
if [ ! -f .env ]; then
    echo "❌ 错误: 未找到 .env 文件"
    exit 1
fi

# 保留命令行显式传入的 SKIP_CERTBOT（.env 中的值不应覆盖它）
SKIP_CERTBOT_OVERRIDE="${SKIP_CERTBOT:-}"

# 安全加载 .env 并导出所有变量，保留变量引用展开功能
# 使用 set -o allexport 以便 source 后变量自动导出
set -o allexport
. .env
set +o allexport

if [ -n "$SKIP_CERTBOT_OVERRIDE" ]; then
    SKIP_CERTBOT="$SKIP_CERTBOT_OVERRIDE"
    export SKIP_CERTBOT
fi

# 固定 Compose 项目名（可通过 .env 覆盖）
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-storage-net}"
export COMPOSE_PROJECT_NAME

# 展开基于 ROOT_DOMAIN 的派生域名（处理 .env 中类似 s3.${ROOT_DOMAIN} 的字面值）
if [ -n "$ROOT_DOMAIN" ]; then
    S3_DOMAIN=$(printf "%s" "$S3_DOMAIN" | sed "s/\${ROOT_DOMAIN}/$ROOT_DOMAIN/g")
    STORAGE_DOMAIN=$(printf "%s" "$STORAGE_DOMAIN" | sed "s/\${ROOT_DOMAIN}/$ROOT_DOMAIN/g")
    WEBDAV_DOMAIN=$(printf "%s" "$WEBDAV_DOMAIN" | sed "s/\${ROOT_DOMAIN}/$ROOT_DOMAIN/g")
    FRPS_DOMAIN=$(printf "%s" "$FRPS_DOMAIN" | sed "s/\${ROOT_DOMAIN}/$ROOT_DOMAIN/g")
    export S3_DOMAIN STORAGE_DOMAIN WEBDAV_DOMAIN FRPS_DOMAIN
fi

# 选择并生成 Nginx 配置（不修改源文件）
NGINX_SOURCE=""
select_nginx_config() {
    if [ "$SKIP_CERTBOT" = "true" ]; then
        echo "📝 使用 HTTP 测试配置"
        NGINX_SOURCE="nginx.conf.http"
    else
        echo "📝 使用 HTTPS 生产配置"
        NGINX_SOURCE="nginx.conf.https"
    fi

    generate_nginx_conf
}

# 生成 Nginx 配置
generate_nginx_conf() {
    if [ ! -f "$NGINX_SOURCE" ]; then
        echo "❌ 错误: 未找到 $NGINX_SOURCE"
        exit 1
    fi

    if command -v envsubst &> /dev/null; then
        envsubst '$ROOT_DOMAIN' < "$NGINX_SOURCE" > nginx.conf
    else
        sed -e "s|\${ROOT_DOMAIN}|$ROOT_DOMAIN|g" "$NGINX_SOURCE" > nginx.conf
    fi
}

# 初始化证书
init_cert() {
    echo "🔐 初始化 SSL 证书..."
    
    # 检查证书是否已存在
    CERT_COUNT=$(docker run --rm -v ${COMPOSE_PROJECT_NAME}_letsencrypt-certs:/etc/letsencrypt alpine find /etc/letsencrypt/live -name "fullchain.pem" 2>/dev/null | wc -l)
    if [ "$CERT_COUNT" -gt 0 ]; then
        echo "✅ 证书已存在，跳过初始化"
        return 0
    fi
    
    if [ "$SKIP_CERTBOT" = "true" ]; then
        echo "📝 生成自签名证书（测试模式）..."
        CERT_DOMAIN="${S3_DOMAIN:-s3.$ROOT_DOMAIN}"
        docker run --rm -v "${COMPOSE_PROJECT_NAME}_letsencrypt-certs:/etc/letsencrypt" alpine sh -c "
            apk add --no-cache openssl
            mkdir -p /etc/letsencrypt/live/$CERT_DOMAIN
            openssl req -x509 -newkey rsa:2048 \
              -keyout /etc/letsencrypt/live/$CERT_DOMAIN/privkey.pem \
              -out /etc/letsencrypt/live/$CERT_DOMAIN/fullchain.pem -days 365 -nodes \
              -subj '/CN=$CERT_DOMAIN' \
              -addext 'subjectAltName=DNS:$CERT_DOMAIN,DNS:$STORAGE_DOMAIN,DNS:$WEBDAV_DOMAIN,DNS:$ROOT_DOMAIN,DNS:$FRPS_DOMAIN'
            chmod 644 /etc/letsencrypt/live/$CERT_DOMAIN/*
        "
        echo "✅ 自签名证书已生成"
    else
        echo "📝 申请 Let's Encrypt 证书..."
        export MAIN_EMAIL S3_DOMAIN STORAGE_DOMAIN WEBDAV_DOMAIN ROOT_DOMAIN FRPS_DOMAIN
        if ! docker compose -p "${COMPOSE_PROJECT_NAME}" -f docker-compose-init.yaml \
            up --abort-on-container-exit --exit-code-from certbot-init; then
            docker compose -p "${COMPOSE_PROJECT_NAME}" -f docker-compose-init.yaml down
            echo "❌ 证书申请失败"
            return 1
        fi
        docker compose -p "${COMPOSE_PROJECT_NAME}" -f docker-compose-init.yaml down
        echo "✅ 证书申请完成"
    fi
}

# 启动服务
start_services() {
    echo "🚀 启动 Docker 服务..."
    
    # 选择合适的配置
    select_nginx_config
    
    # 检查证书
    CERT_COUNT=$(docker run --rm -v ${COMPOSE_PROJECT_NAME}_letsencrypt-certs:/etc/letsencrypt alpine find /etc/letsencrypt/live -name "fullchain.pem" 2>/dev/null | wc -l)
    if [ "$CERT_COUNT" -eq 0 ]; then
        echo "❌ 未找到证书，请先运行: bash run.sh init"
        exit 1
    fi

    docker compose -p "${COMPOSE_PROJECT_NAME}" -f docker-compose-personal.yaml up -d --wait --force-recreate
    docker compose -p "${COMPOSE_PROJECT_NAME}" -f docker-compose-personal.yaml ps
    
    echo ""
    echo "✨ 启动完成！"
    if [ "$SKIP_CERTBOT" = "true" ]; then
        echo "🌐 测试模式 - HTTP 访问地址:"
        echo "   S3 API:     http://s3.${ROOT_DOMAIN}"
        echo "   WebDAV:     http://webdav.${ROOT_DOMAIN}"
        echo "   存储控制台: http://storage.${ROOT_DOMAIN}"
        echo "   FRP:        http://${FRPS_DOMAIN}"
        echo "   网站:       http://${ROOT_DOMAIN}"
    else
        echo "🌐 生产模式 - HTTPS 访问地址:"
        echo "   S3 API:     https://s3.${ROOT_DOMAIN}"
        echo "   WebDAV:     https://webdav.${ROOT_DOMAIN}"
        echo "   存储控制台: https://storage.${ROOT_DOMAIN}"
        echo "   FRP:        https://${FRPS_DOMAIN}"
        echo "   网站:       https://${ROOT_DOMAIN}"
    fi
}

# 主程序
case "${1:-start}" in
    init)
        select_nginx_config
        init_cert
        echo ""
        echo "💡 下一步: bash run.sh start"
        ;;
    start)
        start_services
        ;;
    stop)
        docker compose -p "${COMPOSE_PROJECT_NAME}" -f docker-compose-personal.yaml down
        echo "✅ 服务已停止"
        ;;
    restart)
        select_nginx_config
        docker compose -p "${COMPOSE_PROJECT_NAME}" -f docker-compose-personal.yaml up -d --wait --force-recreate
        echo "✅ 服务已重启"
        ;;
    logs)
        docker compose -p "${COMPOSE_PROJECT_NAME}" -f docker-compose-personal.yaml logs -f "${2:-}"
        ;;
    *)
        echo "用法: bash run.sh [命令]"
        echo ""
        echo "命令:"
        echo "  init       - 初始化证书（首次运行）"
        echo "  start      - 启动服务（默认）"
        echo "  stop       - 停止服务"
        echo "  restart    - 重启服务"
        echo "  logs [服务名] - 查看日志"
        echo ""
        echo "环境变量:"
        echo "  SKIP_CERTBOT=true  - 测试模式，使用 HTTP 和自签名证书"
        exit 1
        ;;
esac
