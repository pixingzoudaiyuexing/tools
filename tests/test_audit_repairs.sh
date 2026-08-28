#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

. "$ROOT/lib/common.sh"

# SSH fixture checks both effective booleans and migrates the legacy drop-in.
export ROOT_SSH_DROPIN="$TEST_DIR/ssh/00-vps-tools-root.conf" ROOT_SSH_LEGACY_DROPIN="$TEST_DIR/ssh/99-vps-tools-root.conf" VPS_TOOLS_ETC="$TEST_DIR/etc"
mkdir -p "$TEST_DIR/ssh" "$TEST_DIR/bin"
printf 'PasswordAuthentication no\n' > "$ROOT_SSH_LEGACY_DROPIN"
printf '#!/usr/bin/env bash\nif [[ "$1" == -T ]]; then printf "permitrootlogin yes\\npasswordauthentication yes\\npubkeyauthentication yes\\nport 22\\n"; fi\n' > "$TEST_DIR/bin/sshd"
chmod 755 "$TEST_DIR/bin/sshd"
PATH="$TEST_DIR/bin:$PATH"
. "$ROOT/scripts/root-ssh.sh"
require_root() { return 0; }
systemctl() { [[ "$1" == list-unit-files ]] && printf 'ssh.service enabled\n' || return 0; }
chpasswd() { return 0; }
root_ssh_enable <<'INPUT' >/dev/null
fixture-password
fixture-password
INPUT
[[ -f "$ROOT_SSH_DROPIN" && ! -e "$ROOT_SSH_LEGACY_DROPIN" ]] || exit 1

# AppleID wrapper passes a fixed replica count without leaking the key.
export APPLE_DIR="$TEST_DIR/apple"
download_file() {
    printf '#!/usr/bin/env bash\nprintf "%%s" "$REPLICAS" > "%s/replicas"\nmkdir -p "$APPLE_DIR"\nprintf "services:\\n  backend:\\n    deploy:\\n      replicas: 1\\n" > "$APPLE_DIR/docker-compose.yml"\n' "$TEST_DIR" > "$2"
}
require_root() { return 0; }
docker() { return 0; }
. "$ROOT/scripts/appleid.sh"
apple_install <<'INPUT' >/dev/null

fixture-api-key
fixture-api-key
node-1
INPUT
[[ "$(<"$TEST_DIR/replicas")" == 1 ]] || { printf 'AppleID replicas 未固定为 1。\n' >&2; exit 1; }

# Native IPv6 plus WARP IPv4 is detected independently of curl -4.
ip() {
    case "$*" in
        "-4 -o addr show scope global") printf '3: WARP    inet 100.64.0.2/32 scope global WARP\n' ;;
        "-6 -o addr show scope global") printf '2: ens3    inet6 2001:db8::1/64 scope global\n' ;;
    esac
}
get_public_ip() { [[ "$1" == 4 ]] && printf '203.0.113.9\n' || printf '2001:db8::1\n'; }
get_cloudflare_warp_state() { [[ "$1" == 4 ]] && printf 'on\n' || printf 'off\n'; }
. "$ROOT/scripts/warp.sh"
[[ -z "$(warp_native_address 4 || true)" ]] || exit 1
[[ "$(warp_native_address 6)" == "2001:db8::1" ]] || exit 1
warp_output="$(warp_pure_ipv6_check 2>&1)"
grep -Fq '当前符合“原生 IPv6 + WARP IPv4”目标状态' <<<"$warp_output"

# A failed timesyncd start cannot report success.
. "$ROOT/scripts/time.sh"
systemctl() {
    case "$1" in
        list-unit-files) printf 'systemd-timesyncd.service enabled\n' ;;
        is-enabled) printf 'enabled\n' ;;
        enable) return 1 ;;
        *) return 0 ;;
    esac
}
timedatectl() { [[ "$1" == set-ntp ]] && return 0; }
if time_enable_sync >"$TEST_DIR/time.out" 2>&1; then exit 1; fi
if grep -Fq '自动时间同步已开启' "$TEST_DIR/time.out"; then exit 1; fi

# Active timesyncd with NTP enabled is successful while first sync is pending.
systemctl() {
    case "$1" in
        list-unit-files) printf 'systemd-timesyncd.service enabled\n' ;;
        is-enabled) printf 'enabled\n' ;;
        enable) return 0 ;;
        is-active) return 0 ;;
        *) return 0 ;;
    esac
}
timedatectl() {
    [[ "$1" == set-ntp ]] && return 0
    [[ "$*" == *"NTP --value"* ]] && printf 'yes\n' && return 0
    [[ "$*" == *"NTPSynchronized --value"* ]] && printf 'no\n' && return 0
    return 0
}
time_enable_sync >"$TEST_DIR/time-pending.out" 2>&1
grep -Fq '自动时间同步已开启' "$TEST_DIR/time-pending.out"
grep -Fq '正在等待首次 NTP 同步' "$TEST_DIR/time-pending.out"

# Immediate sync polls until NTPSynchronized changes to yes.
sync_counter_file="$TEST_DIR/sync-count"
printf '0\n' > "$sync_counter_file"
timedatectl() {
    [[ "$1" == set-ntp ]] && return 0
    [[ "$*" == *"NTP --value"* ]] && printf 'yes\n' && return 0
    if [[ "$*" == *"NTPSynchronized --value"* ]]; then
        sync_checks="$(<"$sync_counter_file")"
        sync_checks=$((sync_checks + 1))
        printf '%s\n' "$sync_checks" > "$sync_counter_file"
        ((sync_checks >= 2)) && printf 'yes\n' || printf 'no\n'
        return 0
    fi
    return 0
}
sleep() { :; }
time_show() { :; }
TIME_SYNC_WAIT_SECONDS=3 TIME_SYNC_POLL_INTERVAL=0 time_sync_now >"$TEST_DIR/time-sync.out" 2>&1
grep -Fq '时间同步完成' "$TEST_DIR/time-sync.out"

# An inactive service is a real failure and must not print success.
systemctl() {
    case "$1" in
        list-unit-files) printf 'systemd-timesyncd.service enabled\n' ;;
        is-enabled) printf 'enabled\n' ;;
        enable) return 0 ;;
        is-active) return 1 ;;
        *) return 0 ;;
    esac
}
if time_enable_sync >"$TEST_DIR/time-failed.out" 2>&1; then exit 1; fi
! grep -Fq '自动时间同步已开启' "$TEST_DIR/time-failed.out"

# v2node restores the exact pre-change config after a failed restart.
export V2NODE_CONFIG="$TEST_DIR/v2.json" V2NODE_SERVICE=v2node-test
printf '{"Nodes":[{"NodeID":1}]}' > "$V2NODE_CONFIG"
. "$ROOT/scripts/v2node.sh"
backup_file() { :; }
restart_count=0
systemctl() {
    if [[ "$1" == restart ]]; then restart_count=$((restart_count + 1)); ((restart_count > 1)) || return 1; fi
    return 0
}
if v2node_change add <<<"7" >/dev/null 2>&1; then exit 1; fi
python3 - "$V2NODE_CONFIG" <<'PY'
import json, sys
assert [n["NodeID"] for n in json.load(open(sys.argv[1]))["Nodes"]] == [1]
PY

# Deleting credentials only removes this module's backups.
export DDNS_DIR="$TEST_DIR/ddns" DDNS_CONFIG="$TEST_DIR/ddns/config.yaml"
mkdir -p "$DDNS_DIR/backups" "$TEST_DIR/other"
printf 'secret' > "$DDNS_CONFIG"
printf 'secret' > "$DDNS_DIR/backups/config.yaml.old.bak"
printf 'keep' > "$TEST_DIR/other/keep.bak"
. "$ROOT/scripts/ddns.sh"
confirm() { return 0; }
systemctl() { return 0; }
ddns_delete <<<"Y" >/dev/null
[[ ! -e "$DDNS_DIR/backups/config.yaml.old.bak" && -e "$TEST_DIR/other/keep.bak" ]] || exit 1

export PROXY_DIR="$TEST_DIR/proxy" PROXY_COMPOSE="$TEST_DIR/proxy/compose.yml" PROXY_ENV="$TEST_DIR/proxy/.env"
mkdir -p "$PROXY_DIR" "$VPS_TOOLS_ETC/backups/3proxy" "$VPS_TOOLS_ETC/backups/other"
printf 'PROXY_PASSWORD=secret\n' > "$PROXY_ENV"
printf 'services: {}\n' > "$PROXY_COMPOSE"
printf 'keep' > "$VPS_TOOLS_ETC/backups/other/keep.bak"
. "$ROOT/scripts/proxy.sh"
docker() { return 0; }
proxy_uninstall <<<"Y" >/dev/null
[[ -e "$VPS_TOOLS_ETC/backups/other/keep.bak" ]] || exit 1
! find "$VPS_TOOLS_ETC/backups/3proxy" -maxdepth 1 -type f -name '*.bak' -print -quit | grep -q .

printf 'test_audit_repairs: PASS\n'
