#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.prod.yml"
SECRETS_DIR="$PROJECT_DIR/deploy/secrets"
BACKUP_DIR="$PROJECT_DIR/backups"

cd "$PROJECT_DIR"
export M_POST_OFFICE_ENV_FILE="${M_POST_OFFICE_ENV_FILE:-$ENV_FILE}"

if docker info >/dev/null 2>&1; then
  DOCKER=(docker)
elif [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  DOCKER=(sudo docker)
else
  DOCKER=(docker)
fi

compose() {
  "${DOCKER[@]}" compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

replace_env() {
  local key="$1" value="$2" temp
  temp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    index($0, key "=") == 1 { print key "=" value; found=1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$ENV_FILE" > "$temp"
  mv "$temp" "$ENV_FILE"
}

init() {
  need openssl
  if [[ ! -f "$ENV_FILE" ]]; then
    cp "$PROJECT_DIR/.env.example" "$ENV_FILE"
    replace_env DJANGO_SECRET_KEY "$(openssl rand -hex 48)"
    replace_env POSTGRES_PASSWORD "$(openssl rand -hex 32)"
    replace_env ADMIN_PASSWORD "$(openssl rand -hex 24)"
    echo "Created $ENV_FILE with random application, database and admin secrets."
  else
    echo "$ENV_FILE already exists; leaving it unchanged."
  fi

  mkdir -p "$SECRETS_DIR" "$BACKUP_DIR"
  if [[ ! -s "$SECRETS_DIR/oidc_private_key.pem" ]]; then
    openssl genpkey -algorithm RSA \
      -pkeyopt rsa_keygen_bits:4096 \
      -out "$SECRETS_DIR/oidc_private_key.pem"
    echo "Generated the OIDC signing key."
  fi
  chmod 600 "$SECRETS_DIR/oidc_private_key.pem" "$ENV_FILE"

  echo "Initialization complete. Edit .env, replace example domains, then run:"
  echo "  ./scripts/deploy.sh doctor"
  echo "  ./scripts/deploy.sh up"
}

doctor() {
  need docker
  "${DOCKER[@]}" compose version >/dev/null
  [[ -f "$ENV_FILE" ]] || { echo "Run './scripts/deploy.sh init' first." >&2; exit 1; }
  [[ -s "$SECRETS_DIR/oidc_private_key.pem" ]] || { echo "OIDC key is missing; run init." >&2; exit 1; }

  if grep -Eq '(^|[.=])example\.(com|net|org)([:/]|$)|CHANGE_ME' "$ENV_FILE"; then
    echo ".env still contains example domains or CHANGE_ME values." >&2
    exit 1
  fi
  compose config --quiet
  echo "Docker, configuration and secrets look ready."
}

up() {
  doctor
  compose build --pull
  compose up -d --remove-orphans
  compose ps
}

update() {
  doctor
  backup
  compose build --pull
  compose up -d --remove-orphans
  compose ps
}

backup() {
  mkdir -p "$BACKUP_DIR"
  local stamp target
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  target="$BACKUP_DIR/m-post-office-$stamp.sql.gz"
  compose exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' | gzip -9 > "$target"
  echo "Database backup written to $target"
}

restore() {
  local source_file="${1:-}"
  [[ -n "$source_file" && -f "$source_file" ]] || {
    echo "Usage: ./scripts/deploy.sh restore backups/file.sql.gz" >&2
    exit 1
  }
  if [[ "${FORCE_RESTORE:-0}" != "1" ]]; then
    read -r -p "This replaces the current database. Type RESTORE to continue: " answer
    [[ "$answer" == "RESTORE" ]] || { echo "Restore cancelled."; exit 1; }
  fi
  compose stop web worker scheduler
  compose exec -T db sh -c 'dropdb -U "$POSTGRES_USER" --if-exists "$POSTGRES_DB" && createdb -U "$POSTGRES_USER" "$POSTGRES_DB"'
  gzip -dc "$source_file" | compose exec -T db sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" "$POSTGRES_DB"'
  compose up -d web worker scheduler gateway
  echo "Database restored from $source_file"
}

case "${1:-help}" in
  init) init ;;
  doctor) doctor ;;
  up) up ;;
  update) update ;;
  backup) backup ;;
  restore) shift; restore "${1:-}" ;;
  down) compose down ;;
  restart) compose restart ;;
  status) compose ps ;;
  logs) shift; compose logs -f --tail=200 "$@" ;;
  config) compose config ;;
  *)
    cat <<'USAGE'
M Post Office deployment helper

Usage: ./scripts/deploy.sh COMMAND

  init                Create .env and the OIDC signing key
  doctor              Validate Docker, configuration and secrets
  up                  Build and start the production stack
  update              Back up, rebuild and perform a rolling restart
  backup              Create a compressed PostgreSQL dump
  restore FILE        Replace the database from a .sql.gz backup
  status              Show container health and state
  logs [SERVICE]      Follow logs (optionally one service)
  restart             Restart all services
  down                 Stop containers without deleting persistent volumes
  config               Render the effective Compose configuration
USAGE
    ;;
esac
