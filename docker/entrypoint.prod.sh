#!/bin/sh
set -eu

cd /app/test_project

wait_for_database() {
  attempts=0
  until python -c '
import os
import socket

host = os.environ.get("POSTGRES_HOST", "db")
port = int(os.environ.get("POSTGRES_PORT", "5432"))
socket.create_connection((host, port), 3).close()
' >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 60 ]; then
      echo "Database did not become ready in time." >&2
      exit 1
    fi
    sleep 2
  done
}

case "${1:-web}" in
  web)
    wait_for_database
    python manage.py migrate --noinput
    python manage.py load_initial_data \
      --name "${APP_NAME:-M Post Office}" \
      --admin-username "${ADMIN_USERNAME:-admin}" \
      --relative-urls-in-config
    python manage.py set_default_site "${APP_DOMAIN:-localhost}"
    python manage.py shell -c \
      'import os; from django.contrib.auth import get_user_model; u=get_user_model().objects.get(username=os.environ.get("ADMIN_USERNAME", "admin")); u.set_password(os.environ["ADMIN_PASSWORD"]); u.save(update_fields=["password"])'
    python manage.py collectstatic --noinput --clear

    mkdir -p /var/www/frontend
    find /var/www/frontend -mindepth 1 -delete
    cp -aL /app/test_project/frontend/. /var/www/frontend/

    exec gunicorn test_project.wsgi:application \
      --bind 0.0.0.0:8000 \
      --workers "${GUNICORN_WORKERS:-3}" \
      --threads "${GUNICORN_THREADS:-2}" \
      --timeout "${GUNICORN_TIMEOUT:-120}" \
      --access-logfile - \
      --error-logfile -
    ;;
  worker)
    wait_for_database
    exec python manage.py rqworker dkim modoboa dovecot
    ;;
  scheduler)
    wait_for_database
    exec python manage.py rqcron test_project/cron_config.py
    ;;
  manage)
    shift
    wait_for_database
    exec python manage.py "$@"
    ;;
  *)
    exec "$@"
    ;;
esac
