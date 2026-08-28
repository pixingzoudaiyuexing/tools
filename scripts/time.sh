#!/usr/bin/env bash

time_show() {
    printf '当前时间：%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    timedatectl status 2>/dev/null || true
    printf '\n[systemd-timesyncd]\n'
    systemctl status systemd-timesyncd --no-pager -n 5 2>/dev/null || printf '未运行或不存在\n'
    if command_exists chronyc; then
        printf '\n[chrony]\n'
        chronyc tracking 2>/dev/null || true
    fi
}

time_set_zone() {
    local choice zone
    require_root || return 1
    cat <<'ZONES'
1. 中国上海 Asia/Shanghai [默认]
2. 中国香港 Asia/Hong_Kong
3. 日本东京 Asia/Tokyo
4. 新加坡 Asia/Singapore
5. 美国洛杉矶 America/Los_Angeles
6. 美国纽约 America/New_York
7. 英国伦敦 Europe/London
8. 德国/法兰克福 Europe/Berlin
9. UTC
10. 自定义
ZONES
    read -r -p "请选择 [1]: " choice; choice="${choice:-1}"
    case "$choice" in
        1) zone="Asia/Shanghai" ;; 2) zone="Asia/Hong_Kong" ;; 3) zone="Asia/Tokyo" ;;
        4) zone="Asia/Singapore" ;; 5) zone="America/Los_Angeles" ;; 6) zone="America/New_York" ;;
        7) zone="Europe/London" ;; 8) zone="Europe/Berlin" ;; 9) zone="UTC" ;;
        10) read -r -p "请输入时区（例如 Europe/Paris）: " zone ;;
        *) error "无效选项。"; return 1 ;;
    esac
    timedatectl list-timezones | grep -Fxq "$zone" || { error "时区不存在：$zone"; return 1; }
    timedatectl set-timezone "$zone" && success "时区已设置为 ${zone}。"
}

time_enable_sync() {
    require_root || return 1
    if systemctl list-unit-files systemd-timesyncd.service --no-legend 2>/dev/null | grep -q '^systemd-timesyncd.service'; then
        timedatectl set-ntp true
        systemctl enable --now systemd-timesyncd
        success "已启用 systemd-timesyncd。"
    elif command_exists chronyd || command_exists chronyc; then
        systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd
        success "已启用 chrony。"
    elif confirm "系统无可用时间同步服务，是否安装 chrony？"; then
        apt_install chrony && systemctl enable --now chrony
    else
        return 1
    fi
}

time_sync_now() {
    require_root || return 1
    time_enable_sync || return 1
    if command_exists chronyc; then
        chronyc -a makestep || true
    else
        systemctl restart systemd-timesyncd
    fi
    sleep 2
    time_show
}

module_main() {
    local choice
    while true; do
        title "时间 / 时区管理"
        printf '1. 修改时区\n2. 立即同步时间\n3. 查看时间同步状态\n4. 开启自动时间同步\n0. 返回\n\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) time_set_zone; pause ;;
            2) time_sync_now; pause ;;
            3) time_show; pause ;;
            4) time_enable_sync; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
