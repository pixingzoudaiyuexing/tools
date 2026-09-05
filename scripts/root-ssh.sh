#!/usr/bin/env bash

ROOT_SSH_DROPIN="${ROOT_SSH_DROPIN:-/etc/ssh/sshd_config.d/00-vps-tools-root.conf}"
ROOT_SSH_LEGACY_DROPIN="${ROOT_SSH_LEGACY_DROPIN:-/etc/ssh/sshd_config.d/99-vps-tools-root.conf}"
ROOT_SSH_HISTORY_CLEANER="${ROOT_SSH_HISTORY_CLEANER:-/usr/local/lib/vps-tools/ssh-login-cleanup.sh}"
ROOT_SSH_HISTORY_SERVICE="${ROOT_SSH_HISTORY_SERVICE:-/etc/systemd/system/vps-tools-ssh-login-cleanup.service}"
ROOT_SSH_HISTORY_TIMER="${ROOT_SSH_HISTORY_TIMER:-/etc/systemd/system/vps-tools-ssh-login-cleanup.timer}"

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
    local sshd_bin temp backup="" legacy_backup="" effective
    require_root || return 1
    sshd_bin="$(command -v sshd)" || { error "未找到 sshd。"; return 1; }
    "$sshd_bin" -t || { error "现有 SSH 配置校验失败，未修改。"; return 1; }
    mkdir -p /etc/ssh/sshd_config.d
    if [[ -e "$ROOT_SSH_DROPIN" ]]; then
        backup="${ROOT_SSH_DROPIN}.vps-tools-rollback"
        cp -a "$ROOT_SSH_DROPIN" "$backup"
        backup_file "$ROOT_SSH_DROPIN" "$VPS_TOOLS_ETC/backups/ssh" || return 1
    fi
    if [[ -e "$ROOT_SSH_LEGACY_DROPIN" ]]; then
        legacy_backup="${ROOT_SSH_LEGACY_DROPIN}.vps-tools-rollback"
        cp -a "$ROOT_SSH_LEGACY_DROPIN" "$legacy_backup"
        backup_file "$ROOT_SSH_LEGACY_DROPIN" "$VPS_TOOLS_ETC/backups/ssh" || return 1
        rm -f "$ROOT_SSH_LEGACY_DROPIN"
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
        [[ -z "$legacy_backup" ]] || mv -f "$legacy_backup" "$ROOT_SSH_LEGACY_DROPIN"
        error "新配置校验失败，已回滚。"
        return 1
    fi
    effective="$("$sshd_bin" -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null || true)"
    if ! grep -q '^permitrootlogin yes$' <<<"$effective" || ! grep -q '^passwordauthentication yes$' <<<"$effective"; then
        if [[ -n "$backup" ]]; then
            mv -f "$backup" "$ROOT_SSH_DROPIN"
        else
            rm -f "$ROOT_SSH_DROPIN"
        fi
        [[ -z "$legacy_backup" ]] || mv -f "$legacy_backup" "$ROOT_SSH_LEGACY_DROPIN"
        error "Drop-in 未被 sshd 加载，已撤销；请检查主配置中的 Include。"
        return 1
    fi
    [[ -z "$backup" ]] || rm -f "$backup"
    [[ -z "$legacy_backup" ]] || rm -f "$legacy_backup"
    root_ssh_reload || return 1
    effective="$("$sshd_bin" -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null || true)"
    if ! grep -q '^permitrootlogin yes$' <<<"$effective" || ! grep -q '^passwordauthentication yes$' <<<"$effective"; then
        error "SSH 重载后有效配置不符合要求（PermitRootLogin/PasswordAuthentication）。"
        return 1
    fi
    root_ssh_set_password || return 1
    success "Root 密码 SSH 登录已启用。请保持当前会话，并在新终端验证后再退出。"
}

root_ssh_show() {
    local sshd_bin
    sshd_bin="$(command -v sshd)" || { error "未找到 sshd。"; return 1; }
    printf '[VPS Tools 配置]\n'
    if [[ -f "$ROOT_SSH_DROPIN" ]]; then cat "$ROOT_SSH_DROPIN"; else printf '未创建\n'; fi
    printf '\n[sshd 实际配置]\n'
    "$sshd_bin" -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null | grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication|port) '
}

root_ssh_restore() {
    local sshd_bin rollback legacy_rollback
    require_root || return 1
    [[ -f "$ROOT_SSH_DROPIN" || -f "$ROOT_SSH_LEGACY_DROPIN" ]] || { info "VPS Tools SSH 配置不存在。"; return 0; }
    confirm "仅删除 VPS Tools 的 SSH 覆盖配置并恢复系统原有策略？" || return 0
    sshd_bin="$(command -v sshd)" || return 1
    rollback="$(mktemp)" || return 1
    legacy_rollback="$(mktemp)" || return 1
    [[ ! -f "$ROOT_SSH_DROPIN" ]] || { cp -a "$ROOT_SSH_DROPIN" "$rollback"; backup_file "$ROOT_SSH_DROPIN" "$VPS_TOOLS_ETC/backups/ssh" || return 1; }
    [[ ! -f "$ROOT_SSH_LEGACY_DROPIN" ]] || { cp -a "$ROOT_SSH_LEGACY_DROPIN" "$legacy_rollback"; backup_file "$ROOT_SSH_LEGACY_DROPIN" "$VPS_TOOLS_ETC/backups/ssh" || return 1; }
    rm -f "$ROOT_SSH_DROPIN" "$ROOT_SSH_LEGACY_DROPIN"
    if ! "$sshd_bin" -t; then
        [[ -s "$rollback" ]] && install -m 0644 "$rollback" "$ROOT_SSH_DROPIN"
        [[ -s "$legacy_rollback" ]] && install -m 0644 "$legacy_rollback" "$ROOT_SSH_LEGACY_DROPIN"
        rm -f "$rollback"
        rm -f "$legacy_rollback"
        error "删除后 SSH 配置无效，已恢复。"
        return 1
    fi
    rm -f "$rollback"
    rm -f "$legacy_rollback"
    root_ssh_reload && success "已移除 VPS Tools 的 SSH 覆盖配置。"
}

root_ssh_history_show_auth_files() {
    local file shown=0
    for file in /var/log/auth.log /var/log/auth.log.1 /var/log/secure /var/log/secure-* /var/log/secure.*; do
        [[ -f "$file" ]] || continue
        case "$file" in *.gz) continue ;; esac
        shown=1
        printf '\n[%s]\n' "$file"
        grep -E 'sshd.*(Accepted|Failed|Invalid user|Connection closed|Disconnected from|authentication failure)' "$file" 2>/dev/null | tail -40 || true
    done
    for file in /var/log/auth.log.*.gz /var/log/secure*.gz; do
        [[ -f "$file" ]] || continue
        shown=1
        printf '\n[%s]\n' "$file"
        if command_exists zgrep; then
            zgrep -hE 'sshd.*(Accepted|Failed|Invalid user|Connection closed|Disconnected from|authentication failure)' "$file" 2>/dev/null | tail -30 || true
        fi
    done
    ((shown == 1)) || printf '没有找到 auth.log / secure SSH 记录。\n'
}

root_ssh_history_source_report() {
    local found=0
    printf '[本机可能记录 SSH 来源 IP 的位置]\n'

    if command_exists journalctl; then
        printf '✓ systemd journal：可能保存 ssh/sshd 成功、失败和断开记录\n'
        found=1
    fi
    [[ -e /var/log/auth.log || -e /var/log/secure ]] && { printf '✓ auth.log / secure：认证日志\n'; found=1; }
    [[ -e /var/log/wtmp ]] && { printf '✓ wtmp：成功登录历史（last）\n'; found=1; }
    [[ -e /var/log/btmp ]] && { printf '✓ btmp：失败登录历史（lastb）\n'; found=1; }
    [[ -e /var/log/lastlog ]] && { printf '✓ lastlog：每个用户最后一次登录来源\n'; found=1; }
    if [[ -e /var/log/audit/audit.log ]] || { command_exists systemctl && systemctl is-active --quiet auditd 2>/dev/null; }; then
        printf '✓ auditd：USER_AUTH / USER_LOGIN 等审计记录可能包含 addr=来源IP\n'
        found=1
    fi
    if [[ -e /var/log/fail2ban.log ]] || { command_exists systemctl && systemctl is-active --quiet fail2ban 2>/dev/null; }; then
        printf '✓ Fail2ban：失败尝试、Ban/Unban 记录可能包含来源 IP\n'
        found=1
    fi
    if command_exists rsyslogd || [[ -d /etc/rsyslog.d ]]; then
        printf '△ rsyslog：如果配置了远程转发，SSH 日志可能已经发到其他服务器\n'
    fi
    if command_exists loginctl; then
        printf '△ systemd-logind：当前在线会话可能暴露 RemoteHost\n'
    fi
    printf '△ 当前会话：who / ss / SSH_CLIENT / SSH_CONNECTION / 进程环境在会话结束前仍可看到来源 IP\n'
    printf '△ 防火墙 / conntrack / IDS / 安全代理：运行期间可能暂存或记录来源 IP\n'
    printf '△ 云厂商侧：VPC Flow Logs、防火墙日志、堡垒机、云审计、远程 SIEM 不在本机，VPS Tools 无法删除\n'
    ((found == 1)) || printf '未发现常见持久化 SSH 登录日志文件。\n'
}

root_ssh_history_show() {
    title "SSH 登录 IP 记录"

    printf '[当前会话环境]\n'
    printf 'SSH_CLIENT=%s\n' "${SSH_CLIENT:-未设置}"
    printf 'SSH_CONNECTION=%s\n' "${SSH_CONNECTION:-未设置}"
    if command_exists who; then
        printf '\n[当前登录会话 / who]\n'
        who -u 2>/dev/null || true
    fi
    if command_exists loginctl; then
        printf '\n[systemd-logind 当前远程会话]\n'
        loginctl list-sessions --no-legend 2>/dev/null | while read -r sid _rest; do
            [[ -n "$sid" ]] || continue
            loginctl show-session "$sid" -p Name -p Remote -p RemoteHost -p Service --no-pager 2>/dev/null | paste -sd ' ' -
        done
    fi
    if command_exists ss; then
        printf '\n[当前 SSH TCP 连接]\n'
        ss -tnp 2>/dev/null | grep -E 'sshd|:22[[:space:]]' | tail -30 || printf '未检测到可识别的 SSH TCP 连接。\n'
    fi

    printf '\n[成功登录历史：wtmp / last]\n'
    if command_exists last; then
        last -Fai 2>/dev/null | grep -vE '^(reboot|shutdown|wtmp begins|$)' | head -50 || true
    else
        printf '没有 last 命令。\n'
    fi

    printf '\n[失败登录历史：btmp / lastb]\n'
    if command_exists lastb; then
        lastb -Fai 2>/dev/null | head -50 || true
    else
        printf '没有 lastb 命令。\n'
    fi

    printf '\n[每个用户最后一次登录：lastlog]\n'
    if command_exists lastlog; then
        lastlog 2>/dev/null | head -40 || true
    else
        printf '没有 lastlog 命令。\n'
    fi

    printf '\n[systemd journal 中的 ssh/sshd]\n'
    if command_exists journalctl; then
        journalctl -u ssh -u sshd --no-pager -n 300 2>/dev/null \
            | grep -E 'Accepted |Failed |Invalid user|Connection closed|Disconnected from|authentication failure' \
            | tail -80 || printf '没有找到匹配的 ssh/sshd Journal 记录。\n'
    else
        printf '系统没有 journalctl。\n'
    fi

    printf '\n[auth.log / secure]\n'
    root_ssh_history_show_auth_files

    printf '\n[auditd SSH / 登录审计]\n'
    if [[ -f /var/log/audit/audit.log ]]; then
        grep -E 'sshd|USER_AUTH|USER_LOGIN|USER_START|USER_END' /var/log/audit/audit.log 2>/dev/null | tail -60 || true
    else
        printf '没有找到 /var/log/audit/audit.log。\n'
    fi

    printf '\n[Fail2ban]\n'
    if [[ -f /var/log/fail2ban.log ]]; then
        grep -Ei 'sshd|Ban |Unban |Found ' /var/log/fail2ban.log 2>/dev/null | tail -60 || true
    else
        printf '没有找到 /var/log/fail2ban.log。\n'
    fi

    printf '\n'
    root_ssh_history_source_report
}

root_ssh_history_truncate_if_exists() {
    local file="$1"
    [[ -e "$file" ]] || return 0
    : >"$file" 2>/dev/null || return 1
}

root_ssh_history_remove_rotated() {
    local file
    for file in \
        /var/log/auth.log.* \
        /var/log/secure-* \
        /var/log/secure.* \
        /var/log/wtmp.* \
        /var/log/btmp.* \
        /var/log/lastlog.* \
        /var/log/fail2ban.log.*; do
        [[ -e "$file" ]] || continue
        rm -f -- "$file" || return 1
    done
}

root_ssh_history_clear_local_now() {
    local file failed=0
    require_root || return 1

    warn "此操作会删除本机认证/登录历史，不只包含你自己的 IP。"
    warn "会清理 auth.log/secure、wtmp、btmp、lastlog、Fail2ban 本地日志及其轮转文件。"
    warn "默认不会清理 systemd journal、auditd、syslog/messages 或任何云厂商/远程日志。"
    confirm "确认清理这些本机登录记录？" || return 0

    for file in /var/log/auth.log /var/log/secure /var/log/wtmp /var/log/btmp /var/log/lastlog /var/log/fail2ban.log; do
        root_ssh_history_truncate_if_exists "$file" || failed=1
    done
    root_ssh_history_remove_rotated || failed=1

    if ((failed == 0)); then
        success "本机常见认证/登录记录已清理。"
    else
        warn "部分文件清理失败，请检查权限或日志服务。"
    fi

    printf '\n仍可能保留来源 IP 的位置：\n'
    printf '- 当前 SSH 会话：who / loginctl / ss / SSH_CLIENT / SSH_CONNECTION（退出会话后消失）\n'
    printf '- systemd journal\n'
    printf '- auditd\n'
    printf '- syslog/messages 或自定义 rsyslog 路由\n'
    printf '- 远程日志服务器 / SIEM / 云厂商 VPC Flow Logs / 防火墙 / 堡垒机\n'
    return "$failed"
}

root_ssh_history_clear_journal() {
    require_root || return 1
    command_exists journalctl || { error "系统没有 journalctl。"; return 1; }

    warn "systemd journal 无法只删除 SSH 条目。"
    warn "继续会删除整台 VPS 当前保存的 Journal 历史，包括内核、网络、服务故障等非 SSH 日志。"
    confirm "确认执行全局 Journal 清理？" || return 0

    journalctl --rotate >/dev/null 2>&1 || { error "Journal rotate 失败。"; return 1; }
    journalctl --vacuum-time=1s >/dev/null 2>&1 || { error "Journal vacuum 失败。"; return 1; }
    success "已清理当前可删除的 systemd Journal 历史。"
    warn "auditd、远程日志和云厂商侧日志仍不会因此删除。"
}

root_ssh_history_write_cleaner() {
    mkdir -p "$(dirname "$ROOT_SSH_HISTORY_CLEANER")" || return 1
    cat >"$ROOT_SSH_HISTORY_CLEANER" <<'CLEANER'
#!/usr/bin/env bash
set -u

truncate_if_exists() {
    [[ -e "$1" ]] || return 0
    : >"$1" 2>/dev/null || true
}

for file in /var/log/auth.log /var/log/secure /var/log/wtmp /var/log/btmp /var/log/lastlog /var/log/fail2ban.log; do
    truncate_if_exists "$file"
done

for file in \
    /var/log/auth.log.* \
    /var/log/secure-* \
    /var/log/secure.* \
    /var/log/wtmp.* \
    /var/log/btmp.* \
    /var/log/lastlog.* \
    /var/log/fail2ban.log.*; do
    [[ -e "$file" ]] || continue
    rm -f -- "$file" 2>/dev/null || true
done

exit 0
CLEANER
    chmod 0755 "$ROOT_SSH_HISTORY_CLEANER"
}

root_ssh_history_install_timer() {
    local calendar="$1" label="$2"
    require_root || return 1
    command_exists systemctl || { error "自动清理需要 systemd。"; return 1; }

    warn "自动清理会周期性删除 auth.log/secure、wtmp、btmp、lastlog、Fail2ban 本地记录。"
    warn "它不会自动删除 Journal/auditd，因为那会连非 SSH 系统日志一起删除。"
    confirm "确认开启${label}自动清理？" || return 0

    root_ssh_history_write_cleaner || { error "写入自动清理脚本失败。"; return 1; }

    cat >"$ROOT_SSH_HISTORY_SERVICE" <<EOF
[Unit]
Description=VPS Tools SSH login history cleanup

[Service]
Type=oneshot
ExecStart=$ROOT_SSH_HISTORY_CLEANER
EOF

    cat >"$ROOT_SSH_HISTORY_TIMER" <<EOF
[Unit]
Description=VPS Tools SSH login history cleanup timer

[Timer]
OnCalendar=$calendar
Persistent=true
Unit=vps-tools-ssh-login-cleanup.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload || return 1
    systemctl enable --now vps-tools-ssh-login-cleanup.timer || return 1
    success "已开启${label}自动清理。"
    info "自动清理范围不包含 systemd journal / auditd / 远程或云厂商日志。"
}

root_ssh_history_disable_timer() {
    require_root || return 1
    command_exists systemctl || { error "未找到 systemd。"; return 1; }
    systemctl disable --now vps-tools-ssh-login-cleanup.timer >/dev/null 2>&1 || true
    rm -f "$ROOT_SSH_HISTORY_TIMER" "$ROOT_SSH_HISTORY_SERVICE" "$ROOT_SSH_HISTORY_CLEANER"
    systemctl daemon-reload >/dev/null 2>&1 || true
    success "SSH 登录记录自动清理已关闭。"
}

root_ssh_history_auto_menu() {
    local choice
    while true; do
        title "SSH 登录记录自动清理"
        printf '1. 查看自动清理状态\n'
        printf '2. 开启每小时自动清理\n'
        printf '3. 开启每天自动清理\n'
        printf '4. 立即执行一次自动清理脚本\n'
        printf '5. 关闭自动清理\n'
        printf '0. 返回\n\n'
        printf '说明：自动模式只清理本机认证/登录文件，不自动清 systemd journal / auditd。\n\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1)
                if command_exists systemctl; then
                    systemctl status vps-tools-ssh-login-cleanup.timer --no-pager -l 2>&1 || true
                    printf '\n'
                    systemctl list-timers vps-tools-ssh-login-cleanup.timer --no-pager 2>/dev/null || true
                else
                    printf '系统没有 systemd。\n'
                fi
                pause
                ;;
            2) root_ssh_history_install_timer 'hourly' '每小时'; pause ;;
            3) root_ssh_history_install_timer 'daily' '每天'; pause ;;
            4)
                require_root || { pause; continue; }
                if [[ -x "$ROOT_SSH_HISTORY_CLEANER" ]]; then
                    "$ROOT_SSH_HISTORY_CLEANER"
                    success "已执行一次本机登录记录清理。"
                else
                    warn "自动清理脚本尚未安装，请先开启每小时或每天自动清理。"
                fi
                pause
                ;;
            5) root_ssh_history_disable_timer; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}

root_ssh_history_menu() {
    local choice
    while true; do
        title "SSH 登录 IP / 记录管理"
        printf '1. 查看 SSH 登录 IP 记录\n'
        printf '2. 查看哪些位置可能记录 SSH 来源 IP\n'
        printf '3. 清理本机常见认证 / 登录记录\n'
        printf '4. 清理 systemd Journal（全局，谨慎）\n'
        printf '5. 自动清理管理\n'
        printf '0. 返回\n\n'
        printf '注意：远程日志服务器、SIEM、云厂商 VPC Flow Logs、防火墙和堡垒机日志无法从本机删除。\n\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) root_ssh_history_show; pause ;;
            2) root_ssh_history_source_report; pause ;;
            3) root_ssh_history_clear_local_now; pause ;;
            4) root_ssh_history_clear_journal; pause ;;
            5) root_ssh_history_auto_menu ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}

module_main() {
    local choice
    while true; do
        title "Root SSH 管理"
        printf '1. 启用 Root + 密码 SSH 登录\n'
        printf '2. 修改 Root 密码\n'
        printf '3. 查看 SSH 当前配置\n'
        printf '4. 恢复 VPS Tools SSH 配置\n'
        printf '5. SSH 登录 IP / 记录管理\n'
        printf '0. 返回\n\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) root_ssh_enable; pause ;;
            2) require_root && root_ssh_set_password; pause ;;
            3) root_ssh_show; pause ;;
            4) root_ssh_restore; pause ;;
            5) root_ssh_history_menu ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
