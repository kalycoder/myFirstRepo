#!/usr/bin/env bash
set -euo pipefail

if ! command -v nginx >/dev/null 2>&1; then
    printf '[10-nginx] nginx not installed, skipping.\n'
    exit 0
fi

APP_DIR="${APP_DIR:-/opt/vpn-admin}"
TEMPLATE_PATH="${APP_DIR}/scripts/templates/nginx.conf.tpl"
SITE_AVAILABLE="/etc/nginx/sites-available/vpn-admin"
SITE_ENABLED="/etc/nginx/sites-enabled/vpn-admin"

if [[ ! -f "$TEMPLATE_PATH" ]]; then
    printf '[10-nginx] Template %s not found, skipping.\n' "$TEMPLATE_PATH"
    exit 0
fi

SERVER_NAME="${DOMAIN:-${SERVER_NAME:-_}}"
APP_PORT="${APP_PORT:-55151}"
SSL_DIR="${SSL_DIR:-/etc/nginx/ssl}"
SSL_CERT_PATH="${SSL_CERT_PATH:-${SSL_DIR}/vpn-admin.crt}"
SSL_KEY_PATH="${SSL_KEY_PATH:-${SSL_DIR}/vpn-admin.key}"

export SERVER_NAME APP_PORT SSL_CERT_PATH SSL_KEY_PATH

mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled "$SSL_DIR"

if [[ ! -f "$SSL_CERT_PATH" || ! -f "$SSL_KEY_PATH" ]]; then
    if command -v openssl >/dev/null 2>&1; then
        printf '[10-nginx] Generating self-signed certificate for %s.\n' "$SERVER_NAME"
        openssl req -x509 -nodes -newkey rsa:2048 \
            -subj "/CN=${SERVER_NAME:-localhost}" \
            -keyout "$SSL_KEY_PATH" \
            -out "$SSL_CERT_PATH" \
            -days "${SSL_DAYS:-3650}"
    else
        printf '[10-nginx] openssl not available; skipping certificate generation.\n'
    fi
fi

printf '[10-nginx] Rendering nginx vhost for %s (port %s).\n' "$SERVER_NAME" "$APP_PORT"
envsubst '${SERVER_NAME} ${APP_PORT} ${SSL_CERT_PATH} ${SSL_KEY_PATH}' <"$TEMPLATE_PATH" >"$SITE_AVAILABLE"

ln -sf "$SITE_AVAILABLE" "$SITE_ENABLED"

if [[ -e /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
fi

nginx -t
systemctl restart nginx
