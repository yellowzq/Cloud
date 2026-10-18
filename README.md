# Docker 个人存储服务（Linux 版）

自托管 S3/WebDAV/静态站点，Nginx 统一入口，一键初始化与启动。

## 前置要求

- Linux 服务器
- Docker & Docker Compose
- 域名与 DNS：`ROOT_DOMAIN`、`s3.`、`storage.`、`webdav.`、`frps.` 均解析到本机
- 防火墙放行 80/443；RustFS 的 9000/9001/8080 不发布到宿主机

## 快速启动

### 1) 配置

编辑 `.env`（已限制为 600，含密钥，勿外传），至少设置：

- `ROOT_DOMAIN`、`MAIN_EMAIL`
- `RUSTFS_ACCESS_KEY`、`RUSTFS_SECRET_KEY`（同时用于 WebDAV 登录）
- `WEB_DATA_DIR`（静态站点目录，默认 `/data/web`）

`COMPOSE_PROJECT_NAME` 决定命名卷前缀，初始化后不要修改，否则会找不到原有卷。

### 2) 初始化并启动

**生产环境：**
```bash
bash run.sh init
bash run.sh start
```

**测试环境（HTTP）：**
```bash
SKIP_CERTBOT=true bash run.sh init
SKIP_CERTBOT=true bash run.sh start
```

## 访问地址

| 服务 | 地址 |
|------|------|
| 存储控制台 | `https://storage.your-domain.com` |
| S3 API | `https://s3.your-domain.com` |
| WebDAV | `https://webdav.your-domain.com` |
| FRP | `https://frps.your-domain.com` |
| 网站 | `https://your-domain.com` |

静态文件由主 Nginx 直接读取 `${WEB_DATA_DIR}`，`/foo` 会依次尝试 `foo`、`foo.html`、`foo/`。

## 常用命令

```bash
bash run.sh start
bash run.sh stop
bash run.sh restart   # 重新加载 .env 并重建容器
bash run.sh logs
bash run.sh logs nginx
```

## WebDAV 说明

WebDAV 由 RustFS 原生网关提供（容器内监听 `8080`），Nginx 在 `webdav.${ROOT_DOMAIN}` 终止 TLS 后反向代理。

- 用户名：`RUSTFS_ACCESS_KEY`
- 密码：`RUSTFS_SECRET_KEY`

网关由 `.env` 中的 `RUSTFS_WEBDAV_ENABLE`、`RUSTFS_WEBDAV_ADDRESS`、`RUSTFS_WEBDAV_TLS_ENABLED` 控制。

## 证书续期

- `certbot` 容器每 12 小时执行一次 `certbot renew`（webroot 模式）
- Nginx 容器每 6 小时自动 `nginx -s reload`，使新证书生效
- 首次申请使用独立容器 `docker-compose-init.yaml`，占用 80 端口
- 新增域名时先更新 `.env`，再执行一次 `bash run.sh init`（必要时配合 `certbot certonly --expand`）

检查实际生效的证书：
```bash
echo | openssl s_client -servername s3.your-domain.com -connect s3.your-domain.com:443 2>/dev/null | openssl x509 -noout -dates
```

## 备份与恢复

```bash
# 备份（自动停止/启动服务，输出到 backups/，含 SHA256SUMS）
bash export_backups.sh

# 恢复（默认取最新一次；也可指定目录和时间戳）
bash import_backups.sh [备份目录] [时间戳]
```

备份范围：`rustfs-data`、`letsencrypt-certs`、`letsencrypt-www`、`WEB_DATA_DIR` 静态站点。`nginx-cache` 为临时缓存，不备份。

## 常见问题

- 证书申请失败：检查 DNS 与 80 端口，查看 `docker compose -p storage-net -f docker-compose-init.yaml logs`
- 证书不存在：`bash run.sh init`
- 服务无法访问：`bash run.sh logs nginx`
- 控制台 403：非浏览器客户端访问 `/` 属正常行为，控制台路径为 `/rustfs/console/`
