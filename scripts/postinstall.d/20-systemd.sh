#!/usr/bin/env bash
set -euo pipefail

if ! command -v systemctl >/dev/null 2>&1; then
    printf '[20-systemd] systemd not available, skipping service setup.\n'
    exit 0
fi

APP_DIR="${APP_DIR:-/opt/vpn-admin}"
TEMPLATE_PATH="${APP_DIR}/scripts/templates/vpn-admin.service.tpl"
SERVICE_PATH="/etc/systemd/system/vpn-admin.service"

if [[ ! -f "$TEMPLATE_PATH" ]]; then
    printf '[20-systemd] Template %s not found, skipping.\n' "$TEMPLATE_PATH"
    exit 0
fi

SERVICE_USER="${SERVICE_USER:-root}"
SERVICE_GROUP="${SERVICE_GROUP:-$SERVICE_USER}"
BIND_ADDRESS="${BIND_ADDRESS:-127.0.0.1}"
APP_PORT="${APP_PORT:-55151}"

export APP_DIR SERVICE_USER SERVICE_GROUP BIND_ADDRESS APP_PORT

printf '[20-systemd] Deploying vpn-admin.service (user %s, bind %s:%s).\n' "$SERVICE_USER" "$BIND_ADDRESS" "$APP_PORT"
envsubst '${APP_DIR} ${SERVICE_USER} ${SERVICE_GROUP} ${BIND_ADDRESS} ${APP_PORT}' \
    <"$TEMPLATE_PATH" >"$SERVICE_PATH"

chmod 644 "$SERVICE_PATH"

systemctl daemon-reload
systemctl enable --now vpn-admin.service
systemctl status vpn-admin.service --no-pager
