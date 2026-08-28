#!/usr/bin/env bash

port_check_all() {
    command_exists ss || { error "缺少 ss，请安装 iproute2。"; return 1; }
    ss -lntup
}

port_check_one() {
    local port
    read -r -p "请输入端口（1-65535）: " port
    validate_port "$port" || { error "端口无效。"; return 1; }
    printf '\n[ss 查询]\n'
    ss -lntup "sport = :$port" 2>/dev/null || true
    if command_exists lsof; then
        printf '\n[lsof 查询]\n'
        lsof -nP -iTCP:"$port" -iUDP:"$port" 2>/dev/null || info "未发现占用。"
    elif confirm "lsof 未安装，是否现在安装？"; then
        if apt_install lsof; then lsof -nP -iTCP:"$port" -iUDP:"$port" 2>/dev/null || true; fi
    else
        warn "已跳过 lsof 查询。"
    fi
}

module_main() {
    local choice
    while true; do
        title "端口占用 / 监听查询"
        printf '1. 查看所有 TCP/UDP 监听端口\n2. 查询指定端口占用\n0. 返回\n\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) port_check_all; pause ;;
            2) port_check_one; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
