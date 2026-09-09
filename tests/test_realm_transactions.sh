#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export VPS_TOOLS_ETC="$TMP/vps-tools"
export REALM_CONFIG="$TMP/config.toml"
export REALM_BIN="$TMP/realm"
export REALM_SERVICE_FILE="$TMP/realm.service"

# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=scripts/realm.sh
. "$ROOT/scripts/realm.sh"

cat >"$REALM_BIN" <<'BIN'
#!/usr/bin/env bash
exit 0
BIN
chmod +x "$REALM_BIN"

backup_file() { return 0; }
realm_show_diagnostics() { :; }

write_rule_a() {
    cat >"$REALM_CONFIG" <<'CFG'
[network]
no_tcp = false
use_udp = true

[[endpoints]]
listen = "0.0.0.0:10000"
remote = "1.1.1.1:443"
CFG
}

write_rule_b() {
    cat >"$1" <<'CFG'
[network]
no_tcp = false
use_udp = true

[[endpoints]]
listen = "0.0.0.0:20000"
remote = "[2001:db8::1]:443"
CFG
}

# 1) 删除最后一条规则：活动服务应停止并禁用，不能把“无规则”误判为失败。
write_rule_a
CANDIDATE_ZERO="$TMP/zero.toml"
cat >"$CANDIDATE_ZERO" <<'CFG'
[network]
no_tcp = false
use_udp = true
CFG
STOP_COUNT=0
RESTART_COUNT=0
DISABLE_COUNT=0
realm_service_active() { return 0; }
realm_stop_service() { STOP_COUNT=$((STOP_COUNT + 1)); return 0; }
realm_restart_service() { RESTART_COUNT=$((RESTART_COUNT + 1)); return 0; }
realm_validate_config_file() { printf '删除最后一条规则时不应启动 Realm 做空配置验证。\n' >&2; return 99; }
systemctl() {
    [[ "${1:-}" == "disable" ]] && DISABLE_COUNT=$((DISABLE_COUNT + 1))
    return 0
}
realm_apply_candidate_config "$CANDIDATE_ZERO" 0
[[ "$(realm_rule_count)" == "0" ]]
[[ "$STOP_COUNT" -eq 1 ]]
[[ "$RESTART_COUNT" -eq 0 ]]
[[ "$DISABLE_COUNT" -eq 1 ]]

# 2) 活动服务应用新规则失败：必须恢复原配置并尝试恢复原服务。
write_rule_a
ORIGINAL="$TMP/original.toml"
cp "$REALM_CONFIG" "$ORIGINAL"
CANDIDATE_B="$TMP/b.toml"
write_rule_b "$CANDIDATE_B"
STOP_COUNT=0
RESTART_COUNT=0
realm_service_active() { return 0; }
realm_stop_service() { STOP_COUNT=$((STOP_COUNT + 1)); return 0; }
realm_restart_service() {
    RESTART_COUNT=$((RESTART_COUNT + 1))
    [[ "$RESTART_COUNT" -ge 2 ]]
}
realm_validate_config_file() { return 0; }
if realm_apply_candidate_config "$CANDIDATE_B" 1 >/dev/null 2>&1; then
    printf 'Realm 新配置重启失败时不应返回成功。\n' >&2
    exit 1
fi
cmp -s "$ORIGINAL" "$REALM_CONFIG"
[[ "$STOP_COUNT" -ge 1 ]]
[[ "$RESTART_COUNT" -eq 2 ]]

# 3) 原服务未运行，添加规则后启动失败：必须停止失败服务并恢复原配置。
write_rule_a
cp "$REALM_CONFIG" "$ORIGINAL"
write_rule_b "$CANDIDATE_B"
STOP_COUNT=0
START_COUNT=0
VALIDATE_COUNT=0
realm_service_active() { return 1; }
realm_stop_service() { STOP_COUNT=$((STOP_COUNT + 1)); return 0; }
realm_validate_config_file() { VALIDATE_COUNT=$((VALIDATE_COUNT + 1)); return 0; }
realm_start_service() { START_COUNT=$((START_COUNT + 1)); return 1; }
realm_restart_service() { printf '原服务未运行时回滚不应强制重启。\n' >&2; return 99; }
if realm_apply_candidate_config "$CANDIDATE_B" 1 >/dev/null 2>&1; then
    printf 'Realm 启动失败时不应返回成功。\n' >&2
    exit 1
fi
cmp -s "$ORIGINAL" "$REALM_CONFIG"
[[ "$VALIDATE_COUNT" -eq 1 ]]
[[ "$START_COUNT" -eq 1 ]]
[[ "$STOP_COUNT" -eq 1 ]]

printf 'Realm 配置事务 / 回滚测试通过。\n'
