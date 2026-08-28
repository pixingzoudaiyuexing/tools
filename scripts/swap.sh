#!/usr/bin/env bash

SWAP_FILE="${SWAP_FILE:-/swapfile}"

swap_show() {
    free -h
    printf '\n'
    swapon --show 2>/dev/null || true
}

swap_update_fstab() {
    local mode="$1" temp
    backup_file /etc/fstab "$VPS_TOOLS_ETC/backups/swap" || return 1
    temp="$(mktemp)" || return 1
    awk -v path="$SWAP_FILE" '$1 != path {print}' /etc/fstab >"$temp"
    [[ "$mode" == "add" ]] && printf '%s none swap sw 0 0\n' "$SWAP_FILE" >>"$temp"
    install -m 0644 "$temp" /etc/fstab
    rm -f "$temp"
}

swap_create() {
    local choice size_mb custom new_file available_mb
    require_root || return 1
    if [[ "$(systemd-detect-virt 2>/dev/null || true)" == "openvz" ]]; then
        warn "OpenVZ 通常不允许客户机创建 Swap，请由服务商侧配置。"
        return 1
    fi
    printf '1. 512 MB\n2. 1 GB\n3. 2 GB\n4. 4 GB\n5. 8 GB\n6. 自定义\n'
    read -r -p "请选择大小: " choice
    case "$choice" in
        1) size_mb=512 ;; 2) size_mb=1024 ;; 3) size_mb=2048 ;; 4) size_mb=4096 ;; 5) size_mb=8192 ;;
        6) read -r -p "请输入 MB 数: " custom; validate_positive_integer "$custom" || { error "大小无效。"; return 1; }; size_mb="$custom" ;;
        *) error "无效选项。"; return 1 ;;
    esac
    available_mb="$(df -Pm / | awk 'NR == 2 {print $4}')"
    ((10#$available_mb > 10#$size_mb + 128)) || { error "磁盘可用空间不足。"; return 1; }
    [[ ! -e "$SWAP_FILE" ]] || confirm "$SWAP_FILE 已存在，确认替换？" || return 0
    new_file="${SWAP_FILE}.vps-tools-new"
    rm -f "$new_file"
    if ! fallocate -l "${size_mb}M" "$new_file" 2>/dev/null; then
        dd if=/dev/zero of="$new_file" bs=1M count="$size_mb" status=progress || { rm -f "$new_file"; return 1; }
    fi
    chmod 600 "$new_file"
    mkswap "$new_file" >/dev/null || { rm -f "$new_file"; return 1; }
    swapoff "$SWAP_FILE" 2>/dev/null || true
    mv -f "$new_file" "$SWAP_FILE"
    swapon "$SWAP_FILE" || return 1
    swap_update_fstab add || return 1
    success "已配置 ${size_mb} MB Swap。"
    swap_show
}

swap_delete() {
    require_root || return 1
    [[ -e "$SWAP_FILE" ]] || { info "$SWAP_FILE 不存在。"; return 0; }
    confirm "确认删除 VPS Tools 管理的 ${SWAP_FILE}？" || return 0
    swapoff "$SWAP_FILE" 2>/dev/null || true
    swap_update_fstab delete || return 1
    rm -f -- "$SWAP_FILE"
    success "已删除 ${SWAP_FILE}，其他 Swap 未受影响。"
    swap_show
}

module_main() {
    local choice
    while true; do
        title "Swap 管理"
        printf '1. 查看当前 Swap\n2. 添加 / 修改 Swap\n3. 删除 Swap\n0. 返回\n\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) swap_show; pause ;;
            2) swap_create; pause ;;
            3) swap_delete; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
