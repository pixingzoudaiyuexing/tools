#!/usr/bin/env bash

# wcwq99 仓库当前重定向到 wcwq98，官方 README 使用下列主分支入口。
module_main() {
    title "VPS 端口中转（Realm）"
    cat <<'TEXT'
将启动 Realm 官方管理脚本。它负责安装、添加/删除转发、服务和日志管理。
VPS Tools 不会修改防火墙，也不会复制 Realm 项目源码。
TEXT
    if confirm "是否继续启动 Realm 管理脚本？"; then
        run_remote_bash "https://raw.githubusercontent.com/wcwq98/realm/main/realm.sh" "wcwq98/realm"
    fi
    pause
}
