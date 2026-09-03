#!/usr/bin/env bash

IPQUALITY_URL="https://IP.Check.Place"
MEDIA_CHECK_URL="https://check.unlock.media"

run_ipquality() {
    local mode="${1:-}" temp_file status
    temp_file="$(mktemp)" || { error "无法创建临时文件。"; return 1; }

    if ! download_file "$IPQUALITY_URL" "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi

    info "即将启动第三方项目：xykt/IPQuality"
    if [[ -n "$mode" ]]; then
        bash "$temp_file" "$mode"
    else
        bash "$temp_file"
    fi
    status=$?
    rm -f "$temp_file"
    return "$status"
}

module_main() {
    local choice
    while true; do
        title "流媒体 / 地区解锁检测"
        cat <<'TEXT'
1. IP 质量体检（IPv4 + IPv6）
2. IP 质量体检（仅 IPv4）
3. IP 质量体检（仅 IPv6）
4. 流媒体 / 地区解锁检测
0. 返回

说明：
- IP 质量体检使用 xykt/IPQuality（IP.Check.Place）。
- 默认双栈检测；也可强制只检测 IPv4 或 IPv6。
- 原有 lmc999/RegionRestrictionCheck 入口继续保留。
TEXT
        printf '\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) run_ipquality; pause ;;
            2) run_ipquality -4; pause ;;
            3) run_ipquality -6; pause ;;
            4) run_remote_bash "$MEDIA_CHECK_URL" "lmc999/RegionRestrictionCheck"; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
