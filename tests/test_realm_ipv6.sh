#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export REALM_CONFIG="$TEST_DIR/config.toml"
export REALM_BIN="$TEST_DIR/realm"
export REALM_SERVICE="realm-test"
export VPS_TOOLS_ETC="$TEST_DIR/etc"

cat >"$REALM_CONFIG" <<'EOF'
[network]
no_tcp = false
use_udp = true
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$REALM_BIN"
chmod +x "$REALM_BIN"

# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=scripts/realm.sh
. "$ROOT/scripts/realm.sh"

[[ "$(realm_format_remote '2001:db8::1234' 443)" == '[2001:db8::1234]:443' ]]
[[ "$(realm_format_remote '[2001:db8::1234]' 443)" == '[2001:db8::1234]:443' ]]
[[ "$(realm_format_remote '203.0.113.8' 443)" == '203.0.113.8:443' ]]
[[ "$(realm_format_remote 'node.example.com' 443)" == 'node.example.com:443' ]]
[[ "$(realm_target_type '2001:db8::1234')" == 'IPv6' ]]
[[ "$(realm_target_type '203.0.113.8')" == 'IPv4' ]]
[[ "$(realm_target_type 'node.example.com')" == '域名' ]]

require_root() { return 0; }
pause() { :; }
confirm() { return 0; }
backup_file() { :; }
realm_service_installed() { return 0; }
realm_show_diagnostics() { :; }
ip() {
    case "$*" in
        '-4 -o addr show scope global') printf '2: ens3    inet 203.0.113.10/24 scope global ens3\n' ;;
        '-6 -o addr show scope global') printf '2: ens3    inet6 2001:db8::10/64 scope global\n' ;;
        *) return 0 ;;
    esac
}
realm_restart_service() { return 0; }

output="$(realm_quick_add <<'INPUT'
2443
2001:db8::20
443
INPUT
)"
grep -Fq 'Realm 原配置启动正常' <<<"$output"
grep -Fq '目标类型：IPv6' <<<"$output"
grep -Fq '转发链路：双栈中转 → IPv6 落地' <<<"$output"
grep -Fq '已自动规范化 IPv6：[2001:db8::20]:443' <<<"$output"
grep -Fq 'listen = "[::]:2443"' "$REALM_CONFIG"
grep -Fq 'remote = "[2001:db8::20]:443"' "$REALM_CONFIG"

# 原配置在修改前就启动失败时，不得修改配置。
cp "$REALM_CONFIG" "$TEST_DIR/preflight-before.toml"
realm_restart_service() { return 1; }
if realm_quick_add <<'INPUT' >/dev/null 2>&1
3000
2001:db8::25
443
INPUT
then
    printf 'Realm 预检失败测试意外返回成功。\n' >&2
    exit 1
fi
cmp -s "$REALM_CONFIG" "$TEST_DIR/preflight-before.toml"

# 新规则导致服务失败时必须恢复添加前的配置：第一次预检成功，第二次新配置失败，第三次回滚后成功。
cp "$REALM_CONFIG" "$TEST_DIR/before.toml"
restart_count=0
realm_restart_service() {
    restart_count=$((restart_count + 1))
    case "$restart_count" in
        1) return 0 ;;
        2) return 1 ;;
        *) return 0 ;;
    esac
}
if realm_quick_add <<'INPUT' >/dev/null 2>&1
3443
2001:db8::30
443
INPUT
then
    printf 'Realm 失败回滚测试意外返回成功。\n' >&2
    exit 1
fi
cmp -s "$REALM_CONFIG" "$TEST_DIR/before.toml"

printf 'test_realm_ipv6: PASS\n'
