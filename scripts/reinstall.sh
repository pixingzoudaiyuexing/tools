#!/usr/bin/env bash

REINSTALL_URL="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"

reinstall_virt_supported() {
    local virt
    virt="$(systemd-detect-virt 2>/dev/null || true)"
    case "$virt" in
        openvz|lxc) error "上游明确不支持 ${virt^^} 虚拟机。"; return 1 ;;
        *) return 0 ;;
    esac
}

reinstall_run() {
    local os_name="$1" version="$2" script
    require_root || return 1
    reinstall_virt_supported || return 1
    warn "系统重装可能清空 VPS 全部数据，并可能使 SSH 失联。"
    confirm "确认交给上游脚本配置重装 ${os_name} ${version}？" || return 0
    script="$(mktemp)" || return 1
    download_file "$REINSTALL_URL" "$script" || { rm -f "$script"; return 1; }
    bash "$script" "$os_name" "$version"
    local status=$?
    rm -f "$script"
    return "$status"
}

module_main() {
    local choice version
    while true; do
        title "VPS 系统重装"
        warn "高风险功能：执行后请严格阅读上游的最终提示，工具箱不会自动重启。"
        printf '1. 重装 Debian\n2. 重装 Ubuntu\n3. 查看上游帮助\n0. 返回\n\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) read -r -p "Debian 版本 [12]: " version; reinstall_run debian "${version:-12}"; pause ;;
            2) read -r -p "Ubuntu 版本 [24.04]: " version; reinstall_run ubuntu "${version:-24.04}"; pause ;;
            3) run_remote_bash "$REINSTALL_URL" "bin456789/reinstall"; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
