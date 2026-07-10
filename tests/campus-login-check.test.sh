#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/bin/campus-login-check"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local needle="$1"
    local file="$2"
    grep -Fq -- "$needle" "$file" || fail "expected '$needle' in $file"
}

write_config() {
    cat > "$TEST_DIR/env" <<'EOF'
CAMPUS_USER_ACCOUNT='test@cmcc'
CAMPUS_USER_PASSWORD='test-password'
CAMPUS_PROBE_URL='http://cp.cloudflare.com/generate_204'
CAMPUS_CONFIRM_URLS='https://www.baidu.com/favicon.ico https://www.qq.com/favicon.ico'
CAMPUS_FAIL_THRESHOLD='2'
CAMPUS_COOLDOWN_SECONDS='60'
CAMPUS_MAX_COOLDOWN_SECONDS='900'
CAMPUS_AFTER_LOGIN_DELAY='0'
CAMPUS_CONNECT_TIMEOUT='1'
CAMPUS_MAX_TIME='1'
EOF
}

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/state"
cat > "$TEST_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u

output='/dev/null'
url=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            output="$2"
            shift 2
            ;;
        *)
            url="$1"
            shift
            ;;
    esac
done
printf '%s\n' "$url" >> "$MOCK_CALLS"

case "${MOCK_MODE:-}" in
    confirmation)
        case "$url" in
            https://www.baidu.com/*)
                printf '200'
                ;;
            *)
                exit 7
                ;;
        esac
        ;;
    portal-failure)
        case "$url" in
            https://p.njupt.edu.cn:802/*)
                printf '{"result":0,"code":"AUTH_FAIL","msg":"invalid credentials"}' > "$output"
                printf '200'
                ;;
            *)
                exit 7
                ;;
        esac
        ;;
    *)
        exit 9
        ;;
esac
EOF
chmod +x "$TEST_DIR/bin/curl"

run_check() {
    PATH="$TEST_DIR/bin:$PATH" \
    CAMPUS_ENV_FILE="$TEST_DIR/env" \
    CAMPUS_STATE_DIR="$TEST_DIR/state" \
    CAMPUS_LOG_FILE="$TEST_DIR/check.log" \
    MOCK_CALLS="$TEST_DIR/calls.log" \
    "$CHECK_SCRIPT"
}

write_config
MOCK_MODE='confirmation' run_check
assert_contains 'LAST_STATUS=confirmed' "$TEST_DIR/state/state"
if grep -Fq 'p.njupt.edu.cn' "$TEST_DIR/calls.log"; then
    fail 'portal login ran even though HTTPS confirmation succeeded'
fi

rm -rf "$TEST_DIR/state"
mkdir -p "$TEST_DIR/state"
: > "$TEST_DIR/calls.log"
MOCK_MODE='portal-failure' run_check
MOCK_MODE='portal-failure' run_check
assert_contains 'LOGIN_FAILURES=1' "$TEST_DIR/state/state"
assert_contains 'portal HTTP 200; result=0, code=AUTH_FAIL, msg=invalid credentials' "$TEST_DIR/state/last_login_result"

printf 'PASS: campus-login-check tests\n'
