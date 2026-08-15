"""Production settings used by the M Post Office Docker deployment."""

import os
from pathlib import Path

from .settings import *  # noqa: F401,F403


def _csv(name: str, default: str = "") -> list[str]:
    return [value.strip() for value in os.environ.get(name, default).split(",") if value.strip()]


def _required(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"Required environment variable {name} is not set")
    return value


def _read_secret(name: str, default_path: str) -> str:
    value = os.environ.get(name)
    if value:
        return value.replace("\\n", "\n")
    path = Path(os.environ.get(f"{name}_FILE", default_path))
    if not path.is_file():
        raise RuntimeError(f"Required secret {name} was not found at {path}")
    return path.read_text(encoding="utf-8")


DEBUG = False
SECRET_KEY = _required("DJANGO_SECRET_KEY")
ALLOWED_HOSTS = _csv("DJANGO_ALLOWED_HOSTS", os.environ.get("APP_DOMAIN", "localhost"))
CSRF_TRUSTED_ORIGINS = _csv("DJANGO_CSRF_TRUSTED_ORIGINS")
MODOBOA_PUBLIC_URL = _required("PUBLIC_URL")

DATABASES["default"] = {  # noqa: F405
    "ENGINE": "django.db.backends.postgresql",
    "NAME": os.environ.get("POSTGRES_DB", "m_post_office"),
    "USER": os.environ.get("POSTGRES_USER", "m_post_office"),
    "PASSWORD": _required("POSTGRES_PASSWORD"),
    "HOST": os.environ.get("POSTGRES_HOST", "db"),
    "PORT": os.environ.get("POSTGRES_PORT", "5432"),
    "ATOMIC_REQUESTS": True,
    "CONN_MAX_AGE": int(os.environ.get("DB_CONN_MAX_AGE", "60")),
    "OPTIONS": {"client_encoding": "UTF8"},
}

# The optional Amavis frontend uses its own database. Keeping it on a persistent
# SQLite file preserves the upstream schema without requiring a second server.
DATABASES["amavis"]["NAME"] = "/app/var/data/amavis.db"  # noqa: F405

STATIC_ROOT = "/app/var/static"
MEDIA_ROOT = "/app/var/media"
FILE_UPLOAD_PERMISSIONS = 0o640

REDIS_HOST = os.environ.get("REDIS_HOST", "redis")
REDIS_PORT = int(os.environ.get("REDIS_PORT", "6379"))
REDIS_URL = f"redis://{REDIS_HOST}:{REDIS_PORT}/0"
for queue in RQ_QUEUES.values():  # noqa: F405
    queue["URL"] = REDIS_URL

CACHES = {
    "default": {
        "BACKEND": "django.core.cache.backends.redis.RedisCache",
        "LOCATION": "redis://redis:6379/1",
    }
}

OIDC_RSA_PRIVATE_KEY = _read_secret("OIDC_RSA_PRIVATE_KEY", "/run/secrets/oidc_private_key")
OAUTH2_PROVIDER = {**OAUTH2_PROVIDER, "OIDC_RSA_PRIVATE_KEY": OIDC_RSA_PRIVATE_KEY}  # noqa: F405

SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
USE_X_FORWARDED_HOST = True
CSRF_COOKIE_SECURE = os.environ.get("COOKIE_SECURE", "true").lower() == "true"
SESSION_COOKIE_SECURE = CSRF_COOKIE_SECURE
SECURE_CONTENT_TYPE_NOSNIFF = True
SECURE_REFERRER_POLICY = "same-origin"
SECURE_HSTS_SECONDS = int(os.environ.get("SECURE_HSTS_SECONDS", "31536000"))
SECURE_HSTS_INCLUDE_SUBDOMAINS = True

CORS_ORIGIN_ALLOW_ALL = False
CORS_ALLOWED_ORIGINS = CSRF_TRUSTED_ORIGINS

EMAIL_BACKEND = "django.core.mail.backends.smtp.EmailBackend"
EMAIL_HOST = os.environ.get("SMTP_HOST", "localhost")
EMAIL_PORT = int(os.environ.get("SMTP_PORT", "587"))
EMAIL_HOST_USER = os.environ.get("SMTP_USERNAME", "")
EMAIL_HOST_PASSWORD = os.environ.get("SMTP_PASSWORD", "")
EMAIL_USE_TLS = os.environ.get("SMTP_USE_TLS", "true").lower() == "true"
DEFAULT_FROM_EMAIL = os.environ.get("DEFAULT_FROM_EMAIL", "M Post Office <postmaster@localhost>")
SERVER_EMAIL = DEFAULT_FROM_EMAIL

EMAIL_CLIENT_CONNECTION_SETTINGS = {
    "imap": {
        "HOSTNAME": os.environ.get("IMAP_HOST", "localhost"),
        "SOCKET_TYPE": os.environ.get("IMAP_SOCKET_TYPE", "SSL"),
        "PORT": int(os.environ.get("IMAP_PORT", "993")),
    },
    "smtp": {
        "HOSTNAME": os.environ.get("SMTP_HOST", "localhost"),
        "SOCKET_TYPE": os.environ.get("SMTP_SOCKET_TYPE", "STARTTLS"),
        "PORT": int(os.environ.get("SMTP_PORT", "587")),
    },
}

DOVECOT_OPERATION_MODE = os.environ.get("DOVECOT_OPERATION_MODE", "rest")
DOVEADM_API_URL = os.environ.get("DOVEADM_API_URL", "")
DOVEADM_API_KEY = os.environ.get("DOVEADM_API_KEY", "")
DOVEADM_API_TIMEOUT = int(os.environ.get("DOVEADM_API_TIMEOUT", "10"))

MODOBOA_CUSTOM_LOGO = "/sitestatic/css/m-post-office-white.svg"
SPECTACULAR_SETTINGS = {  # noqa: F405
    **SPECTACULAR_SETTINGS,
    "TITLE": "M Post Office API",
    "SERVERS": [{"url": f"https://{ALLOWED_HOSTS[0]}", "description": "M Post Office"}],
}

# Containers log to stdout/stderr. Avoid relying on a host /dev/log socket.
for logger_name in ("modoboa.auth", "modoboa.admin", "modoboa.dns", "modoboa.jobs"):
    LOGGING["loggers"][logger_name]["handlers"] = ["console"]  # noqa: F405

DISABLE_DASHBOARD_EXTERNAL_QUERIES = True
