#!/usr/bin/env bash

V2NODE_CONFIG="${V2NODE_CONFIG:-/etc/v2node/config.json}"
V2NODE_SERVICE="${V2NODE_SERVICE:-v2node}"

v2node_prepare() {
    require_root || return 1
    [[ -f "$V2NODE_CONFIG" ]] || { error "未找到配置：${V2NODE_CONFIG}，请先安装首个节点。"; return 1; }
    if ! command_exists python3; then
        confirm "缺少 python3，是否安装？" || return 1
        apt_install python3 || return 1
    fi
    python3 -m json.tool "$V2NODE_CONFIG" >/dev/null || { error "现有配置不是有效 JSON。"; return 1; }
}

v2node_list() {
    python3 - "$V2NODE_CONFIG" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    nodes = json.load(handle).get("Nodes", [])
if not nodes:
    print("当前节点：无")
for node in nodes:
    print(f"Node ID: {node.get('NodeID')}")
PY
}

v2node_change() {
    local action="$1" node_id status rollback
    read -r -p "请输入节点 ID: " node_id
    validate_positive_integer "$node_id" || { error "节点 ID 必须是正整数。"; return 1; }
    backup_file "$V2NODE_CONFIG" || return 1
    rollback="$(mktemp)" || return 1
    cp -a "$V2NODE_CONFIG" "$rollback"
    if python3 - "$V2NODE_CONFIG" "$action" "$node_id" <<'PY'
import copy, json, os, sys, tempfile
path, action, raw_id = sys.argv[1:]
node_id = int(raw_id)
with open(path, encoding="utf-8") as handle:
    data = json.load(handle)
nodes = data.get("Nodes", [])
if action == "add":
    if any(node.get("NodeID") == node_id for node in nodes):
        print(f"节点 {node_id} 已存在。")
        raise SystemExit(2)
    if not nodes:
        print("没有现有节点可供复制。")
        raise SystemExit(1)
    new_node = copy.deepcopy(nodes[0])
    new_node["NodeID"] = node_id
    nodes.append(new_node)
else:
    if not any(node.get("NodeID") == node_id for node in nodes):
        print(f"未找到节点 {node_id}。")
        raise SystemExit(2)
    nodes = [node for node in nodes if node.get("NodeID") != node_id]
data["Nodes"] = nodes
directory = os.path.dirname(path)
fd, temp_path = tempfile.mkstemp(prefix=".v2node-", dir=directory, text=True)
try:
    os.fchmod(fd, os.stat(path).st_mode & 0o777)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=4)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temp_path, path)
finally:
    if os.path.exists(temp_path):
        os.unlink(temp_path)
print(f"节点 {node_id} {'添加' if action == 'add' else '删除'}成功。")
PY
    then
        status=0
    else
        status=$?
    fi
    if [[ "$status" -eq 2 ]]; then
        rm -f "$rollback"
        return 0
    fi
    if [[ "$status" -ne 0 ]]; then
        rm -f "$rollback"
        return "$status"
    fi
    if systemctl restart "$V2NODE_SERVICE" && systemctl is-active --quiet "$V2NODE_SERVICE"; then
        rm -f "$rollback"
        success "v2node 已正常运行。"
        return 0
    fi
    install -m 0600 "$rollback" "$V2NODE_CONFIG"
    if systemctl restart "$V2NODE_SERVICE" && systemctl is-active --quiet "$V2NODE_SERVICE"; then
        rm -f "$rollback"
        error "新配置导致 v2node 启动失败，已自动回滚。"
        return 1
    fi
    rm -f "$rollback"
    error "配置已恢复，但 v2node 服务仍异常，需要人工检查日志。"
    return 1
}

module_main() {
    local choice
    v2node_prepare || { pause; return 1; }
    while true; do
        title "V2Node 多节点管理"
        v2node_list || true
        printf '\n1. 添加节点\n2. 删除节点\n3. 查看完整配置\n4. 重启 v2node\n0. 返回\n\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) v2node_change add; pause ;;
            2) v2node_change delete; pause ;;
            3) python3 -m json.tool "$V2NODE_CONFIG"; pause ;;
            4) if systemctl restart "$V2NODE_SERVICE"; then success "已重启。"; else error "重启失败。"; fi; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
