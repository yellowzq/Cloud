#!/bin/sh
# Certbot 初始化脚本 - 在容器内运行
# 接收来自宿主机环境变量

echo "🔐 正在申请 Let's Encrypt 证书..."
echo "域名: $S3_DOMAIN $STORAGE_DOMAIN $WEBDAV_DOMAIN $ROOT_DOMAIN $FRPS_DOMAIN"
echo "邮箱: $MAIN_EMAIL"
echo ""

# 构建域名列表
DOMAINS="-d $S3_DOMAIN -d $STORAGE_DOMAIN -d $WEBDAV_DOMAIN -d $ROOT_DOMAIN -d $FRPS_DOMAIN"

# 执行 certbot
if printf "%s %s %s %s %s" "$S3_DOMAIN" "$STORAGE_DOMAIN" "$WEBDAV_DOMAIN" "$ROOT_DOMAIN" "$FRPS_DOMAIN" | grep -q '\${'; then
    echo "❌ 错误: 检测到未展开的变量占位符，证书申请已中止"
    exit 1
fi

certbot certonly \
  --standalone \
  --agree-tos \
  --non-interactive \
  --email "$MAIN_EMAIL" \
  $DOMAINS

exit $?

