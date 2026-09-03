#!/usr/bin/env bash

WARP_UPSTREAM_URL="https://raw.githubusercontent.com/yonggekkk/warp-yg/main/CFwarp.sh"
WARP_CF_COMMAND="${WARP_CF_COMMAND:-/usr/bin/cf}"

warp_has_warp_go() {
    [[ -s /usr/local/bin/warp.conf ]] && { command_exists warp-go || [[ -x /usr/local/bin/warp-go || -x /usr/bin/warp-go ]]; }
}

warp_has_wgcf() {
    [[ -s /etc/wireguard/wgcf.conf ]]
}

warp_has_official_client() {
    command_exists warp-cli || command_exists warp-svc || \
        [[ -x /usr/bin/warp-cli || -x /usr/bin/warp-svc || -x /bin/warp-cli || -x /bin/warp-svc ]]
}

warp_has_cf_launcher() {
    [[ -x "$WARP_CF_COMMAND" ]] && grep -Fq 'warp-yg' "$WARP_CF_COMMAND" 2>/dev/null
}

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
    printf 'warp-go：%s\n' "$(warp_has_warp_go && printf '已安装' || printf '未安装')"
    printf 'wgcf：%s\n' "$(warp_has_wgcf && printf '已安装' || printf '未安装')"
    printf '官方 WARP / Socks5：%s\n' "$(warp_has_official_client && printf '已安装' || printf '未安装')"
    printf 'WireGuard 接口：\n'
    ip -brief link show type wireguard 2>/dev/null || printf '  未检测到\n'
}

warp_old_config() {
    local found=0
    printf '[服务]\n'
    systemctl status warp-go --no-pager -n 5 2>/dev/null || true
    systemctl status wg-quick@wgcf --no-pager -n 5 2>/dev/null || true
    systemctl status warp-svc --no-pager -n 5 2>/dev/null || true
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
    journalctl -u warp-go -u wg-quick@wgcf -u warp-svc -n 40 --no-pager 2>/dev/null || true
}

warp_known_artifacts_exist() {
    warp_has_warp_go && return 0
    warp_has_wgcf && return 0
    warp_has_official_client && return 0
    warp_has_cf_launcher && return 0
    [[ -e /root/WARP-UP.sh || -d /root/warpip || -e /root/warp_update ]] && return 0
    return 1
}

warp_stop_monitor() {
    local session
    [[ -e /root/WARP-UP.sh ]] || return 0
    command_exists screen || return 0
    while read -r session; do
        [[ -n "$session" ]] || continue
        screen -S "$session" -X quit >/dev/null 2>&1 || true
    done < <(screen -ls 2>/dev/null | awk '/\.up[[:space:]]/ {print $1}')
}

warp_remove_official_package() {
    if command_exists dpkg-query && dpkg-query -W -f='${Status}' cloudflare-warp 2>/dev/null | grep -q 'install ok installed'; then
        info "正在卸载 cloudflare-warp 软件包..."
        DEBIAN_FRONTEND=noninteractive apt-get purge -y cloudflare-warp || warn "cloudflare-warp 软件包卸载失败，将继续清理其余 WARP 文件。"
    elif command_exists rpm && rpm -q cloudflare-warp >/dev/null 2>&1; then
        info "正在卸载 cloudflare-warp 软件包..."
        if command_exists dnf; then
            dnf remove -y cloudflare-warp || warn "cloudflare-warp 软件包卸载失败。"
        elif command_exists yum; then
            yum remove -y cloudflare-warp || warn "cloudflare-warp 软件包卸载失败。"
        fi
    fi
}

warp_uninstall_remaining() {
    local remaining=0
    if warp_has_warp_go; then warn "仍检测到 warp-go。"; remaining=1; fi
    if warp_has_wgcf; then warn "仍检测到 wgcf 配置。"; remaining=1; fi
    if warp_has_official_client; then warn "仍检测到官方 WARP / warp-cli。"; remaining=1; fi
    if warp_has_cf_launcher; then warn "仍检测到 warp-yg 的 cf 快捷入口。"; remaining=1; fi
    if command_exists systemctl; then
        if systemctl is-active --quiet warp-go 2>/dev/null; then warn "warp-go.service 仍在运行。"; remaining=1; fi
        if systemctl is-active --quiet wg-quick@wgcf 2>/dev/null; then warn "wg-quick@wgcf.service 仍在运行。"; remaining=1; fi
        if systemctl is-active --quiet warp-svc 2>/dev/null; then warn "warp-svc.service 仍在运行。"; remaining=1; fi
    fi
    ((remaining == 0))
}

warp_uninstall_all() {
    local state4 state6
    require_root || return 1
    title "一键卸载所有 WARP"
    warn "将清理 WARP-GO、WGCF、Socks5-WARP / cloudflare-warp、warp-yg 在线监测和已知配置。"
    warn "不会卸载通用 wireguard-tools，也不会清空 iptables / nftables 防火墙。"
    confirm "确认卸载所有 WARP？" || { info "已取消。"; return 0; }

    if ! warp_known_artifacts_exist; then
        success "未检测到需要卸载的 WARP 组件。"
        warp_environment
        return 0
    fi

    info "正在停止 WARP 服务和在线监测..."
    if command_exists warp-cli; then
        warp-cli --accept-tos disconnect >/dev/null 2>&1 || true
        warp-cli --accept-tos disable-always-on >/dev/null 2>&1 || true
        warp-cli --accept-tos delete >/dev/null 2>&1 || true
    fi
    if command_exists wg-quick && [[ -f /etc/wireguard/wgcf.conf ]]; then
        wg-quick down wgcf >/dev/null 2>&1 || true
    fi
    if command_exists systemctl; then
        systemctl disable --now warp-go >/dev/null 2>&1 || true
        systemctl disable --now wg-quick@wgcf >/dev/null 2>&1 || true
        systemctl disable --now warp-svc >/dev/null 2>&1 || true
    fi
    warp_stop_monitor
    command_exists pkill && pkill -TERM -x warp-go >/dev/null 2>&1 || true

    warp_remove_official_package

    if command_exists chattr && [[ -e /etc/resolv.conf ]]; then
        chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
    fi

    if warp_has_cf_launcher; then
        rm -f -- "$WARP_CF_COMMAND"
    fi

    rm -f -- \
        /usr/local/bin/warp-go \
        /usr/bin/warp-go \
        /usr/local/bin/warp.conf \
        /usr/local/bin/warpplus.log \
        /usr/local/bin/wgwarp.conf \
        /usr/local/bin/sbwarp.json \
        /lib/systemd/system/warp-go.service \
        /etc/systemd/system/warp-go.service \
        /etc/wireguard/wgcf.conf \
        /etc/wireguard/wgcf-profile.conf \
        /etc/wireguard/buckup-profile.conf \
        /etc/wireguard/buckup-account.toml \
        /etc/wireguard/wgcf-account.toml \
        /etc/wireguard/wgcf+p.log \
        /etc/wireguard/ID \
        /usr/local/bin/wgcf \
        /usr/bin/wgcf \
        /usr/bin/wireguard-go \
        /root/WARP-UP.sh \
        /root/WARP+Keys.txt \
        /root/warp_update \
        /root/acwarp.sh \
        /root/warpapi \
        /etc/apt/sources.list.d/cloudflare-client.list \
        /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg \
        /etc/apt/keyrings/cloudflare-warp-archive-keyring.gpg
    rm -rf -- /root/warpip

    # 软件包卸载失败或手工安装时，清理明确属于 Cloudflare WARP 的残留二进制。
    rm -f -- /usr/bin/warp-cli /usr/bin/warp-svc /bin/warp-cli /bin/warp-svc

    if [[ -f /etc/gai.conf ]]; then
        sed -i -E '/^[[:space:]]*precedence[[:space:]]+::ffff:0:0\/96[[:space:]]+100[[:space:]]*$/d' /etc/gai.conf 2>/dev/null || true
    fi

    if command_exists systemctl; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed warp-go wg-quick@wgcf warp-svc >/dev/null 2>&1 || true
    fi

    sleep 2
    state4="$(get_cloudflare_warp_state 4)"
    state6="$(get_cloudflare_warp_state 6)"

    if warp_uninstall_remaining; then
        success "所有已知 WARP 组件已卸载。"
    else
        error "仍发现 WARP 残留，请运行“旧 WARP 配置检查”查看。"
        printf '卸载后 WARP 状态：IPv4=%s，IPv6=%s\n' "$state4" "$state6"
        return 1
    fi

    printf '卸载后 WARP 状态：IPv4=%s，IPv6=%s\n' "$state4" "$state6"
    info "下面显示当前网络状态，用于确认原生 IPv4 / IPv6 是否恢复。"
    warp_environment
}

warp_build_upstream_input() {
    local target_family="$1" mode_choice backend_choice
    case "$target_family" in
        4) mode_choice=1 ;;
        6) mode_choice=2 ;;
        *) return 1 ;;
    esac

    if warp_has_warp_go && warp_has_wgcf; then
        return 2
    elif warp_has_warp_go; then
        backend_choice=3
    elif warp_has_wgcf; then
        backend_choice=2
    else
        backend_choice=3
    fi

    if warp_has_cf_launcher; then
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

    if input="$(warp_build_upstream_input "$target_family")"; then
        status=0
    else
        status=$?
    fi
    if [[ "$status" -ne 0 ]]; then
        rm -f "$temp_file"
        if [[ "$status" -eq 2 ]]; then
            error "同时检测到 warp-go 与 wgcf，属于冲突环境，已停止自动部署。"
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

    if warp_has_warp_go && warp_has_wgcf; then
        error "同时检测到 warp-go 与 wgcf。为避免自动修改冲突路由，请先使用“旧 WARP 配置检查 / 保守修复”。"
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
 3. 一键卸载所有 WARP
 4. WARP 环境检测
 5. 启动 warp-yg 管理脚本
 6. 检查：原生 IPv4 + WARP IPv6
 7. 检查：原生 IPv6 + WARP IPv4
 8. WARP 故障诊断
 9. 旧 WARP 配置检查
10. 保守修复 wgcf / warp-go 冲突
 0. 返回
MENU
        printf '\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) warp_auto_add_family 6; pause ;;
            2) warp_auto_add_family 4; pause ;;
            3) warp_uninstall_all; pause ;;
            4) warp_environment; pause ;;
            5) run_remote_bash "$WARP_UPSTREAM_URL" "yonggekkk/warp-yg"; pause ;;
            6) warp_pure_ipv4_check; pause ;;
            7) warp_pure_ipv6_check; pause ;;
            8) warp_diagnose; pause ;;
            9) warp_old_config; pause ;;
            10) warp_repair_conflict; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
