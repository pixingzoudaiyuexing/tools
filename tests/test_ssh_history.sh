#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/root-ssh.sh"

# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=scripts/root-ssh.sh
. "$SCRIPT"

for fn in \
    root_ssh_history_show \
    root_ssh_history_source_report \
    root_ssh_history_clear_local_now \
    root_ssh_history_clear_journal \
    root_ssh_history_install_timer \
    root_ssh_history_disable_timer \
    root_ssh_history_auto_menu \
    root_ssh_history_menu; do
    declare -F "$fn" >/dev/null
 done

for expected in \
    'systemd journal' \
    '/var/log/auth.log' \
    '/var/log/secure' \
    '/var/log/wtmp' \
    '/var/log/btmp' \
    '/var/log/lastlog' \
    '/var/log/audit/audit.log' \
    '/var/log/fail2ban.log' \
    'SSH_CLIENT' \
    'SSH_CONNECTION' \
    'VPC Flow Logs' \
    '远程日志服务器'; do
    grep -q "$expected" "$SCRIPT"
done

grep -q 'journalctl --vacuum-time=1s' "$SCRIPT"
grep -q 'systemd Journal（全局，谨慎）' "$SCRIPT"
grep -q '自动模式只清理本机认证/登录文件，不自动清 systemd journal / auditd' "$SCRIPT"

# 自动清理脚本的 heredoc 不允许包含 Journal 或 auditd 清理命令。
cleaner_block="$(awk '/^    cat >"\$ROOT_SSH_HISTORY_CLEANER" <<.CLEANER./{flag=1; next} /^CLEANER$/{flag=0} flag' "$SCRIPT")"
[[ -n "$cleaner_block" ]]
if grep -Eq 'journalctl|/var/log/audit|auditctl|systemctl.*auditd' <<<"$cleaner_block"; then
    printf '自动 SSH 登录记录清理不应删除 Journal 或 auditd。\n' >&2
    exit 1
fi

for expected in auth.log secure wtmp btmp lastlog fail2ban.log; do
    grep -q "$expected" <<<"$cleaner_block"
done

printf 'SSH 登录 IP / 记录管理静态测试通过。\n'
