#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=scripts/ai-check.sh
. "$ROOT/scripts/ai-check.sh"

TEST_OUTPUT="$TMP/args"
export TEST_OUTPUT

download_file() {
    local _url="$1" destination="$2"
    cat >"$destination" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$TEST_OUTPUT"
SCRIPT
}

run_ai_check >/dev/null
[[ "$(cat "$TEST_OUTPUT")" == "-r 5" ]]

grep -q 'adsorgcn/vpscheck/main/vpscheck.sh' "$ROOT/scripts/ai-check.sh"
grep -q 'ChatGPT / OpenAI API / Gemini / Claude' "$ROOT/scripts/ai-check.sh"

printf 'AI 服务检测入口测试通过。\n'
