#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$ROOT/scripts/reality-web443.sh"
grep -Fq '3. REALITY 443 + 网站 HTTPS 复用' "$ROOT/tools.sh"
grep -Fq '3) load_module reality-web443' "$ROOT/tools.sh"
grep -Fq 'https://raw.githubusercontent.com/pixingzoudaiyuexing/reality-web443-setup/main/reality-web443-setup.sh' "$ROOT/scripts/reality-web443.sh"
grep -Fq 'run_remote_bash "$REALITY_WEB443_SETUP_URL"' "$ROOT/scripts/reality-web443.sh"
grep -Fq 'confirm "确认启动 REALITY 443 + 网站 HTTPS 复用部署脚本？"' "$ROOT/scripts/reality-web443.sh"

printf 'REALITY web443 工具箱入口测试通过。\n'
