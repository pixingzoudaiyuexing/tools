#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=scripts/media.sh
. "$ROOT/scripts/media.sh"

TEST_OUTPUT="$TMP/args"
export TEST_OUTPUT

download_file() {
    local _url="$1" destination="$2"
    cat >"$destination" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$TEST_OUTPUT"
SCRIPT
}

run_ipquality -4 >/dev/null
[[ "$(cat "$TEST_OUTPUT")" == "-4" ]]

run_ipquality -6 >/dev/null
[[ "$(cat "$TEST_OUTPUT")" == "-6" ]]

run_ipquality >/dev/null
[[ "$(cat "$TEST_OUTPUT")" == "" ]]

grep -q 'https://IP.Check.Place' "$ROOT/scripts/media.sh"
grep -q 'IP 质量体检（IPv4 + IPv6）' "$ROOT/scripts/media.sh"
grep -q 'IP 质量体检（仅 IPv4）' "$ROOT/scripts/media.sh"
grep -q 'IP 质量体检（仅 IPv6）' "$ROOT/scripts/media.sh"
grep -q 'https://check.unlock.media' "$ROOT/scripts/media.sh"

printf 'IPQuality 快捷入口测试通过。\n'
