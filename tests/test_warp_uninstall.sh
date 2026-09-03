#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=scripts/warp.sh
. "$ROOT/scripts/warp.sh"

require_root() { return 0; }
confirm() { return 0; }
warp_known_artifacts_exist() { return 0; }
warp_stop_monitor() { :; }
warp_remove_official_package() { printf 'package-cleanup\n' >>"$TEST_DIR/actions"; }
warp_uninstall_remaining() { return 0; }
warp_environment() { printf 'environment-check\n' >>"$TEST_DIR/actions"; }
get_cloudflare_warp_state() { printf 'off\n'; }
command_exists() { return 1; }
sleep() { :; }
rm() { printf 'rm %s\n' "$*" >>"$TEST_DIR/actions"; }
sed() { printf 'sed %s\n' "$*" >>"$TEST_DIR/actions"; }

warp_uninstall_all >/dev/null

grep -Fq 'package-cleanup' "$TEST_DIR/actions"
grep -Fq '/usr/local/bin/warp-go' "$TEST_DIR/actions"
grep -Fq '/etc/wireguard/wgcf.conf' "$TEST_DIR/actions"
grep -Fq '/usr/bin/warp-cli' "$TEST_DIR/actions"
grep -Fq '/root/warpip' "$TEST_DIR/actions"
grep -Fq 'environment-check' "$TEST_DIR/actions"

grep -Fq '3. 一键卸载所有 WARP' "$ROOT/scripts/warp.sh"
grep -Fq 'cloudflare-warp' "$ROOT/scripts/warp.sh"
grep -Fq '不会卸载通用 wireguard-tools' "$ROOT/scripts/warp.sh"
! grep -Eq 'apt(-get)?[^\n]*(remove|purge)[^\n]*wireguard-tools|yum[^\n]*remove[^\n]*wireguard-tools|dnf[^\n]*remove[^\n]*wireguard-tools' "$ROOT/scripts/warp.sh"
! grep -Eq 'nft[[:space:]]+flush[[:space:]]+ruleset|iptables[[:space:]]+-F|ip6tables[[:space:]]+-F' "$ROOT/scripts/warp.sh"

printf 'test_warp_uninstall: PASS\n'
