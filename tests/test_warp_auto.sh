#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=scripts/warp.sh
. "$ROOT/scripts/warp.sh"

export WARP_CF_COMMAND="$TEST_DIR/cf"
backend="none"
warp_has_warp_go() { [[ "$backend" == "warp-go" || "$backend" == "both" ]]; }
warp_has_wgcf() { [[ "$backend" == "wgcf" || "$backend" == "both" ]]; }

# 全新机器默认自动选择 WARP-GO：纯 IPv4 补 IPv6 => 3 -> 1 -> 2。
backend="none"
rm -f "$WARP_CF_COMMAND"
[[ "$(warp_build_upstream_input 6)" == $'3\n1\n2' ]] || {
    printf '纯 IPv4 补 IPv6 的首次自动菜单序列错误。\n' >&2
    exit 1
}

# 全新机器纯 IPv6 补 IPv4 => 3 -> 1 -> 1。
[[ "$(warp_build_upstream_input 4)" == $'3\n1\n1' ]] || {
    printf '纯 IPv6 补 IPv4 的首次自动菜单序列错误。\n' >&2
    exit 1
}

# 已有 WGCF 且没有 cf 快捷命令时，保持 WGCF 后端。
backend="wgcf"
[[ "$(warp_build_upstream_input 6)" == $'2\n1\n2' ]] || {
    printf '已有 WGCF 时自动菜单序列错误。\n' >&2
    exit 1
}

# 已有 warp-go 且 cf 快捷命令确认为 warp-yg 时，直接进入方案一切换目标协议族。
backend="warp-go"
printf '#!/usr/bin/env bash\n# yonggekkk/warp-yg\n' >"$WARP_CF_COMMAND"
chmod +x "$WARP_CF_COMMAND"
[[ "$(warp_build_upstream_input 4)" == $'1\n1' ]] || {
    printf '已有 warp-go 时自动菜单序列错误。\n' >&2
    exit 1
}

# 同时存在两个 WARP 后端必须拒绝自动部署。
backend="both"
set +e
warp_build_upstream_input 4 >/dev/null
status=$?
set -e
[[ "$status" -eq 2 ]] || {
    printf 'warp-go 与 wgcf 冲突时应返回 2。\n' >&2
    exit 1
}

# 验证目标状态：原生 IPv4 + WARP IPv6。
backend="none"
warp_native_address() { [[ "$1" == 4 ]] && printf '198.51.100.10\n' || return 1; }
get_public_ip() { [[ "$1" == 4 ]] && printf '198.51.100.10\n' || printf '2001:db8::99\n'; }
get_cloudflare_warp_state() { [[ "$1" == 4 ]] && printf 'off\n' || printf 'on\n'; }
warp_target_matches 6 || {
    printf '原生 IPv4 + WARP IPv6 目标状态识别失败。\n' >&2
    exit 1
}

# 验证目标状态：原生 IPv6 + WARP IPv4。
warp_native_address() { [[ "$1" == 6 ]] && printf '2001:db8::10\n' || return 1; }
get_public_ip() { [[ "$1" == 4 ]] && printf '203.0.113.20\n' || printf '2001:db8::10\n'; }
get_cloudflare_warp_state() { [[ "$1" == 4 ]] && printf 'on\n' || printf 'off\n'; }
warp_target_matches 4 || {
    printf '原生 IPv6 + WARP IPv4 目标状态识别失败。\n' >&2
    exit 1
}

# 双栈机器不能误用“纯 IPv4/纯 IPv6”快捷项，而且不应调用上游安装。
require_root() { return 0; }
warp_native_address() { [[ "$1" == 4 ]] && printf '198.51.100.10\n' || printf '2001:db8::10\n'; }
called=0
warp_run_upstream_auto() { called=1; return 0; }
if warp_auto_add_family 6 >/dev/null 2>&1; then
    printf '双栈机器不应通过纯 IPv4 快捷项预检。\n' >&2
    exit 1
fi
[[ "$called" -eq 0 ]] || {
    printf '预检失败时不应调用 warp-yg。\n' >&2
    exit 1
}

# 自动化依赖的上游菜单关键文本发生变化时必须停止，而不是盲选编号。
cat >"$TEST_DIR/menu-ok" <<'EOF'
安装/切换WARP单栈IPV4
安装/切换WARP单栈IPV6
请输入数字【0-3】
EOF
warp_validate_upstream_menu "$TEST_DIR/menu-ok" 4
printf '完全不同的菜单\n' >"$TEST_DIR/menu-bad"
if warp_validate_upstream_menu "$TEST_DIR/menu-bad" 4; then
    printf '上游菜单变化时应拒绝自动部署。\n' >&2
    exit 1
fi

grep -Fq '1. 一键：纯 IPv4 机器添加 IPv6' "$ROOT/scripts/warp.sh"
grep -Fq '2. 一键：纯 IPv6 机器添加 IPv4' "$ROOT/scripts/warp.sh"

printf 'test_warp_auto: PASS\n'
