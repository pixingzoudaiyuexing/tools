#!/usr/bin/env bash

SAKURA_SYSCTL="${SAKURA_SYSCTL:-/etc/sysctl.d/ipv6.conf}"
SAKURA_INTERFACES="${SAKURA_INTERFACES:-/etc/network/interfaces}"

sakura_check_system() {
    require_root || return 1
    [[ -r /etc/os-release ]] || return 1
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "12" ]] || { error "此功能只支持樱花 VPS 的 Debian 12。"; return 1; }
    [[ -f "$SAKURA_SYSCTL" && -f "$SAKURA_INTERFACES" ]] || { error "缺少樱花预置的 IPv6 配置文件。"; return 1; }
}

sakura_extract_ipv6() {
    local iface="$1"
    awk -v iface="$iface" '
        $0 ~ "^#[[:space:]]*iface[[:space:]]+" iface "[[:space:]]+inet6[[:space:]]+static" {inside=1; next}
        inside && $0 ~ "^#[[:space:]]*address[[:space:]]+" {line=$0; sub(/^#[[:space:]]*/, "", line); split(line, a, /[[:space:]]+/); print "address=" a[2]; next}
        inside && $0 ~ "^#[[:space:]]*netmask[[:space:]]+" {line=$0; sub(/^#[[:space:]]*/, "", line); split(line, a, /[[:space:]]+/); print "netmask=" a[2]; next}
        inside && $0 ~ "^#[[:space:]]*gateway[[:space:]]+" {line=$0; sub(/^#[[:space:]]*/, "", line); split(line, a, /[[:space:]]+/); print "gateway=" a[2]; next}
        inside && $0 !~ /^#[[:space:]]/ && $0 !~ /^[[:space:]]*$/ {inside=0}
    ' "$SAKURA_INTERFACES"
}

sakura_enable_block() {
    local iface="$1" output="$2"
    awk -v iface="$iface" '
        $0 ~ "^#[[:space:]]*iface[[:space:]]+" iface "[[:space:]]+inet6[[:space:]]+static" {
            line=$0; sub(/^#[[:space:]]*/, "", line); print line; inside=1; next
        }
        inside && $0 ~ "^#[[:space:]]*(address|netmask|gateway)[[:space:]]+" {
            line=$0; sub(/^#[[:space:]]*/, "", line); print line; next
        }
        inside && $0 !~ /^#[[:space:]]/ && $0 !~ /^[[:space:]]*$/ {inside=0}
        {print}
    ' "$SAKURA_INTERFACES" >"$output"
}

sakura_enable_sysctl() {
    local output="$1"
    awk '
        /^[[:space:]]*net\.ipv6\.conf\.all\.disable_ipv6[[:space:]]*=/ {print "net.ipv6.conf.all.disable_ipv6 = 0"; all=1; next}
        /^[[:space:]]*net\.ipv6\.conf\.default\.disable_ipv6[[:space:]]*=/ {print "net.ipv6.conf.default.disable_ipv6 = 0"; def=1; next}
        {print}
        END {if (!all || !def) exit 2}
    ' "$SAKURA_SYSCTL" >"$output"
}

sakura_verify() {
    local iface="$1" public_ipv6
    printf '[IPv6 地址]\n'
    ip -6 address show dev "$iface" scope global || true
    printf '\n[IPv6 默认路由]\n'
    ip -6 route show default || true
    public_ipv6="$(get_public_ip 6)"
    printf '\n公网 IPv6：%s\n' "${public_ipv6:-未检测到}"
    [[ -n "$public_ipv6" ]]
}

sakura_enable() {
    local iface details address netmask gateway temp_sysctl temp_interfaces reboot_choice
    sakura_check_system || return 1
    iface="$(detect_default_interface 4)"
    [[ -n "$iface" ]] || { error "无法识别主网卡。"; return 1; }
    details="$(sakura_extract_ipv6 "$iface")"
    address="$(awk -F= '$1 == "address" {print $2}' <<<"$details")"
    netmask="$(awk -F= '$1 == "netmask" {print $2}' <<<"$details")"
    gateway="$(awk -F= '$1 == "gateway" {print $2}' <<<"$details")"
    [[ "$address" == *:* && "$gateway" == *:* && "$netmask" =~ ^[0-9]+$ ]] || { error "未在 $iface 的注释 IPv6 段中找到完整 address/netmask/gateway。"; return 1; }
    printf '主网卡：%s\nIPv6 地址：%s/%s\nIPv6 网关：%s\n' "$iface" "$address" "$netmask" "$gateway"
    confirm "确认启用这组樱花 VPS 预置 IPv6 配置？" || return 0
    backup_file "$SAKURA_SYSCTL" "$VPS_TOOLS_ETC/backups/sakura-ipv6" || return 1
    backup_file "$SAKURA_INTERFACES" "$VPS_TOOLS_ETC/backups/sakura-ipv6" || return 1
    temp_sysctl="$(mktemp)"; temp_interfaces="$(mktemp)" || return 1
    if ! sakura_enable_sysctl "$temp_sysctl"; then
        rm -f "$temp_sysctl" "$temp_interfaces"
        error "sysctl 文件缺少两项预期配置，未修改。"
        return 1
    fi
    sakura_enable_block "$iface" "$temp_interfaces" || { rm -f "$temp_sysctl" "$temp_interfaces"; return 1; }
    if ! grep -Eq "^[[:space:]]*iface[[:space:]]+${iface}[[:space:]]+inet6[[:space:]]+static" "$temp_interfaces"; then
        rm -f "$temp_sysctl" "$temp_interfaces"; error "IPv6 段生成失败。"; return 1
    fi
    install -m 0644 "$temp_sysctl" "$SAKURA_SYSCTL"
    install -m 0644 "$temp_interfaces" "$SAKURA_INTERFACES"
    rm -f "$temp_sysctl" "$temp_interfaces"
    sysctl -p "$SAKURA_SYSCTL" || warn "sysctl 即时应用不完整，重启后会再次加载。"
    if command_exists ifup; then ifup "$iface" 2>/dev/null || true; fi
    sleep 2
    if sakura_verify "$iface"; then success "IPv6 已启用并通过公网检测。"; else warn "IPv6 尚未完全生效，建议重启后再次验证。"; fi
    printf '\n1. 立即重启\n0. 稍后手动重启\n'
    read -r -p "请选择: " reboot_choice
    if [[ "$reboot_choice" == "1" ]] && confirm "确认立即重启 VPS？"; then
        systemctl reboot
    else
        info "未重启。请稍后手动重启并重新运行验证。"
    fi
}

module_main() {
    title "樱花 VPS IPv6 启用"
    sakura_enable
    pause
}
