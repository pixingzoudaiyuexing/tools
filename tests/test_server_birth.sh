#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/server-birth.sh"

# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=scripts/server-birth.sh
. "$SCRIPT"

declare -F module_main >/dev/null
declare -F server_birth_run >/dev/null
declare -F server_birth_journal_conflicts_with_boot >/dev/null
declare -F server_birth_abs_diff >/dev/null
declare -F server_birth_detect_cloud >/dev/null
declare -F server_birth_probe_provider_metadata >/dev/null

# Journal 晚于当前启动时间必须被判定为冲突，不能继续用于首次启动估算。
server_birth_journal_conflicts_with_boot 1000 1200
if server_birth_journal_conflicts_with_boot 1200 1000; then
    printf '早于当前启动的 Journal 不应被判定为时间冲突。\n' >&2
    exit 1
fi
if server_birth_journal_conflicts_with_boot 1000 1050; then
    printf '允许 60 秒时间边界，50 秒差值不应判定冲突。\n' >&2
    exit 1
fi

[[ "$(server_birth_abs_diff 100 160)" == "60" ]]
[[ "$(server_birth_abs_diff 160 100)" == "60" ]]

for expected in \
    '当前这次启动时间（确定事实）' \
    '云厂商识别 / 官方实例 Metadata' \
    'Cloud-init 当前实例状态' \
    'Cloud-init 历史日志（含轮转日志）' \
    'systemd Journal 启动历史' \
    'wtmp / reboot 历史（含 wtmp.1）' \
    '根文件系统创建时间' \
    'machine-id / SSH Host Key' \
    '系统安装 / 软件包历史' \
    '云 Guest Agent 辅助记录' \
    '时间关系交叉校验' \
    '综合判断' \
    'Asia/Shanghai'; do
    grep -q "$expected" "$SCRIPT"
done

# 强/中/弱证据必须都存在，避免以后又退化成“最早 Journal = 首次启动”。
grep -q 'pendingTime' "$SCRIPT"
grep -q 'timeCreated' "$SCRIPT"
grep -q '/var/lib/cloud/instance' "$SCRIPT"
grep -q '/sem' "$SCRIPT"
grep -q 'cloud-init.log' "$SCRIPT"
grep -q '/var/log/wtmp.1' "$SCRIPT"
grep -q 'Filesystem created:' "$SCRIPT"
grep -q '/etc/machine-id' "$SCRIPT"
grep -q 'ssh_host_.*_key' "$SCRIPT"
grep -q '/var/log/installer' "$SCRIPT"
grep -q '/var/log/dpkg.log' "$SCRIPT"
grep -q '/var/log/waagent.log' "$SCRIPT"
grep -q '/var/log/google-guest-agent.log' "$SCRIPT"
grep -q 'Journal 已截断，排除' "$SCRIPT"
grep -q '不能等同于云实例购买或创建时间' "$SCRIPT"

# 不允许读取常见的云实例角色/服务账号凭据。
if grep -nE 'iam/security-credentials|service-accounts/default/token|security-credentials/' "$SCRIPT" >/dev/null; then
    printf '服务器时间检测不得读取云角色或 Service Account 凭据。\n' >&2
    exit 1
fi

# 该模块承诺只读，不允许加入常见的系统修改命令。
if grep -nE '(^|[[:space:]])(apt|apt-get|dnf|yum|apk)[[:space:]]|systemctl[[:space:]]+(start|stop|restart|enable|disable)|sysctl[[:space:]]+-w|sed[[:space:]]+-i|(^|[[:space:]])(rm|mv|cp|chmod|chown)[[:space:]]' "$SCRIPT" >/dev/null; then
    printf '服务器首次启动时间检测模块必须保持只读。\n' >&2
    exit 1
fi

printf '服务器首次启动时间交叉校验测试通过。\n'
