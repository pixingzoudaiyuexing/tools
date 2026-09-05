#!/usr/bin/env bash

# Linux / 云服务器首次启动时间检查。
# 只读取系统信息，不修改任何配置。

server_birth_line() {
    printf '%s\n' '------------------------------------------------------------'
}

server_birth_section() {
    printf '\n'
    server_birth_line
    printf '%b%s%b\n' "$COLOR_BLUE" "$1" "$COLOR_RESET"
    server_birth_line
}

server_birth_value() {
    printf '%-26s %s\n' "$1" "$2"
}

server_birth_run() {
    local hostname_now os kernel timezone current_boot
    local journal_first="" root_dev root_fs fs_created=""
    local cloud_log="/var/log/cloud-init.log" cloud_first="" cloud_first_line=""
    local instance_id beijing

    title "Linux 云服务器首次启动时间检测"
    info "只读取系统信息，不修改任何配置。"

    server_birth_section "1. 基础信息"

    hostname_now="$(hostname 2>/dev/null || printf '未知')"
    os="$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
    kernel="$(uname -r 2>/dev/null || printf '未知')"
    timezone="$(timedatectl show -p Timezone --value 2>/dev/null || true)"

    server_birth_value "主机名:" "$hostname_now"
    server_birth_value "系统:" "${os:-未知}"
    server_birth_value "内核:" "$kernel"
    server_birth_value "系统时区:" "${timezone:-未知}"

    server_birth_section "2. 当前这次启动时间"

    current_boot="$(uptime -s 2>/dev/null || true)"
    if [[ -n "$current_boot" ]]; then
        server_birth_value "当前启动时间:" "$current_boot"
    else
        printf '无法通过 uptime 获取。\n'
    fi

    printf '\n'
    uptime -p 2>/dev/null || true

    server_birth_section "3. systemd 启动历史"

    if command_exists journalctl; then
        journalctl --list-boots --no-pager 2>/dev/null || printf '没有可用的 journal 启动历史。\n'
    else
        printf '系统没有 journalctl。\n'
    fi

    server_birth_section "4. 当前保留的最早 Journal 日志"

    if command_exists journalctl; then
        journal_first="$(journalctl --no-pager -o short-iso 2>/dev/null | sed -n '1p' || true)"
        if [[ -n "$journal_first" ]]; then
            printf '%s\n' "$journal_first"
        else
            printf '没有找到 Journal 日志。\n'
        fi
    else
        printf '系统没有 journalctl。\n'
    fi

    server_birth_section "5. wtmp / reboot 历史"

    if command_exists last; then
        last -x reboot 2>/dev/null | tail -20 || true
        printf '\n'
        last 2>/dev/null | grep 'wtmp begins' | tail -1 || true
    else
        printf '没有 last 命令。\n'
    fi

    server_birth_section "6. 根文件系统创建时间"

    root_dev="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    root_fs="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"

    server_birth_value "根分区:" "${root_dev:-未知}"
    server_birth_value "文件系统:" "${root_fs:-未知}"

    if [[ "$root_fs" == "ext4" || "$root_fs" == "ext3" || "$root_fs" == "ext2" ]]; then
        if command_exists tune2fs && [[ -n "$root_dev" ]]; then
            fs_created="$(tune2fs -l "$root_dev" 2>/dev/null \
                | grep 'Filesystem created:' \
                | sed 's/Filesystem created:[[:space:]]*//' || true)"
            if [[ -n "$fs_created" ]]; then
                server_birth_value "Filesystem created:" "$fs_created"
            else
                printf '未获取到文件系统创建时间。\n'
            fi
        else
            printf '没有 tune2fs 或无法识别根分区。\n'
        fi
    else
        printf '当前根文件系统不是 ext2/ext3/ext4，跳过 tune2fs。\n'
    fi

    server_birth_section "7. Cloud-init 首次运行记录"

    if [[ -f "$cloud_log" ]]; then
        cloud_first_line="$(grep -m1 'Cloud-init v' "$cloud_log" 2>/dev/null || true)"
        if [[ -n "$cloud_first_line" ]]; then
            printf '%b找到 Cloud-init 最早记录：%b\n' "$COLOR_GREEN" "$COLOR_RESET"
            printf '%s\n' "$cloud_first_line"
            cloud_first="$(printf '%s\n' "$cloud_first_line" \
                | sed -n 's/^\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9:]\{8\}\).*/\1/p')"
        else
            printf '存在 cloud-init.log，但没有找到 Cloud-init v 启动记录。\n'
        fi

        printf '\nCloud-init 日志文件时间：\n'
        stat "$cloud_log" 2>/dev/null | grep -E 'Birth:|Modify:' || true
    else
        printf '没有找到 %s\n' "$cloud_log"
    fi

    server_birth_section "8. Cloud-init 历史启动记录"

    if [[ -f "$cloud_log" ]]; then
        grep 'Cloud-init v' "$cloud_log" 2>/dev/null || printf '没有找到记录。\n'
    else
        printf '没有 Cloud-init 日志。\n'
    fi

    server_birth_section "9. 云厂商 / Cloud-init 数据源"

    if [[ -f "$cloud_log" ]]; then
        grep -m3 -E \
            'DataSourceAliYun|Looking for data source.*AliYun|DataSourceEc2|DataSourceAzure|DataSourceGoogle|OpenStack' \
            "$cloud_log" 2>/dev/null || printf '没有从 cloud-init.log 中明确识别云厂商。\n'
    else
        printf '没有 Cloud-init 日志。\n'
    fi

    server_birth_section "10. Cloud Instance ID"

    if [[ -f /var/lib/cloud/data/instance-id ]]; then
        instance_id="$(cat /var/lib/cloud/data/instance-id 2>/dev/null || true)"
        server_birth_value "Instance ID:" "${instance_id:-未知}"
    else
        printf '没有找到 /var/lib/cloud/data/instance-id\n'
    fi

    server_birth_section "11. machine-id 时间"

    if [[ -f /etc/machine-id ]]; then
        stat /etc/machine-id 2>/dev/null | grep -E 'Birth:|Modify:|Change:' || true
    else
        printf '没有 /etc/machine-id\n'
    fi

    server_birth_section "12. 综合判断"

    printf '以下时间的意义不同：\n\n'
    if [[ -n "$fs_created" ]]; then
        server_birth_value "文件系统创建:" "$fs_created"
    fi
    if [[ -n "$cloud_first" ]]; then
        server_birth_value "Cloud-init 最早启动:" "$cloud_first UTC"
    fi
    if [[ -n "$current_boot" ]]; then
        server_birth_value "当前启动:" "$current_boot"
    fi

    printf '\n'
    server_birth_line

    if [[ -n "$cloud_first" ]]; then
        printf '%b最可能的服务器 / 系统首次云端启动时间：%b\n\n' "$COLOR_GREEN" "$COLOR_RESET"
        printf '    %b%s UTC%b\n\n' "$COLOR_GREEN" "$cloud_first" "$COLOR_RESET"

        if command_exists date; then
            beijing="$(TZ=Asia/Shanghai date -d "${cloud_first} UTC" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || true)"
            if [[ -n "$beijing" ]]; then
                printf '北京时间：\n\n'
                printf '    %b%s%b\n\n' "$COLOR_GREEN" "$beijing" "$COLOR_RESET"
            fi
        fi

        printf '%b判断依据：Cloud-init 是识别云服务器首次初始化非常有价值的记录。%b\n\n' "$COLOR_YELLOW" "$COLOR_RESET"
        printf '注意：如果系统盘曾被克隆、制作快照、自定义镜像或迁移，\n'
        printf '这个时间可能属于原始系统，而不是当前云实例的购买日期。\n'
    elif [[ -n "$journal_first" ]]; then
        printf '%b未找到 Cloud-init 首次记录。%b\n\n' "$COLOR_YELLOW" "$COLOR_RESET"
        printf '只能使用最早 Journal 作为参考：\n%s\n\n' "$journal_first"
        printf '可信度：中等\n'
    else
        printf '%b无法从本机日志可靠推测首次启动时间。%b\n' "$COLOR_RED" "$COLOR_RESET"
    fi

    server_birth_line
    printf '\n检测完成。\n'
}

module_main() {
    server_birth_run
    pause
}
