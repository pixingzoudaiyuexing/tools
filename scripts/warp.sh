#!/usr/bin/env bash

WARP_UPSTREAM_URL="https://raw.githubusercontent.com/yonggekkk/warp-yg/main/CFwarp.sh"

warp_native_address() {
    local family="$1" line iface address
    while read -r line; do
        iface="${line%% *}"
        is_virtual_interface_name "$iface" && continue
        address="$(awk '{print $2}' <<<"$line")"
        [[ -n "$address" ]] && { printf '%s\n' "${address%%/*}"; return 0; }
    done < <(ip "-$family" -o addr show scope global 2>/dev/null | awk '{print $2, $4}')
    return 1
}

warp_pure_ipv6_check() {
    local native4 native6 public4 public6 state4 state6
    native4="$(warp_native_address 4 || true)"
    native6="$(warp_native_address 6 || true)"
    public4="$(get_public_ip 4)"; public6="$(get_public_ip 6)"
    state4="$(get_cloudflare_warp_state 4)"; state6="$(get_cloudflare_warp_state 6)"
    printf '原生网络：\nIPv4：%s\nIPv6：%s\n' "${native4:-无}" "${native6:-无}"
    printf '当前公网：\nIPv4：%s\nIPv6：%s\n' "${public4:-无}" "${public6:-无}"
    printf 'WARP：\nIPv4：%s\nIPv6：%s\n' "$state4" "$state6"
    if [[ -z "$native4" && -n "$native6" && "$state4" =~ ^(on|plus)$ && "$state6" == "off" ]]; then
        success "当前符合“原生 IPv6 + WARP IPv4”目标状态。"
        return 0
    fi
    if [[ "$state6" =~ ^(on|plus)$ ]]; then
        warn "当前 IPv6 也通过 WARP，不符合保留原生 IPv6 的目标状态。"
    else
        warn "WARP IPv4 未正常工作，或原生网络并非纯 IPv6。"
    fi
    return 1
}

warp_environment() {
    local ipv4 ipv6 state4 state6
    ipv4="$(get_public_ip 4)"; ipv6="$(get_public_ip 6)"
    state4="$(get_cloudflare_warp_state 4)"; state6="$(get_cloudflare_warp_state 6)"
    printf '公网 IPv4：%s\n' "${ipv4:-未检测到}"
    printf '公网 IPv6：%s\n' "${ipv6:-未检测到}"
    printf 'IPv4 WARP：%s\n' "$state4"
    printf 'IPv6 WARP：%s\n' "$state6"
    printf 'warp-go：%s\n' "$(command_exists warp-go && printf '已安装' || printf '未安装')"
    printf 'wgcf：%s\n' "$(command_exists wgcf && printf '已安装' || printf '未安装')"
    printf 'WireGuard 接口：\n'
    ip -brief link show type wireguard 2>/dev/null || printf '  未检测到\n'
}

warp_old_config() {
    local found=0
    printf '[服务]\n'
    systemctl status warp-go --no-pager -n 5 2>/dev/null || true
    systemctl status wg-quick@wgcf --no-pager -n 5 2>/dev/null || true
    printf '\n[已知文件]\n'
    for path in /root/WARP-UP.sh /etc/wireguard/wgcf.conf /usr/local/bin/warp.conf /root/warpip; do
        if [[ -e "$path" ]]; then printf '存在：%s\n' "$path"; found=1; fi
    done
    printf '\n[含 wgcf/WARP 标识的防火墙行，仅检查]\n'
    command_exists iptables-save && iptables-save 2>/dev/null | grep -Ei 'wgcf|warp' || true
    command_exists ip6tables-save && ip6tables-save 2>/dev/null | grep -Ei 'wgcf|warp' || true
    ((found == 0)) && info "未发现常见旧配置文件。"
}

warp_repair_conflict() {
    require_root || return 1
    warn "此操作只停用旧 wgcf 服务并重启 warp-go，不删除配置文件或防火墙规则。"
    confirm "确认执行保守修复？" || return 0
    if [[ -f /etc/wireguard/wgcf.conf ]]; then
        backup_file /etc/wireguard/wgcf.conf "$VPS_TOOLS_ETC/backups/warp" || return 1
    fi
    systemctl disable --now wg-quick@wgcf 2>/dev/null || true
    command_exists wg-quick && wg-quick down wgcf 2>/dev/null || true
    if systemctl list-unit-files warp-go.service --no-legend 2>/dev/null | grep -q '^warp-go.service'; then
        systemctl enable --now warp-go && systemctl restart warp-go
    else
        warn "未找到 warp-go.service，请先通过上游脚本安装。"
    fi
    warp_environment
}

warp_diagnose() {
    title "WARP 故障诊断"
    warp_environment
    printf '\n[路由]\n'
    ip -4 route 2>/dev/null || true
    ip -6 route 2>/dev/null || true
    printf '\n[最近日志]\n'
    journalctl -u warp-go -u wg-quick@wgcf -n 40 --no-pager 2>/dev/null || true
}

module_main() {
    local choice
    while true; do
        title "WARP 网络管理"
        printf '1. WARP 环境检测\n2. 启动 warp-yg 管理脚本\n3. 纯 IPv6 → WARP IPv4 场景检查\n4. WARP 故障诊断\n5. 旧 WARP 配置检查\n6. 保守修复 wgcf / warp-go 冲突\n0. 返回\n\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) warp_environment; pause ;;
            3) warp_pure_ipv6_check; pause ;;
            2) run_remote_bash "$WARP_UPSTREAM_URL" "yonggekkk/warp-yg"; pause ;;
            4) warp_diagnose; pause ;;
            5) warp_old_config; pause ;;
            6) warp_repair_conflict; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
