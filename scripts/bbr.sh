#!/usr/bin/env bash

module_main() {
    title "BBRv3 内核 / 网络优化"
    warn "安装内核存在无法启动风险，请先确认控制台、救援模式和旧内核可用。"
    if confirm "是否启动 Actions-bbr-v3 官方脚本？"; then
        run_remote_bash "https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/main/install.sh" "byJoey/Actions-bbr-v3"
    fi
    pause
}
