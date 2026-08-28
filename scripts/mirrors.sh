#!/usr/bin/env bash

module_main() {
    title "Linux 系统换源"
    warn "换源会修改系统软件源；上游脚本会自行备份并交互确认。"
    if confirm "是否启动 LinuxMirrors 官方换源脚本？"; then
        run_remote_bash "https://linuxmirrors.cn/main.sh" "SuperManito/LinuxMirrors"
    fi
    pause
}
