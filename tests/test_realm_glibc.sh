#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export REALM_BIN="$TEST_DIR/realm"
export REALM_CONFIG="$TEST_DIR/config.toml"
export REALM_SERVICE="realm-test"
export VPS_TOOLS_ETC="$TEST_DIR/etc"
printf '[network]\nno_tcp = false\nuse_udp = true\n' >"$REALM_CONFIG"

# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=scripts/realm.sh
. "$ROOT/scripts/realm.sh"

[[ "$(realm_compat_asset_name x86_64)" == 'realm-x86_64-unknown-linux-gnu-glibc2.28.tar.gz' ]]
[[ "$(realm_compat_asset_name amd64)" == 'realm-x86_64-unknown-linux-gnu-glibc2.28.tar.gz' ]]
[[ "$(realm_compat_asset_name aarch64)" == 'realm-aarch64-unknown-linux-gnu-glibc2.28.tar.gz' ]]

# 模拟用户实际遇到的动态链接器错误。
cat >"$REALM_BIN" <<'EOF'
#!/usr/bin/env bash
printf "/lib/x86_64-linux-gnu/libc.so.6: version 'GLIBC_2.38' not found (required by realm)\n" >&2
exit 1
EOF
chmod +x "$REALM_BIN"
realm_binary_glibc_incompatible || {
    printf '未识别 GLIBC_x.xx not found 错误。\n' >&2
    exit 1
}

# 正常可执行的 Realm 不应被误判。
cat >"$REALM_BIN" <<'EOF'
#!/usr/bin/env bash
printf 'realm 2.9.6\n'
EOF
chmod +x "$REALM_BIN"
if realm_binary_glibc_incompatible; then
    printf '正常 Realm 被误判为 glibc 不兼容。\n' >&2
    exit 1
fi

# Release tag 解析不能依赖 jq。
ensure_download_environment() { return 0; }
curl() { printf '{"tag_name":"v2.9.6"}\n'; }
[[ "$(realm_latest_release_tag)" == 'v2.9.6' ]]

# 快速添加预检若发现 glibc 不兼容，必须自动走兼容修复，而不是直接改配置。
require_root() { return 0; }
realm_service_installed() { return 0; }
restart_calls=0
realm_restart_service() {
    restart_calls=$((restart_calls + 1))
    return 1
}
realm_binary_glibc_incompatible() { return 0; }
repaired=0
realm_repair_glibc_compat() { repaired=1; return 0; }
realm_show_diagnostics() { :; }
realm_quick_ready >/dev/null
[[ "$repaired" -eq 1 ]] || {
    printf 'Realm 快速预检没有触发 glibc 自动修复。\n' >&2
    exit 1
}

# 静态安全检查：只替换 Realm 二进制，不升级系统 glibc/libc6。
grep -Fq 'realm-x86_64-unknown-linux-gnu-glibc2.28.tar.gz' "$ROOT/scripts/realm.sh"
grep -Fq '3. Realm glibc 兼容修复' "$ROOT/scripts/realm.sh"
grep -Fq 'https://api.github.com/repos/zhboner/realm/releases/latest' "$ROOT/scripts/realm.sh"
if grep -Eq 'apt(-get)?[^\n]*(install|upgrade)[^\n]*(libc6|glibc)|yum[^\n]*(install|upgrade)[^\n]*glibc|dnf[^\n]*(install|upgrade)[^\n]*glibc' "$ROOT/scripts/realm.sh"; then
    printf 'Realm 兼容修复不应升级系统 glibc/libc6。\n' >&2
    exit 1
fi

printf 'test_realm_glibc: PASS\n'
