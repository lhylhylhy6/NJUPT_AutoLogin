#!/usr/bin/env bash
set -euo pipefail

APP_NAME="campus-login-check"
INSTALL_BIN="/usr/local/sbin/$APP_NAME"
SERVICE_FILE="/etc/systemd/system/$APP_NAME.service"
TIMER_FILE="/etc/systemd/system/$APP_NAME.timer"
NM_DISPATCHER_FILE="/etc/NetworkManager/dispatcher.d/90-$APP_NAME"
INSTALL_LIB_DIR="/usr/local/libexec/$APP_NAME"

die() {
    echo "Error: $*" >&2
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "sudo is required"
    exec sudo -E bash "$0" "$@"
fi

default_user=""
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    default_user="$SUDO_USER"
fi

systemctl disable --now "$APP_NAME.timer" >/dev/null 2>&1 || true
systemctl stop "$APP_NAME.service" >/dev/null 2>&1 || true
rm -f "$SERVICE_FILE" "$TIMER_FILE" "$INSTALL_BIN" "$NM_DISPATCHER_FILE"
rm -f "$INSTALL_LIB_DIR/njupt-portal-login.py"
rmdir "$INSTALL_LIB_DIR" 2>/dev/null || true
systemctl daemon-reload

echo "Removed systemd units, binary, and NetworkManager hook."

if [ -n "$default_user" ]; then
    target_home="$(getent passwd "$default_user" | cut -d: -f6 || true)"
    config_dir="$target_home/.config/campus-login"
    state_dir="$target_home/.local/state/campus-login"
    if [ -d "$config_dir" ] || [ -d "$state_dir" ]; then
        read -r -p "Remove user config and logs for $default_user? [y/N]: " remove_data
        case "${remove_data:-N}" in
            y|Y|yes|YES)
                rm -rf "$config_dir" "$state_dir"
                echo "Removed user config and logs."
                ;;
            *)
                echo "Kept user config and logs."
                ;;
        esac
    fi
fi
