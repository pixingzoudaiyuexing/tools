#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export DDNS_DIR="$TEST_DIR/ddns" DDNS_CONFIG="$TEST_DIR/ddns/config.yaml"

# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=scripts/ddns.sh
. "$ROOT/scripts/ddns.sh"
get_cloudflare_warp_state() { printf 'off\n'; }

ddns_write_config <<'INPUT' >/dev/null
1
fixture-token
fixture-token
n

v6.example.com
INPUT

ruby -e 'require "yaml"; data=YAML.safe_load(File.read(ARGV[0])); abort unless data["dnsconf"][0]["ipv6"]["enable"] == true; abort unless data["dnsconf"][0]["dns"]["name"] == "cloudflare"' "$DDNS_CONFIG"
[[ "$(stat -f '%Lp' "$DDNS_CONFIG" 2>/dev/null || stat -c '%a' "$DDNS_CONFIG")" == "600" ]]
grep -Fq 'notallowwanaccess: true' "$DDNS_CONFIG"

printf 'test_ddns: PASS\n'
