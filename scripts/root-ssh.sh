#!/usr/bin/env bash

ROOT_SSH_DROPIN="${ROOT_SSH_DROPIN:-/etc/ssh/sshd_config.d/99-vps-tools-root.conf}"

root_ssh_reload() {
    local service
    service="$(service_name_for_ssh)" || { error "找不到 ssh/sshd systemd 服务。"; return 1; }
    systemctl reload "$service" 2>/dev/null || systemctl restart "$service"
}

root_ssh_set_password() {
    local password password_again
    read -r -s -p "请输入新的 Root 密码: " password; printf '\n'
    read -r -s -p "请再次输入 Root 密码: " password_again; printf '\n'
    [[ -n "$password" && "$password" == "$password_again" ]] || { error "密码为空或两次输入不一致。"; return 1; }
    printf 'root:%s\n' "$password" | chpasswd
    local status=$?
    unset password password_again
    [[ "$status" -eq 0 ]] && success "Root 密码已修改。"
    return "$status"
}

root_ssh_enable() {
    local sshd_bin temp backup=""
    require_root || return 1
    sshd_bin="$(command -v sshd)" || { error "未找到 sshd。"; return 1; }
    "$sshd_bin" -t || { error "现有 SSH 配置校验失败，未修改。"; return 1; }
    mkdir -p /etc/ssh/sshd_config.d
    if [[ -e "$ROOT_SSH_DROPIN" ]]; then
        backup="${ROOT_SSH_DROPIN}.vps-tools-rollback"
        cp -a "$ROOT_SSH_DROPIN" "$backup"
        backup_file "$ROOT_SSH_DROPIN" "$VPS_TOOLS_ETC/backups/ssh" || return 1
    fi
    temp="$(mktemp)" || return 1
    printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' >"$temp"
    install -m 0644 "$temp" "$ROOT_SSH_DROPIN"
    rm -f "$temp"
    if ! "$sshd_bin" -t; then
        if [[ -n "$backup" ]]; then
            mv -f "$backup" "$ROOT_SSH_DROPIN"
        else
            rm -f "$ROOT_SSH_DROPIN"
        fi
        error "新配置校验失败，已回滚。"
        return 1
    fi
    if ! "$sshd_bin" -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null | grep -q '^permitrootlogin yes$'; then
        if [[ -n "$backup" ]]; then
            mv -f "$backup" "$ROOT_SSH_DROPIN"
        else
            rm -f "$ROOT_SSH_DROPIN"
        fi
        error "Drop-in 未被 sshd 加载，已撤销；请检查主配置中的 Include。"
        return 1
    fi
    [[ -z "$backup" ]] || rm -f "$backup"
    root_ssh_set_password || return 1
    root_ssh_reload || return 1
    success "Root 密码 SSH 登录已启用。请保持当前会话，并在新终端验证后再退出。"
}

root_ssh_show() {
    local sshd_bin
    sshd_bin="$(command -v sshd)" || { error "未找到 sshd。"; return 1; }
    printf '[VPS Tools 配置]\n'
    if [[ -f "$ROOT_SSH_DROPIN" ]]; then cat "$ROOT_SSH_DROPIN"; else printf '未创建\n'; fi
    printf '\n[sshd 实际配置]\n'
    "$sshd_bin" -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null | grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication) '
}

root_ssh_restore() {
    local sshd_bin rollback
    require_root || return 1
    [[ -f "$ROOT_SSH_DROPIN" ]] || { info "VPS Tools SSH 配置不存在。"; return 0; }
    confirm "仅删除 99-vps-tools-root.conf 并恢复系统原有策略？" || return 0
    sshd_bin="$(command -v sshd)" || return 1
    rollback="$(mktemp)" || return 1
    cp -a "$ROOT_SSH_DROPIN" "$rollback"
    backup_file "$ROOT_SSH_DROPIN" "$VPS_TOOLS_ETC/backups/ssh" || return 1
    rm -f "$ROOT_SSH_DROPIN"
    if ! "$sshd_bin" -t; then
        install -m 0644 "$rollback" "$ROOT_SSH_DROPIN"
        rm -f "$rollback"
        error "删除后 SSH 配置无效，已恢复。"
        return 1
    fi
    rm -f "$rollback"
    root_ssh_reload && success "已移除 VPS Tools 的 SSH 覆盖配置。"
}

module_main() {
    local choice
    while true; do
        title "Root SSH 管理"
        printf '1. 启用 Root + 密码 SSH 登录\n2. 修改 Root 密码\n3. 查看 SSH 当前配置\n4. 恢复 VPS Tools SSH 配置\n0. 返回\n\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) root_ssh_enable; pause ;;
            2) require_root && root_ssh_set_password; pause ;;
            3) root_ssh_show; pause ;;
            4) root_ssh_restore; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
