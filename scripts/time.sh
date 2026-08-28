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

time_has_timesyncd() {
    systemctl list-unit-files systemd-timesyncd.service --no-legend 2>/dev/null | grep -q '^systemd-timesyncd.service'
}

time_timesyncd_properties() {
    local ntp synchronized
    ntp="$(timedatectl show -p NTP --value 2>/dev/null)" || { error "无法读取 NTP 状态。"; return 1; }
    synchronized="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" || { error "无法读取时间同步状态。"; return 1; }
    printf '%s %s\n' "$ntp" "$synchronized"
}

time_wait_for_timesyncd() {
    local elapsed=0 max_wait="${TIME_SYNC_WAIT_SECONDS:-30}" interval="${TIME_SYNC_POLL_INTERVAL:-1}"
    local properties ntp synchronized
    while ((elapsed < max_wait)); do
        properties="$(time_timesyncd_properties)" || return 1
        read -r ntp synchronized <<<"$properties"
        if [[ "$synchronized" == "yes" ]]; then
            success "时间同步完成。"
            return 0
        fi
        [[ "$ntp" == "yes" ]] || { error "NTP 未启用。"; return 1; }
        elapsed=$((elapsed + 1))
        info "正在等待 NTP 同步... ${elapsed}/${max_wait} 秒"
        sleep "$interval"
    done
    systemctl is-active --quiet systemd-timesyncd || { error "systemd-timesyncd 未处于 active。"; return 1; }
    warn "NTP 服务运行正常，但 ${max_wait} 秒内尚未完成首次同步。建议稍后重新查看同步状态。"
    return 0
}

time_enable_sync() {
    local properties ntp synchronized
    require_root || return 1
    if time_has_timesyncd; then
        systemctl is-enabled systemd-timesyncd 2>/dev/null | grep -q masked && { error "systemd-timesyncd 已被 mask。"; return 1; }
        timedatectl set-ntp true || { error "无法启用 NTP。"; return 1; }
        systemctl enable --now systemd-timesyncd || { error "systemd-timesyncd 启动失败。"; return 1; }
        systemctl is-active --quiet systemd-timesyncd || { error "systemd-timesyncd 未处于 active。"; return 1; }
        properties="$(time_timesyncd_properties)" || return 1
        read -r ntp synchronized <<<"$properties"
        [[ "$ntp" == "yes" ]] || { error "NTP 未启用。"; return 1; }
        success "自动时间同步已开启。"
        if [[ "$synchronized" == "yes" ]]; then
            success "当前系统时间已经同步。"
        else
            warn "正在等待首次 NTP 同步。"
        fi
    elif command_exists chronyd || command_exists chronyc; then
        systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd || { error "chrony 启动失败。"; return 1; }
        systemctl is-active --quiet chrony 2>/dev/null || systemctl is-active --quiet chronyd 2>/dev/null || { error "chrony 未处于 active。"; return 1; }
        success "已启用并验证 chrony。"
    elif confirm "系统无可用时间同步服务，是否安装 chrony？"; then
        apt_install chrony && systemctl enable --now chrony && systemctl is-active --quiet chrony && success "已安装并验证 chrony。"
    else
        return 1
    fi
}

time_sync_now() {
    require_root || return 1
    time_enable_sync || return 1
    if time_has_timesyncd; then
        systemctl restart systemd-timesyncd || { error "systemd-timesyncd 重启失败。"; return 1; }
        systemctl is-active --quiet systemd-timesyncd || { error "systemd-timesyncd 未处于 active。"; return 1; }
        time_wait_for_timesyncd || return 1
    elif command_exists chronyc; then
        chronyc -a makestep || { error "chrony 立即同步失败。"; return 1; }
    else
        error "未找到可用的时间同步服务。"
        return 1
    fi
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
