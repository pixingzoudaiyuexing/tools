#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export VPS_TOOLS_CA_BUNDLE="$TEST_DIR/ca-certificates.crt"
CALLS="$TEST_DIR/calls"
: >"$CALLS"

is_root() { return 0; }
require_debian_ubuntu() { return 0; }
is_debian_ubuntu_system() { return 0; }
command_exists() {
    if [[ "$1" == "curl" ]]; then
        [[ -f "$TEST_DIR/curl-ready" ]]
    else
        command -v "$1" >/dev/null 2>&1
    fi
}
apt-get() {
    printf 'apt-get %s\n' "$*" >>"$CALLS"
    if [[ "$*" == "install -y curl" ]]; then
        : >"$TEST_DIR/curl-ready"
    fi
    return 0
}
update-ca-certificates() {
    printf 'update-ca-certificates %s\n' "$*" >>"$CALLS"
    : >"$VPS_TOOLS_CA_BUNDLE"
    return 0
}

repair_download_environment >/dev/null

grep -Fq 'apt-get update' "$CALLS"
grep -Fq 'apt-get install --reinstall -y openssl ca-certificates' "$CALLS"
grep -Fq 'apt-get install -y curl' "$CALLS"
grep -Fq 'update-ca-certificates --fresh' "$CALLS"
[[ -f "$TEST_DIR/curl-ready" ]]
[[ -s "$VPS_TOOLS_CA_BUNDLE" || -f "$VPS_TOOLS_CA_BUNDLE" ]]

before="$(wc -l <"$CALLS")"
ensure_download_environment
[[ "$(wc -l <"$CALLS")" -eq "$before" ]]

grep -Fq 'apt-get update' "$ROOT/tools.sh"
grep -Fq 'apt update' "$ROOT/README.md"

printf '下载/CA 环境修复测试通过。\n'
