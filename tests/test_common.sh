#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"

assert_true() { "$@" || { printf '断言失败：%s\n' "$*" >&2; exit 1; }; }
assert_false() { if "$@"; then printf '预期失败但成功：%s\n' "$*" >&2; exit 1; fi; }

assert_true validate_port 1
assert_true validate_port 65535
assert_false validate_port 0
assert_false validate_port 65536
assert_false validate_port abc
assert_true validate_port_range 40000 50000
assert_false validate_port_range 50000 40000
assert_true validate_hostname_or_ip example.com
assert_true validate_hostname_or_ip 2001:db8::1
assert_false validate_hostname_or_ip '-bad'
assert_false validate_hostname_or_ip 'bad target'

curl() { return 22; }
[[ -z "$(get_public_ip 6)" ]] || { printf 'IPv6 失败应返回空结果。\n' >&2; exit 1; }

ip() {
    if [[ "$*" == "-4 -o addr show scope global" ]]; then
        printf '2: ens3    inet 198.51.100.10/24 scope global ens3\n3: warp0   inet 100.64.0.2/32 scope global warp0\n'
    elif [[ "$*" == "-4 route get"* ]]; then
        printf '1.1.1.1 dev warp0 src 100.64.0.2\n'
    fi
}
[[ "$(detect_inbound_interface 4)" == "ens3" ]] || { printf '应优先选择物理公网接口。\n' >&2; exit 1; }

printf 'test_common: PASS\n'
