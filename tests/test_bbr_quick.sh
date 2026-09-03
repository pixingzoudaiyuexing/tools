#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=scripts/bbr.sh
. "$ROOT/scripts/bbr.sh"

BBR_SYSCTL_FILE="$TMP/99-vps-tools-bbr-fq.conf"
TEST_CC="cubic"
TEST_QDISC="fq_codel"

require_root() { return 0; }
title() { :; }
pause() { :; }
modprobe() { return 0; }
command_exists() { [[ "$1" == "modprobe" ]]; }
bbr_available_cc() { printf 'reno cubic bbr\n'; }
bbr_current_cc() { printf '%s\n' "$TEST_CC"; }
bbr_current_qdisc() { printf '%s\n' "$TEST_QDISC"; }
sysctl() {
    if [[ "${1:-}" == "-w" ]]; then
        case "${2:-}" in
            net.core.default_qdisc=*) TEST_QDISC="${2#*=}" ;;
            net.ipv4.tcp_congestion_control=*) TEST_CC="${2#*=}" ;;
            *) return 1 ;;
        esac
        return 0
    fi
    return 1
}

bbr_quick_enable >/dev/null
[[ "$TEST_CC" == "bbr" ]]
[[ "$TEST_QDISC" == "fq" ]]
grep -qx 'net.core.default_qdisc = fq' "$BBR_SYSCTL_FILE"
grep -qx 'net.ipv4.tcp_congestion_control = bbr' "$BBR_SYSCTL_FILE"

rm -f "$BBR_SYSCTL_FILE"
bbr_available_cc() { printf 'reno cubic\n'; }
if bbr_quick_enable >/dev/null 2>&1; then
    printf '当前内核不支持 BBR 时不应返回成功。\n' >&2
    exit 1
fi
[[ ! -e "$BBR_SYSCTL_FILE" ]]

grep -q '快速开启 BBR + FQ' "$ROOT/scripts/bbr.sh"
grep -q '99-vps-tools-bbr-fq.conf' "$ROOT/scripts/bbr.sh"
if grep -nE 'apt(-get)? .*linux-image|grub-install|update-grub' "$ROOT/scripts/bbr.sh" | grep -v 'BBRv3' >/dev/null; then
    printf '快速 BBR 模块不应自行安装或切换内核。\n' >&2
    exit 1
fi

printf 'BBR + FQ 快捷开启测试通过。\n'
