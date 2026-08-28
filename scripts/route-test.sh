#!/usr/bin/env bash

NEXTTRACE_INSTALL_URL="https://nxtrace.org/nt"

route_require_nexttrace() {
    command_exists nexttrace && return 0
    confirm "NextTrace 未安装，是否使用官方脚本安装？" || return 1
    require_root || return 1
    run_remote_bash "$NEXTTRACE_INSTALL_URL" "nxtrace/NTrace-core"
    command_exists nexttrace || { error "NextTrace 安装后仍不可用。"; return 1; }
}

route_read_target() {
    local target
    read -r -p "请输入目标 IP 或域名: " target
    validate_hostname_or_ip "$target" || { error "目标格式无效。"; return 1; }
    printf '%s\n' "$target"
}

route_nexttrace() {
    local protocol="$1" target port
    route_require_nexttrace || return 1
    target="$(route_read_target)" || return 1
    case "$protocol" in
        icmp) nexttrace --language cn "$target" ;;
        tcp)
            read -r -p "TCP 端口 [443]: " port; port="${port:-443}"
            validate_port "$port" || { error "端口无效。"; return 1; }
            nexttrace --language cn --tcp --port "$port" "$target"
            ;;
        udp)
            read -r -p "UDP 端口 [33494]: " port; port="${port:-33494}"
            validate_port "$port" || { error "端口无效。"; return 1; }
            nexttrace --language cn --udp --port "$port" "$target"
            ;;
    esac
}

route_mtr() {
    local target mode port
    if ! command_exists mtr; then
        confirm "MTR 未安装，是否安装？" || return 1
        apt_install mtr-tiny || return 1
    fi
    target="$(route_read_target)" || return 1
    printf '1. ICMP 报告\n2. TCP 报告\n3. UDP 报告\n0. 返回\n'
    read -r -p "请选择: " mode
    case "$mode" in
        1) mtr -rwzc 10 "$target" ;;
        2)
            read -r -p "TCP 端口 [443]: " port; port="${port:-443}"
            validate_port "$port" || { error "端口无效。"; return 1; }
            mtr -rwzc 10 -T -P "$port" "$target"
            ;;
        3)
            read -r -p "UDP 端口 [33494]: " port; port="${port:-33494}"
            validate_port "$port" || { error "端口无效。"; return 1; }
            mtr -rwzc 10 -u -P "$port" "$target"
            ;;
        0) return 0 ;;
        *) error "无效选项。"; return 1 ;;
    esac
}

module_main() {
    local choice
    while true; do
        title "路由 / 链路测试"
        printf '1. ICMP 路由测试\n2. TCP 路由测试\n3. UDP 路由测试\n4. MTR 丢包 / 延迟测试\n0. 返回\n\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) route_nexttrace icmp; pause ;;
            2) route_nexttrace tcp; pause ;;
            3) route_nexttrace udp; pause ;;
            4) route_mtr; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
