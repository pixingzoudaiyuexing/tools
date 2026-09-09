#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=scripts/realm.sh
. "$ROOT/scripts/realm.sh"

[[ "$(realm_asset_name x86_64 glibc)" == 'realm-x86_64-unknown-linux-gnu-glibc2.28.tar.gz' ]]
[[ "$(realm_asset_name amd64 glibc)" == 'realm-x86_64-unknown-linux-gnu-glibc2.28.tar.gz' ]]
[[ "$(realm_asset_name x86_64 musl)" == 'realm-x86_64-unknown-linux-musl.tar.gz' ]]
[[ "$(realm_asset_name aarch64 glibc)" == 'realm-aarch64-unknown-linux-gnu-glibc2.28.tar.gz' ]]
[[ "$(realm_asset_name arm64 musl)" == 'realm-aarch64-unknown-linux-musl.tar.gz' ]]
[[ "$(realm_asset_name armv7l glibc)" == 'realm-armv7-unknown-linux-gnueabihf-glibc2.28.tar.gz' ]]
if realm_asset_name sparc glibc >/dev/null 2>&1; then
    printf '未知架构不应猜测 Realm Release 文件名。\n' >&2
    exit 1
fi

ensure_download_environment() { return 0; }
curl() { printf '{"tag_name":"v2.9.6"}\n'; }
[[ "$(realm_latest_release_tag)" == 'v2.9.6' ]]

SCRIPT="$ROOT/scripts/realm.sh"
grep -q 'realm-x86_64-unknown-linux-gnu-glibc2.28.tar.gz' "$SCRIPT"
grep -q 'realm-aarch64-unknown-linux-gnu-glibc2.28.tar.gz' "$SCRIPT"
grep -q 'https://api.github.com/repos/zhboner/realm/releases/latest' "$SCRIPT"
grep -q 'https://github.com/zhboner/realm/releases/download' "$SCRIPT"

if grep -nE '(apt|apt-get|dnf|yum|apk).*(libc6|glibc)|glibc.*(install|upgrade)' "$SCRIPT" >/dev/null; then
    printf 'Realm 模块不应升级系统 glibc / libc6。\n' >&2
    exit 1
fi
if grep -Eq 'wcwq98|wcwq99|raw\.githubusercontent\.com/.*/realm.*\.sh' "$SCRIPT"; then
    printf 'Realm 模块仍存在第三方脚本依赖。\n' >&2
    exit 1
fi

printf 'Realm 官方 Release / libc 构建选择测试通过。\n'
