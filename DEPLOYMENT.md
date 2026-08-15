# M Post Office Docker 部署手册

本文档说明如何在一台 Linux 服务器上以 Docker Compose 方式部署、升级、备份和恢复 M Post Office。

> 范围说明：本仓库的生产栈负责 Web 管理端、Webmail、API、任务队列、数据库和 HTTPS 网关。SMTP/IMAP 传输服务应使用现有的 Postfix/Dovecot、企业邮件网关或兼容的托管邮件服务，并通过 `.env` 中的 `SMTP_*`、`IMAP_*` 接入。邮箱增删还要求 Postfix/Dovecot 使用 M Post Office 的 SQL 映射，或由 Dovecot 暴露受保护的 `doveadm` REST API。这样不会在缺少 PTR、反垃圾和投递信誉配置时意外开放一个不安全的公网邮件中继。

## 1. 部署架构

```text
Internet
   │  TCP 80/443
   ▼
Caddy（自动 HTTPS、静态文件、反向代理）
   ├── Vue 前端
   ├── Django/Gunicorn API ── PostgreSQL
   │                       └─ Redis
   ├── RQ Worker ──────────── Redis
   └── RQ Scheduler ───────── Redis

M Post Office ── IMAPS/Submission ── 现有 Dovecot/Postfix 或托管邮件服务
```

生产 Compose 包含以下服务：

| 服务 | 用途 | 是否暴露公网端口 |
| --- | --- | --- |
| `gateway` | Caddy HTTPS、前端静态文件和 API 代理 | `80/tcp`、`443/tcp+udp` |
| `web` | Django + Gunicorn | 否 |
| `worker` | DKIM、后台作业和 Dovecot 队列 | 否 |
| `scheduler` | 周期任务 | 否 |
| `db` | PostgreSQL 主数据库 | 否 |
| `redis` | 缓存和任务队列 | 否 |

数据库、媒体、静态文件、前端文件、Redis 和 Caddy 证书全部使用 Docker named volume 持久化。

## 2. 前置条件

建议配置：

- Ubuntu 24.04 LTS、Debian 12 或其他受支持的 64 位 Linux；
- 2 核 CPU、4 GB 内存、至少 30 GB 可用磁盘；
- Docker Engine 27+ 与 Docker Compose v2；
- 一个解析到服务器公网 IP 的域名，例如 `mail.example.com`；
- 防火墙允许 `80/tcp`、`443/tcp` 和 `443/udp`；
- 可连接的 IMAP/SMTP 服务。

检查 Docker：

```bash
docker version
docker compose version
```

若服务器已有 Nginx、Caddy、Traefik 或面板占用 80/443，请阅读“已有反向代理”一节，不要直接启动默认网关端口。

## 3. DNS 和网络准备

为 Web 入口配置 DNS：

```dns
mail.example.com.  IN  A     203.0.113.10
# 有 IPv6 时再添加 AAAA；没有可用 IPv6 时不要添加。
```

Caddy 申请 ACME 证书前必须满足：

1. A/AAAA 已解析到本机；
2. 公网能够访问 80 和 443；
3. `SITE_ADDRESS` 是真实域名；
4. `ACME_EMAIL` 是有效邮箱。

本应用连接外部邮件传输时，还需要由邮件管理员正确配置 MX、PTR/rDNS、SPF、DKIM、DMARC 和自动发现记录。它们与 Web 入口证书不是一回事。

## 4. 首次安装

### 4.0 一键安装（推荐）

在 Ubuntu、Debian、RHEL/Rocky/AlmaLinux 或 Fedora 服务器上进入仓库后执行：

```bash
sudo bash scripts/install.sh
```

脚本会自动完成：

1. 检测操作系统和 root/sudo 权限；
2. 从 Docker 官方软件源安装 Docker Engine、Buildx 和 Compose 插件；
3. 启用 Docker 服务；
4. 交互收集域名、ACME 邮箱、IMAP、SMTP 和可选 doveadm API；
5. 生成数据库、Django、管理员和 OIDC 随机密钥；
6. 配置 UFW/firewalld（已启用时）；
7. 校验配置、构建镜像并启动全部生产服务；
8. 输出访问地址和初始管理员密码。

无人值守安装示例：

```bash
sudo bash scripts/install.sh \
  --domain mail.example.com \
  --email ops@example.com \
  --admin-user admin \
  --imap-host imap.example.com \
  --smtp-host smtp.example.com \
  --doveadm-url https://imap.example.com:8080/doveadm/v1 \
  --non-interactive
```

仅用于本机验证：

```bash
sudo bash scripts/install.sh --local
# 打开 http://localhost:8080
```

完整参数：`bash scripts/install.sh --help`。如果 Docker 已由运维平台管理，可加 `--skip-docker-install`；如果防火墙由云安全组或其他系统管理，可加 `--skip-firewall`。

脚本可重复执行。已有 `.env`、OIDC 私钥和 Docker 数据卷不会被删除；重复执行会保留密钥并重建/升级应用。下文是同一安装过程的手动步骤，适合需要逐项控制的环境。

### 4.1 获取代码

```bash
git clone <你的仓库地址> m-post-office
cd m-post-office
```

### 4.2 初始化密钥

```bash
bash scripts/deploy.sh init
```

脚本会：

- 从 `.env.example` 创建不会提交到 Git 的 `.env`；
- 生成 Django、PostgreSQL 和初始管理员随机密码；
- 生成 4096 位 OIDC RSA 私钥到 `deploy/secrets/oidc_private_key.pem`；
- 创建本地 `backups/` 目录。

如果 `.env` 或私钥已经存在，脚本不会覆盖。

### 4.3 编辑 `.env`

至少修改这些值：

```dotenv
SITE_ADDRESS=mail.example.com
APP_DOMAIN=mail.example.com
PUBLIC_URL=https://mail.example.com
ACME_EMAIL=ops@example.com
DJANGO_ALLOWED_HOSTS=mail.example.com
DJANGO_CSRF_TRUSTED_ORIGINS=https://mail.example.com

IMAP_HOST=imap.example.com
IMAP_PORT=993
IMAP_SOCKET_TYPE=SSL
DOVECOT_OPERATION_MODE=rest
DOVEADM_API_URL=https://imap.example.com:8080/doveadm/v1
DOVEADM_API_KEY=替换为随机且仅服务端保存的 API 密钥
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_SOCKET_TYPE=STARTTLS
SMTP_USERNAME=service-account@example.com
SMTP_PASSWORD=替换为真实密码
DEFAULT_FROM_EMAIL="M Post Office <postmaster@example.com>"
```

变量说明：

| 变量 | 说明 |
| --- | --- |
| `SITE_ADDRESS` | Caddy 站点地址；真实域名会自动启用 HTTPS |
| `APP_DOMAIN` | Django Site 和 OAuth 回调使用的主域名 |
| `PUBLIC_URL` | 用户实际访问的完整来源；包含协议，非标准端口时也要包含端口 |
| `DJANGO_ALLOWED_HOSTS` | 允许的 Host，多个值用逗号分隔 |
| `DJANGO_CSRF_TRUSTED_ORIGINS` | 完整来源，必须包含 `https://`，多个值用逗号分隔 |
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` | 首次管理员；每次启动会确保该账号密码与环境一致 |
| `GUNICORN_WORKERS` | Web worker 数；一般取 `2 × CPU + 1`，受内存限制时降低 |
| `IMAP_*` | Webmail 读取邮箱的服务地址 |
| `SMTP_*` | Webmail 发信及系统通知使用的服务地址 |
| `DOVEADM_API_*` | 创建、重命名和删除邮箱目录时调用的 Dovecot 管理 API |

不要提交 `.env`、`deploy/secrets/` 或 `backups/`。这些路径已加入 `.gitignore`，仍建议额外使用服务器权限和加密备份保护。

### 4.4 配置预检

```bash
bash scripts/deploy.sh doctor
```

预检会确认 Docker Compose 可用、密钥存在、配置中没有 `CHANGE_ME` 或示例域名，并运行 `docker compose config --quiet`。

### 4.5 构建并启动

```bash
bash scripts/deploy.sh up
```

首次构建会下载 Node、Python、PostgreSQL、Redis 和 Caddy 镜像并编译前后端，通常需要数分钟。启动过程中 `web` 容器自动执行：

1. 等待 PostgreSQL；
2. 执行 Django 数据库迁移；
3. 创建基础角色、OAuth 客户端和初始管理员；
4. 设置站点域名和管理员密码；
5. 收集静态文件并发布前端；
6. 启动 Gunicorn。

查看状态和日志：

```bash
bash scripts/deploy.sh status
bash scripts/deploy.sh logs web
bash scripts/deploy.sh logs gateway
```

全部服务健康后打开 `https://mail.example.com`，使用 `.env` 中的 `ADMIN_USERNAME` 和 `ADMIN_PASSWORD` 登录。首次登录后建议创建个人管理员账号，并把初始密码保存在密码管理器中。

## 5. 本机 HTTP 验证

只在本机或隔离网络测试时使用以下配置：

```dotenv
SITE_ADDRESS=:80
APP_DOMAIN=localhost
PUBLIC_URL=http://localhost:8080
DJANGO_ALLOWED_HOSTS=localhost,127.0.0.1
DJANGO_CSRF_TRUSTED_ORIGINS=http://localhost
COOKIE_SECURE=false
SECURE_HSTS_SECONDS=0
HTTP_PORT=8080
```

此时通过 `http://localhost:8080` 访问。生产环境必须恢复真实域名、HTTPS、Secure Cookie 和 HSTS。

## 6. 日常运维

```bash
# 查看容器与健康状态
bash scripts/deploy.sh status

# 查看全部日志或指定服务日志
bash scripts/deploy.sh logs
bash scripts/deploy.sh logs worker

# 重启（不重建镜像）
bash scripts/deploy.sh restart

# 停止容器，保留所有数据卷
bash scripts/deploy.sh down

# 输出最终 Compose 配置，排查变量问题
bash scripts/deploy.sh config
```

执行 Django 管理命令：

```bash
docker compose --env-file .env -f docker-compose.prod.yml \
  run --rm web manage check --deploy
```

## 7. 升级与回滚

升级前确认工作区没有未保存的配置变更：

```bash
git status
git pull --ff-only
bash scripts/deploy.sh update
```

`update` 会先创建 PostgreSQL 备份，再拉取基础镜像、重建应用镜像并按 Compose 依赖重启。升级后检查：

```bash
bash scripts/deploy.sh status
bash scripts/deploy.sh logs web
```

回滚步骤：

1. 记录当前提交：`git rev-parse HEAD`；
2. 切回经过验证的发布标签或提交；
3. 重新执行 `bash scripts/deploy.sh up`；
4. 只有数据库迁移不向后兼容时，才从升级前备份恢复数据库。

不要使用 `docker compose down -v`，它会删除数据库、媒体文件和证书等持久卷。

## 8. 备份与恢复

### 8.1 数据库备份

```bash
bash scripts/deploy.sh backup
```

备份保存在 `backups/m-post-office-UTC时间.sql.gz`。生产环境还应备份以下 named volume：

- `m-post-office_media_data`：用户上传内容；
- `m-post-office_app_data`：Amavis 辅助数据库等应用数据；
- `m-post-office_caddy_data`：ACME 账户与证书（可重新申请，但备份能减少恢复时间）。

可以用主机或云平台的卷快照完成这些备份。数据库 dump 与卷快照应复制到异机/对象存储，并定期演练恢复。

### 8.2 数据库恢复

```bash
bash scripts/deploy.sh restore backups/m-post-office-20260101T000000Z.sql.gz
```

脚本会要求输入 `RESTORE`，随后停止应用服务、重建当前数据库、导入备份并重新启动。自动化灾备时可显式设置 `FORCE_RESTORE=1`，但只应在已经校验备份文件与目标环境后使用。

## 9. 已有反向代理

如果 80/443 已被宿主机代理占用，可在 `.env` 中把容器端口改为仅本机监听所需端口，并让现有代理转发：

```dotenv
SITE_ADDRESS=:80
PUBLIC_URL=https://mail.example.com
HTTP_PORT=127.0.0.1:8080
COOKIE_SECURE=true
DJANGO_CSRF_TRUSTED_ORIGINS=https://mail.example.com
```

Compose 的端口变量支持 `127.0.0.1:8080` 这类值。上游代理必须：

- 将 `https://mail.example.com` 转发到 `http://127.0.0.1:8080`；
- 保留 `Host`；
- 设置 `X-Forwarded-Proto: https`；
- 支持较大的附件上传和至少 120 秒的上游超时。

此模式下可以从 Compose 中移除/禁用 `gateway` 并直接代理 `web`，但那样还需要单独发布前端、静态和媒体路径；保留本机 Caddy 作为统一上游通常更简单。

## 10. 安全基线

- 只对公网开放 80/443；PostgreSQL、Redis 和 Gunicorn 仅在内部 Docker 网络；
- `.env` 与 OIDC 私钥权限保持 `0600`，服务器 SSH 禁止密码登录；
- 定期更新宿主机、Docker 和项目镜像；
- 管理员启用 2FA，日常不要共享初始管理员账号；
- SMTP 服务必须启用身份验证和 TLS，严禁开放中继；
- 在外层防火墙/WAF 配置速率限制和告警；
- 监控磁盘、PostgreSQL、容器重启次数、Caddy 证书和 RQ 队列积压；
- 定期执行 `docker compose ... run --rm web manage check --deploy`；
- 备份加密、异地保存并测试恢复。

## 11. 常见故障

### 网关无法签发证书

```bash
bash scripts/deploy.sh logs gateway
```

检查 DNS 是否已经生效、80/443 是否从公网可达、AAAA 是否指向真实可用的 IPv6，以及 `ACME_EMAIL`/`SITE_ADDRESS` 是否正确。

### `web` 一直 unhealthy

```bash
bash scripts/deploy.sh logs web
bash scripts/deploy.sh logs db
```

常见原因是 PostgreSQL 密码不一致、旧数据卷使用了不同用户、OIDC 私钥缺失或数据库迁移失败。不要直接删除卷；先备份并根据日志处理。

### 登录后 OAuth 回调失败

确认三项完全一致：

```dotenv
APP_DOMAIN=mail.example.com
DJANGO_ALLOWED_HOSTS=mail.example.com
DJANGO_CSRF_TRUSTED_ORIGINS=https://mail.example.com
```

然后重启 `web`，它会幂等更新 OAuth 回调地址：

```bash
bash scripts/deploy.sh restart
```

### Webmail 无法收信或发信

从 `web` 容器测试 DNS/端口，并核对 `.env` 的 IMAP/SMTP 主机、端口和加密模式。容器中的 `localhost` 指容器本身，不是 Docker 宿主机；宿主机邮件服务应使用可路由地址或明确的 Docker 网络地址。

### 修改 `.env` 后没有生效

`docker compose restart` 不会重新创建容器环境。使用：

```bash
docker compose --env-file .env -f docker-compose.prod.yml up -d --force-recreate
```

## 12. 开发 Docker 渠道

仓库根目录原有的 `docker-compose.yml` 继续用于开发，提供 Django 开发服务器、Vite 热更新、Redis、Radicale、Dovecot 以及可选的 LDAP/Amavis profile：

```bash
docker compose up --build
docker compose --profile ldap up --build
docker compose --profile amavis up --build
```

开发 Compose 使用测试配置、源码挂载和开发服务器，不应部署到公网。生产环境始终使用：

```bash
docker compose --env-file .env -f docker-compose.prod.yml ...
```
