#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for script in "$ROOT/tools.sh" "$ROOT/node" "$ROOT/lib/common.sh" "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh; do
    bash -n "$script"
done

for test_script in "$ROOT"/tests/test_*.sh; do
    bash "$test_script"
done

NO_COLOR=1 VPS_TOOLS_NONINTERACTIVE=1 bash "$ROOT/tools.sh" <<'INPUT' >/dev/null
99
0
INPUT

printf '全部测试通过。\n'
