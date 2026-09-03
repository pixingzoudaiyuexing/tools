#!/usr/bin/env bash

WARP_UPSTREAM_URL="https://raw.githubusercontent.com/yonggekkk/warp-yg/main/CFwarp.sh"
WARP_CF_COMMAND="${WARP_CF_COMMAND:-/usr/bin/cf}"

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

warp_target_matches() {
    local target_family="$1" native4 native6 public4 public6 state4 state6
    native4="$(warp_native_address 4 || true)"
    native6="$(warp_native_address 6 || true)"
    public4="$(get_public_ip 4)"
    public6="$(get_public_ip 6)"
    state4="$(get_cloudflare_warp_state 4)"
    state6="$(get_cloudflare_warp_state 6)"

    case "$target_family" in
        4)
            [[ -z "$native4" && -n "$native6" && -n "$public4" && "$state4" =~ ^(on|plus)$ && "$state6" == "off" ]]
            ;;
        6)
            [[ -n "$native4" && -z "$native6" && -n "$public6" && "$state6" =~ ^(on|plus)$ && "$state4" == "off" ]]
            ;;
        *) return 1 ;;
    esac
}

warp_target_report() {
    local target_family="$1" native4 native6 public4 public6 state4 state6
    native4="$(warp_native_address 4 || true)"
    native6="$(warp_native_address 6 || true)"
    public4="$(get_public_ip 4)"; public6="$(get_public_ip 6)"
    state4="$(get_cloudflare_warp_state 4)"; state6="$(get_cloudflare_warp_state 6)"
    printf '原生网络：\nIPv4：%s\nIPv6：%s\n' "${native4:-无}" "${native6:-无}"
    printf '当前公网：\nIPv4：%s\nIPv6：%s\n' "${public4:-无}" "${public6:-无}"
    printf 'WARP：\nIPv4：%s\nIPv6：%s\n' "$state4" "$state6"

    if warp_target_matches "$target_family"; then
        if [[ "$target_family" == "4" ]]; then
            success "当前符合“原生 IPv6 + WARP IPv4”目标状态。"
        else
            success "当前符合“原生 IPv4 + WARP IPv6”目标状态。"
        fi
        return 0
    fi

    if [[ "$target_family" == "4" ]]; then
        warn "当前不符合“原生 IPv6 + WARP IPv4”目标状态。"
    else
        warn "当前不符合“原生 IPv4 + WARP IPv6”目标状态。"
    fi
    return 1
}

warp_pure_ipv6_check() {
    warp_target_report 4
}

warp_pure_ipv4_check() {
    warp_target_report 6
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

warp_build_upstream_input() {
    local target_family="$1" mode_choice backend_choice
    case "$target_family" in
        4) mode_choice=1 ;;
        6) mode_choice=2 ;;
        *) return 1 ;;
    esac

    if command_exists warp-go && command_exists wg-quick; then
        return 2
    elif command_exists warp-go; then
        backend_choice=3
    elif command_exists wg-quick; then
        backend_choice=2
    else
        backend_choice=3
    fi

    if [[ -x "$WARP_CF_COMMAND" ]]; then
        printf '1\n%s\n' "$mode_choice"
    else
        printf '%s\n1\n%s\n' "$backend_choice" "$mode_choice"
    fi
}

warp_validate_upstream_menu() {
    local script="$1" target_family="$2"
    grep -Fq '安装/切换WARP单栈IPV4' "$script" || grep -Fq '安装/切换wgcf-warp单栈IPV4' "$script" || return 1
    grep -Fq '安装/切换WARP单栈IPV6' "$script" || grep -Fq '安装/切换wgcf-warp单栈IPV6' "$script" || return 1
    grep -Fq '请输入数字【0-3】' "$script" || grep -Fq '方案一：安装/切换WARP-GO' "$script" || grep -Fq '方案一：安装/切换WGCF-WARP' "$script" || return 1
    [[ "$target_family" == "4" || "$target_family" == "6" ]]
}

warp_run_upstream_auto() {
    local target_family="$1" temp_file input status
    temp_file="$(mktemp)" || return 1
    if ! download_file "$WARP_UPSTREAM_URL" "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi
    if ! warp_validate_upstream_menu "$temp_file" "$target_family"; then
        rm -f "$temp_file"
        error "warp-yg 上游菜单结构已变化，为避免自动选择错误，已停止部署。"
        return 1
    fi

    input="$(warp_build_upstream_input "$target_family")"
    status=$?
    if [[ "$status" -ne 0 ]]; then
        rm -f "$temp_file"
        if [[ "$status" -eq 2 ]]; then
            error "同时检测到 warp-go 与 wg-quick，属于冲突环境，已停止自动部署。"
        else
            error "无法生成 warp-yg 自动部署参数。"
        fi
        return 1
    fi

    info "正在调用 warp-yg 自动完成部署，后续无需手动选择菜单。"
    printf '%s\n' "$input" | bash "$temp_file"
    status=$?
    rm -f "$temp_file"
    return "$status"
}

warp_auto_add_family() {
    local target_family="$1" native4 native6 attempt
    require_root || return 1
    native4="$(warp_native_address 4 || true)"
    native6="$(warp_native_address 6 || true)"

    case "$target_family" in
        6)
            if [[ -z "$native4" || -n "$native6" ]]; then
                error "此快捷项仅用于纯 IPv4 机器。检测结果：原生 IPv4=${native4:-无}，原生 IPv6=${native6:-无}。"
                return 1
            fi
            info "已确认当前为纯 IPv4 网络，将自动添加 WARP IPv6，并保留原生 IPv4。"
            ;;
        4)
            if [[ -n "$native4" || -z "$native6" ]]; then
                error "此快捷项仅用于纯 IPv6 机器。检测结果：原生 IPv4=${native4:-无}，原生 IPv6=${native6:-无}。"
                return 1
            fi
            info "已确认当前为纯 IPv6 网络，将自动添加 WARP IPv4，并保留原生 IPv6。"
            ;;
        *) return 1 ;;
    esac

    if warp_target_matches "$target_family"; then
        success "当前已经是目标 WARP 状态，无需重复部署。"
        warp_target_report "$target_family"
        return 0
    fi

    if command_exists warp-go && command_exists wg-quick; then
        error "同时检测到 warp-go 与 wg-quick。为避免自动修改冲突路由，请先使用“旧 WARP 配置检查 / 保守修复”。"
        return 1
    fi

    warp_run_upstream_auto "$target_family" || {
        error "warp-yg 自动部署未成功完成。"
        return 1
    }

    for attempt in 1 2 3 4 5; do
        if warp_target_matches "$target_family"; then
            success "WARP 自动部署成功。"
            warp_target_report "$target_family"
            return 0
        fi
        ((attempt < 5)) && sleep 3
    done

    error "warp-yg 已执行，但最终网络状态未达到目标。"
    warp_target_report "$target_family" || true
    warn "建议运行 WARP 故障诊断检查路由、服务和日志。"
    return 1
}

module_main() {
    local choice
    while true; do
        title "WARP 网络管理"
        cat <<'MENU'
 1. 一键：纯 IPv4 机器添加 IPv6
 2. 一键：纯 IPv6 机器添加 IPv4
 3. WARP 环境检测
 4. 启动 warp-yg 管理脚本
 5. 检查：原生 IPv4 + WARP IPv6
 6. 检查：原生 IPv6 + WARP IPv4
 7. WARP 故障诊断
 8. 旧 WARP 配置检查
 9. 保守修复 wgcf / warp-go 冲突
 0. 返回
MENU
        printf '\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) warp_auto_add_family 6; pause ;;
            2) warp_auto_add_family 4; pause ;;
            3) warp_environment; pause ;;
            4) run_remote_bash "$WARP_UPSTREAM_URL" "yonggekkk/warp-yg"; pause ;;
            5) warp_pure_ipv4_check; pause ;;
            6) warp_pure_ipv6_check; pause ;;
            7) warp_diagnose; pause ;;
            8) warp_old_config; pause ;;
            9) warp_repair_conflict; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
