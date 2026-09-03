#!/usr/bin/env bash

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export V2NODE_CONFIG="$TEST_DIR/config.json" V2NODE_SERVICE="v2node-test"
cat >"$V2NODE_CONFIG" <<'JSON'
{
  "Log": {"Level": "info"},
  "Nodes": [
    {"NodeID": 1, "ApiHost": "https://panel.example.com", "Token": "fixture-token"}
  ]
}
JSON

# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=scripts/v2node.sh
. "$ROOT/scripts/v2node.sh"
backup_file() { :; }
systemctl() { return 0; }

[[ "$(v2node_list)" == "现有节点 ID：1" ]]

output="$(v2node_change add <<<"7")"
grep -Fq '现有节点 ID：1' <<<"$output"
python3 - "$V2NODE_CONFIG" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
assert [n["NodeID"] for n in data["Nodes"]] == [1, 7]
assert data["Nodes"][1]["ApiHost"] == "https://panel.example.com"
assert data["Log"]["Level"] == "info"
PY

output="$(v2node_change add <<<"7")"
grep -Fq '现有节点 ID：1, 7' <<<"$output"
python3 - "$V2NODE_CONFIG" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    assert [n["NodeID"] for n in json.load(f)["Nodes"]] == [1, 7]
PY

output="$(v2node_change delete <<<"7")"
grep -Fq '现有节点 ID：1, 7' <<<"$output"
python3 - "$V2NODE_CONFIG" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    assert [n["NodeID"] for n in json.load(f)["Nodes"]] == [1]
PY

printf 'test_v2node: PASS\n'
