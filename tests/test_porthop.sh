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

printf 'test_porthop: PASS\n'
