#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if grep -RInE --include='*.sh' \
    'nft[[:space:]]+flush[[:space:]]+ruleset|swapoff[[:space:]]+-a|docker[[:space:]]+system[[:space:]]+prune|systemctl[[:space:]]+(disable|stop)[[:space:]]+firewalld' \
    "$ROOT"; then
    printf '发现禁止的危险命令。\n' >&2
    exit 1
fi

grep -Fq "awk -v marker=\"\$id\" '\$NF != marker {print}'" "$ROOT/scripts/temp-ssh-key.sh"
grep -Fq 'nft delete table ip vps_tools_porthop' "$ROOT/scripts/porthop.sh"
grep -Fq 'nft delete table ip6 vps_tools_porthop' "$ROOT/scripts/porthop.sh"

if grep -RInE --include='*.sh' --exclude-dir=tests \
    "(api[_-]?key|token|password)[[:space:]]*=[[:space:]]*['\"][A-Za-z0-9_-]{16,}" \
    "$ROOT"; then
    printf '疑似发现写入脚本源码的敏感凭证。\n' >&2
    exit 1
fi

printf 'test_security: PASS\n'
