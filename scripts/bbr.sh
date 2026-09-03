#!/usr/bin/env bash

BBR_SYSCTL_FILE="${BBR_SYSCTL_FILE:-/etc/sysctl.d/99-vps-tools-bbr-fq.conf}"
BBR_UPSTREAM_URL="https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/main/install.sh"

bbr_current_cc() {
    sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '未知\n'
}

bbr_current_qdisc() {
    sysctl -n net.core.default_qdisc 2>/dev/null || printf '未知\n'
}

bbr_available_cc() {
    if [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then
        cat /proc/sys/net/ipv4/tcp_available_congestion_control
    else
        sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true
    fi
}

bbr_show_status() {
    local available current_cc current_qdisc
    available="$(bbr_available_cc)"
    current_cc="$(bbr_current_cc)"
    current_qdisc="$(bbr_current_qdisc)"

    printf '内核版本：%s\n' "$(uname -r)"
    printf '可用拥塞控制：%s\n' "${available:-未检测到}"
    printf '当前拥塞控制：%s\n' "$current_cc"
    printf '当前默认队列：%s\n' "$current_qdisc"
    if [[ "$current_cc" == "bbr" && "$current_qdisc" == "fq" ]]; then
        success "当前已是 BBR + FQ。"
    fi
}

bbr_restore_runtime() {
    local old_cc="$1" old_qdisc="$2"
    [[ -n "$old_qdisc" && "$old_qdisc" != "未知" ]] && sysctl -w "net.core.default_qdisc=${old_qdisc}" >/dev/null 2>&1 || true
    [[ -n "$old_cc" && "$old_cc" != "未知" ]] && sysctl -w "net.ipv4.tcp_congestion_control=${old_cc}" >/dev/null 2>&1 || true
}

bbr_quick_enable() {
    local available old_cc old_qdisc old_file="" had_old_file=0
    require_root || { pause; return 1; }

    title "快速开启 BBR + FQ"
    info "只启用当前内核已有的 BBR + FQ，不安装或更换内核。"

    if command_exists modprobe; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
        modprobe sch_fq >/dev/null 2>&1 || true
    fi

    available="$(bbr_available_cc)"
    if [[ " ${available} " != *" bbr "* ]]; then
        error "当前内核没有提供 BBR，无法直接快速开启。"
        info "请返回后选择“启动 BBRv3 完整管理脚本”安装支持 BBR 的内核。"
        bbr_show_status
        pause
        return 1
    fi

    old_cc="$(bbr_current_cc)"
    old_qdisc="$(bbr_current_qdisc)"

    mkdir -p "$(dirname "$BBR_SYSCTL_FILE")" || { error "无法创建 sysctl 配置目录。"; pause; return 1; }
    if [[ -e "$BBR_SYSCTL_FILE" ]]; then
        old_file="$(mktemp)" || { error "无法创建临时备份。"; pause; return 1; }
        cp -a -- "$BBR_SYSCTL_FILE" "$old_file" || { rm -f "$old_file"; error "备份现有 BBR 配置失败。"; pause; return 1; }
        had_old_file=1
        backup_file "$BBR_SYSCTL_FILE" "$VPS_TOOLS_ETC/backups/bbr" || true
    fi

    cat >"$BBR_SYSCTL_FILE" <<'EOF'
# Managed by VPS Tools: BBR + FQ
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    chmod 0644 "$BBR_SYSCTL_FILE" 2>/dev/null || true

    if ! sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || \
       ! sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
        error "BBR + FQ 应用失败，正在恢复修改前状态。"
        bbr_restore_runtime "$old_cc" "$old_qdisc"
        if ((had_old_file == 1)); then
            cp -a -- "$old_file" "$BBR_SYSCTL_FILE"
        else
            rm -f "$BBR_SYSCTL_FILE"
        fi
        rm -f "$old_file"
        bbr_show_status
        pause
        return 1
    fi

    rm -f "$old_file"

    if [[ "$(bbr_current_cc)" == "bbr" && "$(bbr_current_qdisc)" == "fq" ]]; then
        success "BBR + FQ 已开启并写入持久化配置。"
        printf '配置文件：%s\n\n' "$BBR_SYSCTL_FILE"
        bbr_show_status
        pause
        return 0
    fi

    error "命令执行后状态验证未通过。"
    bbr_show_status
    pause
    return 1
}

bbr_upstream() {
    warn "安装 BBRv3 内核存在无法启动风险，请先确认控制台、救援模式和旧内核可用。"
    if confirm "是否启动 Actions-bbr-v3 官方脚本？"; then
        run_remote_bash "$BBR_UPSTREAM_URL" "byJoey/Actions-bbr-v3"
    fi
}

module_main() {
    local choice
    while true; do
        title "BBR / BBRv3 网络优化"
        cat <<'TEXT'
1. 快速开启 BBR + FQ
2. 启动 BBRv3 完整管理脚本
3. 查看当前 BBR / FQ 状态
0. 返回

说明：
- 选 1 后自动完成，不再进入分级菜单。
- 快速开启只使用当前内核已有的 BBR，不更换内核。
- 当前内核不支持 BBR 时，请使用选项 2。
TEXT
        printf '\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) bbr_quick_enable ;;
            2) bbr_upstream; pause ;;
            3) title "BBR / FQ 当前状态"; bbr_show_status; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
