#!/usr/bin/env bash
set -euo pipefail

APP_NAME="campus-login-check"
INSTALL_BIN="/usr/local/sbin/$APP_NAME"
SERVICE_FILE="/etc/systemd/system/$APP_NAME.service"
TIMER_FILE="/etc/systemd/system/$APP_NAME.timer"
NM_DISPATCHER_FILE="/etc/NetworkManager/dispatcher.d/90-$APP_NAME"
INSTALL_LIB_DIR="/usr/local/libexec/$APP_NAME"
INSTALL_HELPER="$INSTALL_LIB_DIR/njupt-portal-login.py"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

die() {
    echo "Error: $*" >&2
    exit 1
}

info() {
    printf '%s\n' "$*"
}

if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "sudo is required"
    exec sudo -E bash "$0" "$@"
fi

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"
}

prompt_default() {
    local prompt="$1"
    local default="$2"
    local value
    read -r -p "$prompt [$default]: " value
    printf '%s' "${value:-$default}"
}

prompt_required() {
    local prompt="$1"
    local value
    while true; do
        read -r -p "$prompt: " value
        if [ -n "$value" ]; then
            printf '%s' "$value"
            return 0
        fi
        echo "This value cannot be empty." >&2
    done
}

prompt_secret_twice() {
    local prompt="$1"
    local first second
    while true; do
        read -r -s -p "$prompt: " first
        printf '\n' >&2
        read -r -s -p "Confirm $prompt: " second
        printf '\n' >&2
        if [ -n "$first" ] && [ "$first" = "$second" ]; then
            printf '%s' "$first"
            return 0
        fi
        echo "Passwords were empty or did not match. Please try again." >&2
    done
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-Y}"
    local value
    while true; do
        read -r -p "$prompt [$default]: " value
        value="${value:-$default}"
        case "$value" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO) return 1 ;;
            *) echo "Please answer y or n." >&2 ;;
        esac
    done
}

normalize_interval() {
    local value="$1"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        value="${value}s"
    fi
    [[ "$value" =~ ^[0-9]+(s|sec|m|min|h|hr)$ ]] || die "invalid interval: $value"
    printf '%s' "$value"
}

sed_escape() {
    printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

write_env_file() {
    local env_file="$1"
    local owner="$2"
    local group="$3"
    local tmp
    tmp="$(mktemp)"
    umask 077
    {
        printf 'CAMPUS_USER_ACCOUNT=%q\n' "$CAMPUS_USER_ACCOUNT"
        printf 'CAMPUS_USER_PASSWORD=%q\n' "$CAMPUS_USER_PASSWORD"
        printf 'CAMPUS_PORTAL_URL=%q\n' "$CAMPUS_PORTAL_URL"
        printf 'CAMPUS_CONFIG_URL=%q\n' "$CAMPUS_CONFIG_URL"
        printf 'CAMPUS_LOGIN_URL=%q\n' "$CAMPUS_LOGIN_URL"
        printf 'CAMPUS_LOGIN_TIMEOUT=%q\n' "$CAMPUS_LOGIN_TIMEOUT"
        printf 'CAMPUS_PROBE_URL=%q\n' "$CAMPUS_PROBE_URL"
        printf 'CAMPUS_PROBE_EXPECT=%q\n' "$CAMPUS_PROBE_EXPECT"
        printf 'CAMPUS_CONFIRM_URLS=%q\n' "$CAMPUS_CONFIRM_URLS"
        printf 'CAMPUS_FAIL_THRESHOLD=%q\n' "$CAMPUS_FAIL_THRESHOLD"
        printf 'CAMPUS_COOLDOWN_SECONDS=%q\n' "$CAMPUS_COOLDOWN_SECONDS"
        printf 'CAMPUS_MAX_COOLDOWN_SECONDS=%q\n' "$CAMPUS_MAX_COOLDOWN_SECONDS"
        printf 'CAMPUS_AFTER_LOGIN_DELAY=%q\n' "$CAMPUS_AFTER_LOGIN_DELAY"
        printf 'CAMPUS_CONNECT_TIMEOUT=%q\n' "$CAMPUS_CONNECT_TIMEOUT"
        printf 'CAMPUS_MAX_TIME=%q\n' "$CAMPUS_MAX_TIME"
    } > "$tmp"
    install -o "$owner" -g "$group" -m 0600 "$tmp" "$env_file"
    rm -f "$tmp"
}

render_template() {
    local src="$1"
    local dst="$2"
    local mode="$3"
    local owner="$4"
    local group="$5"
    local tmp
    tmp="$(mktemp)"
    sed \
        -e "s/__USER__/$(sed_escape "$TARGET_USER")/g" \
        -e "s/__GROUP__/$(sed_escape "$TARGET_GROUP")/g" \
        -e "s/__HOME__/$(sed_escape "$TARGET_HOME")/g" \
        -e "s/__ENV_FILE__/$(sed_escape "$ENV_FILE")/g" \
        -e "s/__INTERVAL__/$(sed_escape "$CHECK_INTERVAL")/g" \
        -e "s/__WATCH_IFACES__/$(sed_escape "$WATCH_IFACES")/g" \
        "$src" > "$tmp"
    install -o "$owner" -g "$group" -m "$mode" "$tmp" "$dst"
    rm -f "$tmp"
}

detect_default_user() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        printf '%s' "$SUDO_USER"
    elif [ -n "${USER:-}" ] && [ "$USER" != "root" ]; then
        printf '%s' "$USER"
    else
        printf '%s' ""
    fi
}

detect_default_iface() {
    ip route show default 2>/dev/null | awk 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

need_cmd bash
need_cmd curl
need_cmd flock
need_cmd systemctl
need_cmd install
need_cmd sed
need_cmd awk
need_cmd mktemp
need_cmd python3

[ -r "$SCRIPT_DIR/bin/campus-login-check" ] || die "missing bin/campus-login-check"
[ -r "$SCRIPT_DIR/lib/njupt-portal-login.py" ] || die "missing lib/njupt-portal-login.py"
[ -r "$SCRIPT_DIR/systemd/campus-login-check.service.in" ] || die "missing service template"
[ -r "$SCRIPT_DIR/systemd/campus-login-check.timer.in" ] || die "missing timer template"

default_user="$(detect_default_user)"
if [ -n "$default_user" ]; then
    TARGET_USER="$(prompt_default "Run service as Linux user" "$default_user")"
else
    TARGET_USER="$(prompt_required "Run service as Linux user")"
fi

id "$TARGET_USER" >/dev/null 2>&1 || die "user does not exist: $TARGET_USER"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ] || die "cannot find home directory for $TARGET_USER"

ENV_DIR="$TARGET_HOME/.config/campus-login"
STATE_DIR="$TARGET_HOME/.local/state/campus-login"
ENV_FILE="$ENV_DIR/env"

info ""
info "Campus account configuration"
CAMPUS_USER_ACCOUNT="$(prompt_required "Campus user account, e.g. xxx, xxx@cmcc, or xxx@njxy")"
CAMPUS_USER_PASSWORD="$(prompt_secret_twice "Campus password")"
CAMPUS_PORTAL_URL="$(prompt_default "Campus portal page URL" "https://p.njupt.edu.cn/")"
CAMPUS_LOGIN_URL="$(prompt_default "Campus login API URL" "https://p.njupt.edu.cn:804/eportal/portal/login")"
CAMPUS_CONFIG_URL="${CAMPUS_LOGIN_URL%/login}/page/loadConfig"
CAMPUS_LOGIN_TIMEOUT="20"

info ""
info "Connectivity check configuration"
CAMPUS_PROBE_URL="$(prompt_default "Primary probe URL" "http://cp.cloudflare.com/generate_204")"
CAMPUS_PROBE_EXPECT="$(prompt_default "Expected HTTP status" "204")"
CAMPUS_CONFIRM_URLS="$(prompt_default "HTTPS confirmation URL(s), space separated" "https://www.baidu.com/favicon.ico https://www.qq.com/favicon.ico")"
CHECK_INTERVAL="$(normalize_interval "$(prompt_default "Check interval" "30s")")"
CAMPUS_FAIL_THRESHOLD="$(prompt_default "Consecutive failures before login" "2")"
CAMPUS_COOLDOWN_SECONDS="$(prompt_default "Login cooldown seconds" "60")"
CAMPUS_MAX_COOLDOWN_SECONDS="$(prompt_default "Maximum login cooldown seconds" "900")"
CAMPUS_AFTER_LOGIN_DELAY="$(prompt_default "Seconds to wait after login before recheck" "10")"
CAMPUS_CONNECT_TIMEOUT="$(prompt_default "Probe connect timeout seconds" "2")"
CAMPUS_MAX_TIME="$(prompt_default "Probe total timeout seconds" "5")"

[[ "$CAMPUS_PROBE_EXPECT" =~ ^[0-9]{3}$ ]] || die "expected HTTP status must be a 3-digit code"
[[ -n "$CAMPUS_CONFIRM_URLS" ]] || die "at least one confirmation URL is required"
[[ "$CAMPUS_FAIL_THRESHOLD" =~ ^[0-9]+$ ]] || die "failure threshold must be a number"
[[ "$CAMPUS_COOLDOWN_SECONDS" =~ ^[0-9]+$ ]] || die "cooldown must be a number"
[[ "$CAMPUS_MAX_COOLDOWN_SECONDS" =~ ^[0-9]+$ ]] || die "maximum cooldown must be a number"
[[ "$CAMPUS_AFTER_LOGIN_DELAY" =~ ^[0-9]+$ ]] || die "after-login delay must be a number"
[[ "$CAMPUS_CONNECT_TIMEOUT" =~ ^[0-9]+$ ]] || die "connect timeout must be a number"
[[ "$CAMPUS_MAX_TIME" =~ ^[0-9]+$ ]] || die "max time must be a number"
(( CAMPUS_MAX_COOLDOWN_SECONDS >= CAMPUS_COOLDOWN_SECONDS )) || die "maximum cooldown must be at least the login cooldown"

WATCH_IFACES=""
default_iface="$(detect_default_iface || true)"
if [ -d /etc/NetworkManager/dispatcher.d ] && [ -r "$SCRIPT_DIR/networkmanager/90-campus-login-check.in" ]; then
    if prompt_yes_no "Install optional NetworkManager hook for reconnect events" "Y"; then
        if [ -n "$default_iface" ]; then
            WATCH_IFACES="$(prompt_default "Network interface(s), space separated" "$default_iface")"
        else
            WATCH_IFACES="$(prompt_required "Network interface(s), space separated, e.g. wlan0 eth0")"
        fi
    fi
fi

info ""
info "Installing..."
install -d -o "$TARGET_USER" -g "$TARGET_GROUP" -m 0700 "$ENV_DIR"
install -d -o "$TARGET_USER" -g "$TARGET_GROUP" -m 0700 "$STATE_DIR"

if [ -f "$ENV_FILE" ]; then
    backup="$ENV_FILE.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$ENV_FILE" "$backup"
    chown "$TARGET_USER:$TARGET_GROUP" "$backup"
    chmod 0600 "$backup"
    info "Existing env backed up to: $backup"
fi

write_env_file "$ENV_FILE" "$TARGET_USER" "$TARGET_GROUP"
install -o root -g root -m 0755 "$SCRIPT_DIR/bin/campus-login-check" "$INSTALL_BIN"
install -d -o root -g root -m 0755 "$INSTALL_LIB_DIR"
install -o root -g root -m 0755 "$SCRIPT_DIR/lib/njupt-portal-login.py" "$INSTALL_HELPER"
render_template "$SCRIPT_DIR/systemd/campus-login-check.service.in" "$SERVICE_FILE" 0644 root root
render_template "$SCRIPT_DIR/systemd/campus-login-check.timer.in" "$TIMER_FILE" 0644 root root

if [ -n "$WATCH_IFACES" ]; then
    render_template "$SCRIPT_DIR/networkmanager/90-campus-login-check.in" "$NM_DISPATCHER_FILE" 0755 root root
else
    rm -f "$NM_DISPATCHER_FILE"
fi

systemctl daemon-reload
systemctl enable --now "$APP_NAME.timer" >/dev/null
systemctl start "$APP_NAME.service" || true

info ""
info "Installed successfully."
info "Timer status:"
systemctl --no-pager --full status "$APP_NAME.timer" | sed -n '1,12p' || true
info ""
info "Useful commands:"
info "  systemctl status $APP_NAME.timer"
info "  sudo journalctl -u $APP_NAME.service -f"
info "  tail -f $STATE_DIR/check.log"
