#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export VPS_TOOLS_ETC="$TEST_DIR/vps-tools"
export REALM_CONFIG="$TEST_DIR/etc/realm/config.toml"
export REALM_BIN="$TEST_DIR/usr/local/bin/realm"
export REALM_SERVICE_FILE="$TEST_DIR/etc/systemd/system/realm.service"
export REALM_LEGACY_CONFIG="$TEST_DIR/root/.realm/config.toml"
export REALM_LEGACY_BIN="$TEST_DIR/root/realm/realm"

# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=scripts/realm.sh
. "$ROOT/scripts/realm.sh"

[[ "$(realm_target_type '2607:5300:60:2288:29::a')" == "IPv6" ]]
[[ "$(realm_target_type '1.1.1.1')" == "IPv4" ]]
[[ "$(realm_target_type 'example.com')" == "域名" ]]
[[ "$(realm_format_remote '2607:5300:60:2288:29::a' 50036)" == '[2607:5300:60:2288:29::a]:50036' ]]
[[ "$(realm_format_remote '[2607:5300:60:2288:29::a]' 50036)" == '[2607:5300:60:2288:29::a]:50036' ]]
[[ "$(realm_listen_address 1 54545)" == '0.0.0.0:54545' ]]
[[ "$(realm_listen_address 2 54545)" == '[::]:54545' ]]
[[ "$(realm_listen_address 3 54545)" == '[::]:54545' ]]

mkdir -p "$(dirname "$REALM_CONFIG")"
cat >"$REALM_CONFIG" <<'CFG'
[network]
no_tcp = false
use_udp = true

[[endpoints]]
listen = "0.0.0.0:54545"
remote = "[2607:5300:60:2288:29::a]:50036"

[[endpoints]]
listen = "[::]:60000"
remote = "1.1.1.1:443"
[endpoints.network]
ipv6_only = false

[log]
level = "warn"
CFG

[[ "$(realm_rule_count)" == "2" ]]
realm_port_in_config 54545
realm_port_in_config 60000
if realm_port_in_config 12345; then
    printf '不存在的 Realm 端口被误判为已存在。\n' >&2
    exit 1
fi

RULES="$(realm_rule_lines)"
grep -q '^1|0.0.0.0:54545|\[2607:5300:60:2288:29::a\]:50036$' <<<"$RULES"
grep -q '^2|\[::\]:60000|1.1.1.1:443$' <<<"$RULES"

CANDIDATE="$TEST_DIR/candidate.toml"
realm_build_config_without_rule "$REALM_CONFIG" 2 "$CANDIDATE"
grep -q '0.0.0.0:54545' "$CANDIDATE"
if grep -q '\[::\]:60000' "$CANDIDATE"; then
    printf '删除 Realm 规则时目标 endpoint 未被删除。\n' >&2
    exit 1
fi
grep -q '^\[log\]$' "$CANDIDATE"
grep -q '^level = "warn"$' "$CANDIDATE"

APPEND="$TEST_DIR/append.toml"
cp "$REALM_CONFIG" "$APPEND"
realm_append_endpoint "$APPEND" 2 '[::]:61000' '[2001:db8::1]:443'
grep -q 'listen = "\[::\]:61000"' "$APPEND"
grep -A1 '^\[endpoints.network\]$' "$APPEND" | grep -q 'ipv6_only = false'

# 旧配置只迁移到新标准路径，不沿用旧二进制。
rm -f "$REALM_CONFIG"
mkdir -p "$(dirname "$REALM_LEGACY_CONFIG")"
cat >"$REALM_LEGACY_CONFIG" <<'LEGACY'
[network]
no_tcp = false
use_udp = true
[[endpoints]]
listen = "0.0.0.0:10000"
remote = "1.1.1.1:443"
LEGACY
realm_prepare_config >/dev/null
cmp -s "$REALM_LEGACY_CONFIG" "$REALM_CONFIG"

realm_write_service_file
grep -q "^ExecStart=${REALM_BIN} -c ${REALM_CONFIG}$" "$REALM_SERVICE_FILE"
grep -q '^Restart=on-failure$' "$REALM_SERVICE_FILE"

SCRIPT="$ROOT/scripts/realm.sh"
grep -q 'zhboner/realm' "$SCRIPT"
grep -q '/usr/local/bin/realm' "$SCRIPT"
grep -q '/etc/realm/config.toml' "$SCRIPT"
if grep -Eq 'wcwq98|wcwq99|REALM_UPSTREAM_URL|run_remote_bash' "$SCRIPT"; then
    printf 'Realm 模块不应再依赖第三方管理脚本。\n' >&2
    exit 1
fi

printf 'Realm 官方自维护 IPv4 / IPv6 与迁移测试通过。\n'
