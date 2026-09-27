#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

grep -q 'docker_ensure_compose_v2' "$ROOT/scripts/docker.sh"
grep -q 'docker-compose-plugin' "$ROOT/scripts/docker.sh"
grep -q 'docker compose version' "$ROOT/scripts/docker.sh"
grep -q '官方方式安装 Docker + Compose V2' "$ROOT/scripts/docker.sh"

printf 'Docker Compose V2 安装保障测试通过。\n'
