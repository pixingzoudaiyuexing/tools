#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 不允许再把 INT/TERM 与 cleanup 绑在同一个 trap 上，否则 Ctrl+C 只清理不退出。
! grep -Fq 'trap cleanup EXIT INT TERM' "$ROOT/tools.sh"
grep -Fq 'trap cleanup EXIT' "$ROOT/tools.sh"
grep -Fq 'trap handle_interrupt INT' "$ROOT/tools.sh"
grep -Fq 'trap handle_terminate TERM' "$ROOT/tools.sh"
grep -Fq "trap 'exit 130' INT" "$ROOT/tools.sh"
grep -Fq "trap 'exit 143' TERM" "$ROOT/tools.sh"

# 在 Linux/coreutils 环境实际给阻塞中的主菜单发送 SIGINT，必须以 130 退出。
if command -v timeout >/dev/null 2>&1; then
    output="$(mktemp)"
    trap 'rm -f "$output"' EXIT
    set +e
    timeout --preserve-status -s INT 1 bash "$ROOT/tools.sh" < <(sleep 3) >"$output" 2>&1
    status=$?
    set -e
    [[ "$status" -eq 130 ]] || { printf 'SIGINT 退出码应为 130，实际为 %s。\n' "$status" >&2; exit 1; }
    grep -Fq '已退出 VPS Tools。' "$output"
fi

printf '信号处理测试通过。\n'
