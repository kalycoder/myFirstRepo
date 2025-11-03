#!/usr/bin/env bash

set -euo pipefail

log() {
    printf '[+] %s\n' "$*"
}

warn() {
    printf '[!] %s\n' "$*" >&2
}

fatal() {
    printf '[x] %s\n' "$*" >&2
    exit 1
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        fatal "Run this script as root (tip: prefix with sudo)."
    fi
}

ensure_supported_os() {
    if [[ ! -r /etc/os-release ]]; then
        fatal "Cannot determine operating system (missing /etc/os-release)."
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    case "${ID,,}" in
        debian|ubuntu|linuxmint|pop)
            ;;
        *)
            fatal "Unsupported distribution: ${ID} (expected Debian or Ubuntu family)."
            ;;
    esac
}

detect_local_repo() {
    local source_path="${BASH_SOURCE[0]:-}"
    if [[ -n "$source_path" && -f "$source_path" ]]; then
        # Resolve .. relative to scripts/bootstrap.sh
        local base_dir
        base_dir="$(cd "$(dirname "$source_path")/.." && pwd)"
        if [[ -d "$base_dir/.git" ]]; then
            printf '%s\n' "$base_dir"
            return 0
        fi
    fi
    return 1
}

install_base_packages() {
    export DEBIAN_FRONTEND=noninteractive
    log "Updating apt cache..."
    apt-get update -y

    local packages=(
        git
        curl
        wget
        python3
        python3-venv
        python3-pip
        nginx
        ufw
        gettext-base
        openssl
    )

    log "Installing required packages: ${packages[*]}"
    apt-get install -y "${packages[@]}"
}

prepare_source_tree() {
    local local_repo="${1:-}"
    local use_local="${2:-0}"
    local repo_url="${3}"
    local branch="${4}"
    local target_dir="${5}"

    if [[ "$use_local" == "1" ]]; then
        if [[ -z "$local_repo" ]]; then
            fatal "USE_LOCAL_SOURCE=1 but no local git repository detected."
        fi
        APP_DIR="$local_repo"
        SRC_DIR="$local_repo"
        log "Using existing working tree at ${SRC_DIR}"
        return
    fi

    [[ -z "$repo_url" ]] && fatal "REPO_URL is empty. Export REPO_URL before running."

    if [[ "$repo_url" == "https://github.com/CHANGE_ME/admin-panel.git" ]]; then
        fatal "Update REPO_URL to point at your published repository."
    fi

    mkdir -p "$(dirname "$target_dir")"

    if [[ -d "$target_dir/.git" ]]; then
        log "Repository already present; updating ${target_dir}"
        git -C "$target_dir" fetch --all --quiet
        git -C "$target_dir" checkout "$branch"
        git -C "$target_dir" pull --ff-only origin "$branch"
    else
        if [[ -d "$target_dir" && -n "$(ls -A "$target_dir" 2>/dev/null)" ]]; then
            fatal "Target directory ${target_dir} exists and is not a git repository; remove or set APP_DIR."
        fi
        [[ -d "$target_dir" ]] && rmdir "$target_dir" 2>/dev/null || true
        log "Cloning ${repo_url} (branch ${branch}) into ${target_dir}"
        git clone --branch "$branch" --depth 1 "$repo_url" "$target_dir"
    fi

    SRC_DIR="$target_dir"
}

ensure_python_dependencies() {
    local app_dir="${1}"
    local venv_path="${app_dir}/.venv"

    if [[ ! -d "$venv_path" ]]; then
        log "Creating Python virtual environment in ${venv_path}"
        python3 -m venv "$venv_path"
    fi

    log "Upgrading pip inside virtual environment"
    "${venv_path}/bin/pip" install --upgrade pip wheel >/dev/null

    if [[ -f "${app_dir}/requirements.txt" ]]; then
        log "Installing Python requirements"
        "${venv_path}/bin/pip" install -r "${app_dir}/requirements.txt"
    else
        warn "No requirements.txt found in ${app_dir}; skipping dependency install."
    fi

    # Ensure gunicorn is available even if not listed in requirements.
    "${venv_path}/bin/pip" install --upgrade gunicorn >/dev/null
}

generate_admin_config() {
    local app_dir="${1}"
    local vpn_type="${2}"
    local admin_user="${3}"
    local admin_pass_hash="${4}"

    local module_path="${app_dir}/${vpn_type}.py"
    if [[ ! -f "$module_path" ]]; then
        fatal "VPN implementation ${vpn_type}.py not found in ${app_dir}"
    fi

    local config_path="${app_dir}/app/config.py"
    local backup_suffix
    if [[ -f "$config_path" ]]; then
        backup_suffix="$(date '+%Y%m%d%H%M%S')"
        cp "$config_path" "${config_path}.${backup_suffix}.bak"
        log "Backed up existing config.py to config.py.${backup_suffix}.bak"
    fi

    log "Creating admin configuration at ${config_path}"
    ADMIN_USER="$admin_user" ADMIN_PASS_HASH="$admin_pass_hash" VPN_TYPE="$vpn_type" CONFIG_PATH="$config_path" \
        python3 - <<'PY'
import os
from pathlib import Path

admin_user = os.environ["ADMIN_USER"]
admin_pass_hash = os.environ["ADMIN_PASS_HASH"]
vpn_type = os.environ["VPN_TYPE"]
config_path = Path(os.environ["CONFIG_PATH"])

config_path.write_text(
    f"import {vpn_type} as vpn\n"
    "creds = {\n"
    f'    "username": "{admin_user}",\n'
    f'    "password": "{admin_pass_hash}",\n'
    "}\n",
    encoding="utf-8",
)
PY
}

sync_admin_credentials() {
    local app_dir="${1}"
    local admin_user="${2}"
    local admin_pass_hash="${3}"

    local python_bin="${app_dir}/.venv/bin/python"
    if [[ ! -x "$python_bin" ]]; then
        warn "Virtualenv Python binary not found at ${python_bin}; skipping DB sync."
        return
    fi

    log "Synchronising admin credentials with database"
    (
        cd "$app_dir"
        PYTHONPATH="$app_dir" ADMIN_USER="$admin_user" ADMIN_PASS_HASH="$admin_pass_hash" "$python_bin" - <<'PY'
import os

from app.models import Session, AdminCredentials, init_db

admin_user = os.environ["ADMIN_USER"]
admin_pass_hash = os.environ["ADMIN_PASS_HASH"]

init_db()

session = Session()
admin = session.query(AdminCredentials).first()
if admin:
    admin.username = admin_user
    admin.password = admin_pass_hash
else:
    admin = AdminCredentials(username=admin_user, password=admin_pass_hash)
    session.add(admin)
session.commit()
session.close()
PY
    )
}

detect_public_ip() {
    local ip
    ip="$(curl -4fsSL https://api.ipify.org || true)"
    if [[ -n "$ip" ]]; then
        printf '%s\n' "$ip"
        return
    fi
    ip="$(curl -4fsSL https://ifconfig.me || true)"
    if [[ -n "$ip" ]]; then
        printf '%s\n' "$ip"
        return
    fi
    printf ''
}

install_openvpn() {
    if [[ "${INSTALL_OPENVPN:-1}" != "1" ]]; then
        log "Skipping OpenVPN installation (INSTALL_OPENVPN=${INSTALL_OPENVPN:-0})."
        return
    fi

    if [[ -f /etc/openvpn/server/server.conf ]]; then
        log "OpenVPN appears to be installed already; skipping installer."
        return
    fi

    local installer_url="${OPENVPN_INSTALLER_URL:-https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh}"
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' RETURN

    log "Downloading OpenVPN installer from ${installer_url}"
    curl -fsSL "$installer_url" -o "${tmp_dir}/openvpn-install.sh"
    chmod +x "${tmp_dir}/openvpn-install.sh"

    local endpoint="${ENDPOINT:-${DOMAIN:-$(detect_public_ip)}}"
    if [[ -z "$endpoint" ]]; then
        warn "Failed to detect public IP; OpenVPN installer may prompt for endpoint."
    fi

    export AUTO_INSTALL="${AUTO_INSTALL:-y}"
    export APPROVE_INSTALL="${APPROVE_INSTALL:-y}"
    export APPROVE_IP="${APPROVE_IP:-y}"
    export ENDPOINT="$endpoint"
    export IPV6_SUPPORT="${IPV6_SUPPORT:-n}"
    export PORT_CHOICE="${PORT_CHOICE:-1}"
    export PROTOCOL_CHOICE="${PROTOCOL_CHOICE:-1}"
    export DNS="${DNS:-1}"
    export COMPRESSION_ENABLED="${COMPRESSION_ENABLED:-n}"
    export CUSTOMIZE_ENC="${CUSTOMIZE_ENC:-n}"
    export CLIENT="${OPENVPN_BOOTSTRAP_CLIENT:-bootstrap-client}"
    export PASS="${PASS:-1}"

    log "Running OpenVPN installer in unattended mode"
    bash "${tmp_dir}/openvpn-install.sh"

    trap - RETURN
    rm -rf "$tmp_dir"

    if [[ "${REMOVE_BOOTSTRAP_CLIENT:-1}" == "1" ]]; then
        remove_bootstrap_client "${OPENVPN_BOOTSTRAP_CLIENT:-bootstrap-client}"
    fi
}

configure_openvpn_logging() {
    local candidates=(
        "/etc/openvpn/server.conf"
        "/etc/openvpn/server/server.conf"
    )
    local server_conf=""
    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" ]]; then
            server_conf="$candidate"
            break
        fi
    done
    if [[ -z "$server_conf" ]]; then
        return
    fi

    log "Configuring OpenVPN to minimise logging"

    if grep -qE '^\s*log\s+' "$server_conf"; then
        sed -i 's|^\s*log\s\+.*|log /dev/null|' "$server_conf"
    else
        echo "log /dev/null" >>"$server_conf"
    fi

    if grep -qE '^\s*status\s+' "$server_conf"; then
        sed -i 's|^\s*status\s\+.*|status /dev/null|' "$server_conf"
    else
        echo "status /dev/null" >>"$server_conf"
    fi

    systemctl restart openvpn@server >/dev/null 2>&1 || systemctl restart openvpn >/dev/null 2>&1 || true
}

configure_ufw() {
    if [[ "${CONFIGURE_UFW:-0}" != "1" ]]; then
        log "Skipping UFW configuration (CONFIGURE_UFW=${CONFIGURE_UFW:-0})."
        return
    fi

    if ! command -v ufw >/dev/null 2>&1; then
        warn "ufw is not installed; skipping firewall configuration."
        return
    fi

    local vpn_port="${VPN_PORT:-1194}"
    local vpn_proto="${VPN_PROTO:-udp}"

    log "Configuring uncomplicated firewall (ufw)"
    ufw allow 22/tcp || true
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
    ufw allow "${vpn_port}/${vpn_proto}" || true

    if [[ "${ENABLE_UFW:-0}" == "1" ]]; then
        ufw --force enable
    else
        warn "UFW rules added but firewall not enabled (set ENABLE_UFW=1 to force)."
    fi
}

run_postinstall_hooks() {
    local hooks_dir="${1}"
    if [[ ! -d "$hooks_dir" ]]; then
        return
    fi

    local executed=0
    shopt -s nullglob
    for hook in "${hooks_dir}/"*.sh; do
        log "Running post-install hook $(basename "$hook")"
        chmod +x "$hook"
        APP_DIR="$APP_DIR" SRC_DIR="$SRC_DIR" "$hook"
        executed=1
    done
    shopt -u nullglob

    if [[ "$executed" -eq 0 ]]; then
        log "No post-install hooks found in ${hooks_dir}"
    fi
}

remove_bootstrap_client() {
    local client_name="${1}"
    if [[ -z "$client_name" ]]; then
        return
    fi

    local easyrsa_dir="/etc/openvpn/easy-rsa"
    local index_file="${easyrsa_dir}/pki/index.txt"

    if [[ ! -f "$index_file" ]]; then
        rm -f "/root/${client_name}.ovpn"
        return
    fi

    if ! grep -q "/CN=${client_name}$" "$index_file"; then
        rm -f "/root/${client_name}.ovpn"
        return
    fi

    log "Removing bootstrap OpenVPN client ${client_name}"
    if [[ -x "${easyrsa_dir}/easyrsa" ]]; then
        (
            cd "$easyrsa_dir" || exit 0
            ./easyrsa --batch revoke "$client_name" >/dev/null 2>&1 || true
            EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl >/dev/null 2>&1 || true
        )
        cp "${easyrsa_dir}/pki/crl.pem" /etc/openvpn/crl.pem 2>/dev/null || true
        chmod 644 /etc/openvpn/crl.pem 2>/dev/null || true
    fi

    sed -i "/^${client_name},.*/d" /etc/openvpn/ipp.txt 2>/dev/null || true
    rm -f "/root/${client_name}.ovpn"
    systemctl restart openvpn@server >/dev/null 2>&1 || systemctl restart openvpn >/dev/null 2>&1 || true
}

configure_journald() {
    if [[ "${CONFIGURE_JOURNALD:-1}" != "1" ]]; then
        return
    fi

    local journald_conf="/etc/systemd/journald.conf"
    log "Configuring systemd-journald to use volatile storage"
    sed -i 's|^#\?Storage=.*|Storage=volatile|' "$journald_conf"
    sed -i 's|^#\?SystemMaxUse=.*|SystemMaxUse=0|' "$journald_conf" || echo "SystemMaxUse=0" >>"$journald_conf"
    sed -i 's|^#\?RuntimeMaxUse=.*|RuntimeMaxUse=1M|' "$journald_conf" || echo "RuntimeMaxUse=1M" >>"$journald_conf"
    systemctl restart systemd-journald
}

disable_rsyslog() {
    if systemctl list-unit-files | grep -q '^rsyslog.service'; then
        log "Disabling rsyslog service"
        systemctl disable --now rsyslog >/dev/null 2>&1 || true
    fi
}

install_log_cleanup_cron() {
    local cron_path="/etc/cron.daily/vpn-admin-logwipe"
    log "Installing daily log cleanup job at ${cron_path}"
    cat >"$cron_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
truncate -s0 /var/log/auth.log 2>/dev/null || true
truncate -s0 /var/log/syslog 2>/dev/null || true
truncate -s0 /var/log/wtmp 2>/dev/null || true
truncate -s0 /var/log/lastlog 2>/dev/null || true
truncate -s0 /var/log/apt/history.log 2>/dev/null || true
truncate -s0 /var/log/apt/term.log 2>/dev/null || true
truncate -s0 /var/log/dpkg.log 2>/dev/null || true
EOF
    chmod +x "$cron_path"
}

main() {
    require_root
    ensure_supported_os
    install_base_packages

    local local_repo
    local_repo="$(detect_local_repo || true)"

    local repo_url_default="$(
        if [[ -n "$local_repo" ]]; then
            git -C "$local_repo" config --get remote.origin.url || true
        fi
    )"

    REPO_URL="${REPO_URL:-$repo_url_default}"
    BRANCH="${BRANCH:-main}"
    APP_DIR="${APP_DIR:-/opt/vpn-admin}"
    SRC_DIR="${SRC_DIR:-}"
    USE_LOCAL_SOURCE="${USE_LOCAL_SOURCE:-0}"
    VPN_TYPE="${VPN_TYPE:-openvpn}"
    ADMIN_USER="Administrator"
    ADMIN_PASS="${ADMIN_PASS:-}"
    GENERATED_PASSWORD=0
    OPENVPN_BOOTSTRAP_CLIENT="${OPENVPN_BOOTSTRAP_CLIENT:-bootstrap-client}"
    REMOVE_BOOTSTRAP_CLIENT="${REMOVE_BOOTSTRAP_CLIENT:-1}"

    if [[ -z "$ADMIN_PASS" ]]; then
        log "ADMIN_PASS not provided; generating a random password."
        ADMIN_PASS="$(python3 - <<'PY'
import secrets
import string

alphabet = string.ascii_letters + string.digits
print(''.join(secrets.choice(alphabet) for _ in range(24)))
PY
)"
        GENERATED_PASSWORD=1
    fi

    prepare_source_tree "$local_repo" "$USE_LOCAL_SOURCE" "$REPO_URL" "$BRANCH" "$APP_DIR"

    ensure_python_dependencies "$APP_DIR"
    ADMIN_PASS_HASH="$(ADMIN_PASS="$ADMIN_PASS" python3 - <<'PY'
import hashlib
import os
print(hashlib.sha256(os.environ["ADMIN_PASS"].encode("utf-8")).hexdigest())
PY
)"

    generate_admin_config "$APP_DIR" "$VPN_TYPE" "$ADMIN_USER" "$ADMIN_PASS_HASH"
    sync_admin_credentials "$APP_DIR" "$ADMIN_USER" "$ADMIN_PASS_HASH"

    install_openvpn
    configure_ufw
    run_postinstall_hooks "${APP_DIR}/scripts/postinstall.d"
    configure_openvpn_logging
    configure_journald
    disable_rsyslog
    install_log_cleanup_cron

    log "Bootstrap complete."
    printf '\n%-20s %s\n' "Application path:" "$APP_DIR"
    printf '%-20s %s\n' "Admin user:" "$ADMIN_USER"
    printf '%-20s %s\n' "Admin password:" "$ADMIN_PASS"
    if [[ "$GENERATED_PASSWORD" -eq 1 ]]; then
        printf '%-20s %s\n' "Note:" "Store this password securely."
    fi
    printf '%-20s %s\n' "VPN type:" "$VPN_TYPE"
}

main "$@"
