#!/usr/bin/env bash

# 查询失败不会中断另一个协议族。
module_main() {
    local ipv4 ipv6
    title "公网 IPv4 / IPv6"
    command_exists curl || { error "缺少 curl。"; pause; return 1; }
    ipv4="$(get_public_ip 4)"
    ipv6="$(get_public_ip 6)"
    printf '公网 IPv4：%s\n' "${ipv4:-未检测到}"
    printf '公网 IPv6：%s\n' "${ipv6:-未检测到}"
    pause
}
