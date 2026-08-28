#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export PORTHOP_DIR="$TEST_DIR/porthop"
mkdir -p "$PORTHOP_DIR"
export PORTHOP_CONFIG="$PORTHOP_DIR/rules.tsv" PORTHOP_RULES="$PORTHOP_DIR/rules.nft"
cat >"$PORTHOP_CONFIG" <<'TSV'
rule-a	40000	50000	60295	ens3	-	-
rule-b	51000	52000	-	-	59442	ens6
TSV

# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=scripts/porthop.sh
. "$ROOT/scripts/porthop.sh"

porthop_render "$PORTHOP_RULES"
grep -Fq 'table ip vps_tools_porthop {' "$PORTHOP_RULES"
grep -Fq 'iifname "ens3" udp dport 40000-50000 redirect to :60295' "$PORTHOP_RULES"
grep -Fq 'table ip6 vps_tools_porthop {' "$PORTHOP_RULES"
grep -Fq 'iifname "ens6" udp dport 51000-52000 redirect to :59442' "$PORTHOP_RULES"
if grep -Fq 'flush ruleset' "$PORTHOP_RULES"; then exit 1; fi
porthop_has_conflict 45000 46000 4 ens3
if porthop_has_conflict 53000 54000 4 ens3; then exit 1; fi
if porthop_has_conflict 45000 46000 6 ens6; then exit 1; fi

# Failed apply restores the previous TSV, while a user can override the interface.
printf 'old\t10000\t10010\t60100\tens3\t-\t-\n' > "$PORTHOP_CONFIG"
require_root() { return 0; }
require_debian_ubuntu() { return 0; }
confirm() { return 0; }
detect_inbound_interface() { [[ "$1" == 4 ]] && printf 'warp0\n' || printf 'ens6\n'; }
ip() { [[ "$1" == link ]] && return 0; }
backup_file() { :; }
porthop_apply_count=0
porthop_apply() { porthop_apply_count=$((porthop_apply_count + 1)); ((porthop_apply_count == 1)) && return 1; return 0; }
porthop_add <<'INPUT' >/dev/null 2>&1 || true
40000
40010
ens9

60295

INPUT
grep -Fq $'old\t10000\t10010' "$PORTHOP_CONFIG"
! grep -Fq $'40000\t40010' "$PORTHOP_CONFIG"

printf 'test_porthop: PASS\n'
