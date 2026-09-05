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

for expected in \
    '当前这次启动时间' \
    'systemd 启动历史' \
    '当前保留的最早 Journal 日志' \
    'wtmp / reboot 历史' \
    '根文件系统创建时间' \
    'Cloud-init 首次运行记录' \
    'Cloud-init 历史启动记录' \
    '云厂商 / Cloud-init 数据源' \
    'Cloud Instance ID' \
    'machine-id 时间' \
    '综合判断' \
    'Asia/Shanghai'; do
    grep -q "$expected" "$SCRIPT"
done

grep -q 'DataSourceAliYun' "$SCRIPT"
grep -q 'DataSourceEc2' "$SCRIPT"
grep -q 'DataSourceAzure' "$SCRIPT"
grep -q 'DataSourceGoogle' "$SCRIPT"
grep -q 'OpenStack' "$SCRIPT"
grep -q 'Filesystem created:' "$SCRIPT"

# 该模块承诺只读，不允许加入常见的系统修改命令。
if grep -nE '(^|[[:space:]])(apt|apt-get|dnf|yum|apk)[[:space:]]|systemctl[[:space:]]+(start|stop|restart|enable|disable)|sysctl[[:space:]]+-w|sed[[:space:]]+-i|(^|[[:space:]])(rm|mv|cp|chmod|chown)[[:space:]]' "$SCRIPT" >/dev/null; then
    printf '服务器首次启动时间检测模块必须保持只读。\n' >&2
    exit 1
fi

printf '服务器首次启动时间检测静态测试通过。\n'
