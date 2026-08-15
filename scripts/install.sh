#!/usr/bin/env bash
set -Eeuo pipefail

# M Post Office one-click installer for Ubuntu, Debian, RHEL-compatible and
# Fedora servers. It is safe to run again: existing secrets and volumes remain.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"
export M_POST_OFFICE_ENV_FILE="$ENV_FILE"

DOMAIN=""
ACME_EMAIL_VALUE=""
ADMIN_USER_VALUE="admin"
IMAP_HOST_VALUE=""
SMTP_HOST_VALUE=""
SMTP_USER_VALUE=""
SMTP_PASSWORD_VALUE=""
DOVEADM_URL_VALUE=""
DOVEADM_KEY_VALUE=""
LOCAL_MODE=0
NON_INTERACTIVE=0
INSTALL_DOCKER=1
CONFIGURE_FIREWALL=1

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
M Post Office 一键安装脚本

用法：
  sudo bash scripts/install.sh
  sudo bash scripts/install.sh --domain mail.example.com --email ops@example.com

参数：
  --domain DOMAIN          Web 访问域名
  --email EMAIL            ACME/运维邮箱
  --admin-user USER        初始管理员用户名，默认 admin
  --imap-host HOST         IMAP 主机，默认与 --domain 相同
  --smtp-host HOST         SMTP 主机，默认与 --domain 相同
  --smtp-user USER         SMTP 认证用户名，可留空
  --smtp-password PASS     SMTP 认证密码，可留空
  --doveadm-url URL        Dovecot doveadm REST 地址，可留空
  --doveadm-key KEY        doveadm API 密钥；未提供时自动生成
  --local                  仅在 localhost:8080 上进行 HTTP 测试
  --non-interactive        不提问；必须提供 domain/email，或使用 --local
  --skip-docker-install    Docker 缺失时直接退出
  --skip-firewall          不修改 UFW/firewalld
  -h, --help               显示帮助
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --email) ACME_EMAIL_VALUE="${2:-}"; shift 2 ;;
    --admin-user) ADMIN_USER_VALUE="${2:-}"; shift 2 ;;
    --imap-host) IMAP_HOST_VALUE="${2:-}"; shift 2 ;;
    --smtp-host) SMTP_HOST_VALUE="${2:-}"; shift 2 ;;
    --smtp-user) SMTP_USER_VALUE="${2:-}"; shift 2 ;;
    --smtp-password) SMTP_PASSWORD_VALUE="${2:-}"; shift 2 ;;
    --doveadm-url) DOVEADM_URL_VALUE="${2:-}"; shift 2 ;;
    --doveadm-key) DOVEADM_KEY_VALUE="${2:-}"; shift 2 ;;
    --local) LOCAL_MODE=1; shift ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --skip-docker-install) INSTALL_DOCKER=0; shift ;;
    --skip-firewall) CONFIGURE_FIREWALL=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（使用 --help 查看帮助）" ;;
  esac
done

[[ "$(uname -s)" == "Linux" ]] || die "一键安装只支持 Linux；Windows/macOS 请按 DEPLOYMENT.md 使用 Docker Desktop。"
[[ -f "$PROJECT_DIR/docker-compose.prod.yml" ]] || die "请在 M Post Office 仓库中运行本脚本。"

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  SUDO=()
elif command -v sudo >/dev/null 2>&1; then
  SUDO=(sudo)
else
  die "需要 root 权限安装系统依赖；请安装 sudo 或使用 root 运行。"
fi

run_root() { "${SUDO[@]}" "$@"; }

install_base_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    run_root apt-get update
    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
      ca-certificates curl gnupg openssl
  elif command -v dnf >/dev/null 2>&1; then
    run_root dnf install -y ca-certificates curl openssl
  elif command -v yum >/dev/null 2>&1; then
    run_root yum install -y ca-certificates curl openssl
  else
    die "不支持的包管理器。请手动安装 Docker、curl 和 openssl。"
  fi
}

install_docker_apt() {
  # shellcheck disable=SC1091
  . /etc/os-release
  local docker_distro="$ID" codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  case "$docker_distro" in
    ubuntu|debian) ;;
    *)
      if [[ "${ID_LIKE:-}" == *ubuntu* ]]; then docker_distro=ubuntu
      elif [[ "${ID_LIKE:-}" == *debian* ]]; then docker_distro=debian
      else die "当前 APT 发行版不在自动安装支持列表：$ID"; fi
      ;;
  esac
  [[ -n "$codename" ]] || die "无法识别发行版代号。"

  run_root install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/$docker_distro/gpg" \
    | run_root tee /etc/apt/keyrings/docker.asc >/dev/null
  run_root chmod a+r /etc/apt/keyrings/docker.asc

  local arch
  arch="$(dpkg --print-architecture)"
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
    "$arch" "$docker_distro" "$codename" \
    | run_root tee /etc/apt/sources.list.d/docker.list >/dev/null
  run_root apt-get update
  run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_rpm() {
  # shellcheck disable=SC1091
  . /etc/os-release
  local repo_os=centos
  [[ "$ID" == "fedora" ]] && repo_os=fedora
  if command -v dnf >/dev/null 2>&1; then
    run_root dnf install -y dnf-plugins-core
    run_root dnf config-manager --add-repo "https://download.docker.com/linux/$repo_os/docker-ce.repo"
    run_root dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    run_root yum install -y yum-utils
    run_root yum-config-manager --add-repo "https://download.docker.com/linux/$repo_os/docker-ce.repo"
    run_root yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker 与 Compose 已安装。"
  else
    [[ "$INSTALL_DOCKER" -eq 1 ]] || die "Docker/Compose 不可用，且指定了 --skip-docker-install。"
    info "正在安装 Docker Engine 与 Compose 插件……"
    install_base_packages
    if command -v apt-get >/dev/null 2>&1; then
      install_docker_apt
    else
      install_docker_rpm
    fi
  fi

  if ! run_root docker info >/dev/null 2>&1; then
    if command -v systemctl >/dev/null 2>&1; then
      run_root systemctl enable --now docker
    elif command -v service >/dev/null 2>&1; then
      run_root service docker start
    else
      die "Docker 已安装，但无法找到 systemctl/service 来启动守护进程。"
    fi
  fi
  if ! docker info >/dev/null 2>&1; then
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
      run_root usermod -aG docker "${SUDO_USER:-$USER}" || true
    fi
    run_root docker info >/dev/null || die "Docker 服务未能正常启动。"
  fi
  ok "Docker 服务运行正常。"
}

env_get() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || return 0
  awk -v key="$key" 'index($0, key "=") == 1 { sub("^[^=]*=", ""); gsub(/^"|"$/, ""); print; exit }' "$ENV_FILE"
}

env_set() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  if [[ -f "$ENV_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == "$key="* ]]; then
        printf '%s=%s\n' "$key" "$value"
      else
        printf '%s\n' "$line"
      fi
    done < "$ENV_FILE" > "$tmp"
    if ! grep -q "^${key}=" "$ENV_FILE"; then printf '%s=%s\n' "$key" "$value" >> "$tmp"; fi
  else
    printf '%s=%s\n' "$key" "$value" > "$tmp"
  fi
  mv "$tmp" "$ENV_FILE"
}

dotenv_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

prompt_default() {
  local prompt="$1" default="$2" secret="${3:-0}" reply
  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    printf '%s' "$default"
    return
  fi
  if [[ "$secret" -eq 1 ]]; then
    read -r -s -p "$prompt${default:+ [已设置]}: " reply
    printf '\n' >&2
  else
    read -r -p "$prompt${default:+ [$default]}: " reply
  fi
  printf '%s' "${reply:-$default}"
}

validate_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

collect_configuration() {
  [[ "$ADMIN_USER_VALUE" =~ ^[A-Za-z0-9_.@+-]+$ ]] || die "管理员用户名包含非法字符。"
  if [[ "$LOCAL_MODE" -eq 1 ]]; then
    DOMAIN=localhost
    ACME_EMAIL_VALUE="${ACME_EMAIL_VALUE:-admin@localhost}"
    IMAP_HOST_VALUE="${IMAP_HOST_VALUE:-localhost}"
    SMTP_HOST_VALUE="${SMTP_HOST_VALUE:-localhost}"
    return
  fi

  local old_domain old_email
  old_domain="$(env_get APP_DOMAIN)"
  [[ "$old_domain" == *.example.com ]] && old_domain=""
  old_email="$(env_get ACME_EMAIL)"
  [[ "$old_email" == *@example.com ]] && old_email=""

  [[ -n "$DOMAIN" ]] || DOMAIN="$(prompt_default 'Web 访问域名' "$old_domain")"
  [[ -n "$ACME_EMAIL_VALUE" ]] || ACME_EMAIL_VALUE="$(prompt_default 'ACME/运维邮箱' "$old_email")"

  [[ -n "$DOMAIN" ]] || die "必须提供域名。"
  validate_domain "$DOMAIN" || die "域名格式无效：$DOMAIN"
  [[ "$ACME_EMAIL_VALUE" == *@*.* ]] || die "邮箱格式无效：$ACME_EMAIL_VALUE"
  [[ -n "$IMAP_HOST_VALUE" ]] || IMAP_HOST_VALUE="$(prompt_default 'IMAP 主机' "$(env_get IMAP_HOST)")"
  [[ -n "$IMAP_HOST_VALUE" && "$IMAP_HOST_VALUE" != *.example.com ]] || IMAP_HOST_VALUE="$DOMAIN"

  [[ -n "$SMTP_HOST_VALUE" ]] || SMTP_HOST_VALUE="$(prompt_default 'SMTP 主机' "$(env_get SMTP_HOST)")"
  [[ -n "$SMTP_HOST_VALUE" && "$SMTP_HOST_VALUE" != *.example.com ]] || SMTP_HOST_VALUE="$DOMAIN"

  [[ -n "$SMTP_USER_VALUE" ]] || SMTP_USER_VALUE="$(env_get SMTP_USERNAME)"
  [[ -n "$SMTP_PASSWORD_VALUE" ]] || SMTP_PASSWORD_VALUE="$(env_get SMTP_PASSWORD)"
  [[ -n "$DOVEADM_URL_VALUE" ]] || DOVEADM_URL_VALUE="$(env_get DOVEADM_API_URL)"
  [[ -n "$DOVEADM_KEY_VALUE" ]] || DOVEADM_KEY_VALUE="$(env_get DOVEADM_API_KEY)"
  [[ "$DOVEADM_URL_VALUE" == *example.com* ]] && DOVEADM_URL_VALUE=""
  [[ "$DOVEADM_KEY_VALUE" == CHANGE_ME* ]] && DOVEADM_KEY_VALUE=""

  if [[ "$NON_INTERACTIVE" -eq 0 ]]; then
    SMTP_USER_VALUE="$(prompt_default 'SMTP 用户名（可留空）' "$SMTP_USER_VALUE")"
    SMTP_PASSWORD_VALUE="$(prompt_default 'SMTP 密码（可留空）' "$SMTP_PASSWORD_VALUE" 1)"
    DOVEADM_URL_VALUE="$(prompt_default 'doveadm REST URL（可留空）' "$DOVEADM_URL_VALUE")"
  fi
}

write_configuration() {
  info "生成应用密钥和环境文件……"
  bash "$SCRIPT_DIR/deploy.sh" init

  if [[ "$LOCAL_MODE" -eq 1 ]]; then
    env_set SITE_ADDRESS :80
    env_set APP_DOMAIN localhost
    env_set PUBLIC_URL http://localhost:8080
    env_set ACME_EMAIL "$ACME_EMAIL_VALUE"
    env_set HTTP_PORT 8080
    env_set DJANGO_ALLOWED_HOSTS localhost,127.0.0.1
    env_set DJANGO_CSRF_TRUSTED_ORIGINS http://localhost:8080
    env_set COOKIE_SECURE false
    env_set SECURE_HSTS_SECONDS 0
  else
    env_set SITE_ADDRESS "$DOMAIN"
    env_set APP_DOMAIN "$DOMAIN"
    env_set PUBLIC_URL "https://$DOMAIN"
    env_set ACME_EMAIL "$ACME_EMAIL_VALUE"
    env_set HTTP_PORT 80
    env_set HTTPS_PORT 443
    env_set DJANGO_ALLOWED_HOSTS "$DOMAIN"
    env_set DJANGO_CSRF_TRUSTED_ORIGINS "https://$DOMAIN"
    env_set COOKIE_SECURE true
    env_set SECURE_HSTS_SECONDS 31536000
  fi

  env_set ADMIN_USERNAME "$ADMIN_USER_VALUE"
  env_set IMAP_HOST "$IMAP_HOST_VALUE"
  env_set SMTP_HOST "$SMTP_HOST_VALUE"
  env_set SMTP_USERNAME "$(dotenv_quote "$SMTP_USER_VALUE")"
  env_set SMTP_PASSWORD "$(dotenv_quote "$SMTP_PASSWORD_VALUE")"
  env_set DEFAULT_FROM_EMAIL "$(dotenv_quote "M Post Office <postmaster@$DOMAIN>")"

  if [[ -n "$DOVEADM_URL_VALUE" ]]; then
    [[ "$DOVEADM_URL_VALUE" == https://* || "$DOVEADM_URL_VALUE" == http://127.0.0.1:* ]] \
      || die "doveadm URL 必须使用 HTTPS（仅本机 127.0.0.1 可使用 HTTP）。"
    [[ -n "$DOVEADM_KEY_VALUE" ]] || DOVEADM_KEY_VALUE="$(openssl rand -hex 32)"
    env_set DOVECOT_OPERATION_MODE rest
    env_set DOVEADM_API_URL "$DOVEADM_URL_VALUE"
    env_set DOVEADM_API_KEY "$DOVEADM_KEY_VALUE"
  else
    env_set DOVECOT_OPERATION_MODE cmd
    env_set DOVEADM_API_URL ""
    env_set DOVEADM_API_KEY ""
    warn "未配置 doveadm REST API；邮箱目录管理需要之后完成 Dovecot SQL/API 集成。"
  fi

  chmod 600 "$ENV_FILE" "$PROJECT_DIR/deploy/secrets/oidc_private_key.pem"
}

configure_firewall() {
  [[ "$LOCAL_MODE" -eq 0 ]] || { info "本机模式不修改防火墙。"; return; }
  [[ "$CONFIGURE_FIREWALL" -eq 1 ]] || { warn "已跳过防火墙配置。"; return; }
  if command -v ufw >/dev/null 2>&1 && run_root ufw status | grep -q '^Status: active'; then
    run_root ufw allow 80/tcp
    run_root ufw allow 443/tcp
    run_root ufw allow 443/udp
    ok "已添加 UFW Web/HTTP3 规则。"
  elif command -v firewall-cmd >/dev/null 2>&1 && run_root firewall-cmd --state >/dev/null 2>&1; then
    run_root firewall-cmd --permanent --add-service=http
    run_root firewall-cmd --permanent --add-service=https
    run_root firewall-cmd --permanent --add-port=443/udp
    run_root firewall-cmd --reload
    ok "已添加 firewalld Web/HTTP3 规则。"
  else
    warn "未检测到启用的 UFW/firewalld；请确认云安全组允许 80/tcp、443/tcp 和 443/udp。"
  fi
}

check_dns() {
  [[ "$LOCAL_MODE" -eq 1 ]] && return
  if getent ahosts "$DOMAIN" >/dev/null 2>&1; then
    ok "域名 $DOMAIN 可以解析。"
  else
    warn "域名 $DOMAIN 当前无法解析；Caddy 在 DNS 生效前无法签发证书。"
  fi
}

main() {
  cd "$PROJECT_DIR"
  info "M Post Office 一键安装开始。"
  ensure_docker
  command -v openssl >/dev/null 2>&1 || install_base_packages
  command -v openssl >/dev/null 2>&1 || die "openssl 安装失败。"
  collect_configuration
  write_configuration
  configure_firewall
  check_dns

  info "校验并构建生产环境；首次运行通常需要数分钟……"
  bash "$SCRIPT_DIR/deploy.sh" doctor
  bash "$SCRIPT_DIR/deploy.sh" up

  local public_url admin_password
  public_url="$(env_get PUBLIC_URL)"
  admin_password="$(env_get ADMIN_PASSWORD)"
  printf '\n'
  ok "M Post Office 安装完成。"
  printf '访问地址：%s\n管理员：%s\n初始密码：%s\n' \
    "$public_url" "$ADMIN_USER_VALUE" "$admin_password"
  printf '\n请立即安全保存密码，并使用以下命令查看状态：\n'
  printf '  bash scripts/deploy.sh status\n'
  printf '  bash scripts/deploy.sh logs web\n'
}

main "$@"
