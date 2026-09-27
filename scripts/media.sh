#!/usr/bin/env bash

IPQUALITY_URL="https://IP.Check.Place"
MEDIA_CHECK_URL="https://raw.githubusercontent.com/lmc999/RegionRestrictionCheck/main/check.sh"

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

run_media_check() {
    local temp_file status
    ensure_download_environment || return 1
    temp_file="$(mktemp)" || { error "无法创建临时文件。"; return 1; }

    info "即将从上游官方 GitHub 仓库加载最新版：lmc999/RegionRestrictionCheck"
    if ! download_file "$MEDIA_CHECK_URL" "$temp_file"; then
        error "流媒体检测脚本下载失败：$MEDIA_CHECK_URL"
        rm -f "$temp_file"
        return 1
    fi
    if [[ ! -s "$temp_file" ]]; then
        error "流媒体检测脚本下载内容为空：$MEDIA_CHECK_URL"
        rm -f "$temp_file"
        return 1
    fi

    bash "$temp_file"
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
- 流媒体检测每次直接从 lmc999/RegionRestrictionCheck 官方 GitHub main 分支拉取最新版，避免 check.unlock.media 入口故障。
TEXT
        printf '\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) run_ipquality; pause ;;
            2) run_ipquality -4; pause ;;
            3) run_ipquality -6; pause ;;
            4) run_media_check; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
