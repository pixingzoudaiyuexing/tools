#!/usr/bin/env bash

REALM_UPSTREAM_URL="https://raw.githubusercontent.com/wcwq98/realm/main/realm.sh"
REALM_CONFIG="${REALM_CONFIG:-/root/.realm/config.toml}"
REALM_BIN="${REALM_BIN:-/root/realm/realm}"
REALM_SERVICE="${REALM_SERVICE:-realm}"

realm_strip_brackets() {
    local target="$1"
    if [[ "$target" == \[*\] ]]; then
        target="${target#[}"
        target="${target%]}"
    fi
    printf '%s\n' "$target"
}

realm_target_type() {
    local target
    target="$(realm_strip_brackets "$1")"
    if [[ "$target" == *:* ]]; then
        printf 'IPv6\n'
    elif [[ "$target" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        printf 'IPv4\n'
    else
        printf '域名\n'
    fi
}

realm_format_remote() {
    local target port type
    target="$(realm_strip_brackets "$1")"
    port="$2"
    validate_hostname_or_ip "$target" || return 1
    validate_port "$port" || return 1
    type="$(realm_target_type "$target")"
    if [[ "$type" == "IPv6" ]]; then
        printf '[%s]:%s\n' "$target" "$port"
    else
        printf '%s:%s\n' "$target" "$port"
    fi
}

realm_local_network_type() {
    local has4=0 has6=0 line iface
    while read -r line; do
        [[ -n "$line" ]] || continue
        iface="${line%% *}"
        iface="${iface%%@*}"
        is_virtual_interface_name "$iface" && continue
        has4=1
        break
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2, $4}')
    while read -r line; do
        [[ -n "$line" ]] || continue
        iface="${line%% *}"
        iface="${iface%%@*}"
        is_virtual_interface_name "$iface" && continue
        has6=1
        break
    done < <(ip -6 -o addr show scope global 2>/dev/null | awk '{print $2, $4}')

    if ((has4 == 1 && has6 == 1)); then
        printf '双栈中转\n'
    elif ((has4 == 1)); then
        printf 'IPv4 中转\n'
    elif ((has6 == 1)); then
        printf 'IPv6 中转\n'
    else
        printf '未知网络\n'
    fi
}

realm_restart_service() {
    if command_exists systemctl; then
        systemctl restart "$REALM_SERVICE" || return 1
        systemctl is-active --quiet "$REALM_SERVICE"
        return $?
    fi
    if command_exists rc-service; then
        rc-service "$REALM_SERVICE" restart || return 1
        rc-service "$REALM_SERVICE" status >/dev/null 2>&1
        return $?
    fi
    error "未找到 systemd 或 OpenRC，无法自动重启 Realm。"
    return 1
}

realm_rule_exists() {
    local port="$1"
    [[ -f "$REALM_CONFIG" ]] || return 1
    grep -qE "listen = \"(\\[::\\]|0\\.0\\.0\\.0):${port}\"" "$REALM_CONFIG"
}

realm_quick_ready() {
    require_root || return 1
    if [[ ! -x "$REALM_BIN" || ! -f "$REALM_CONFIG" ]]; then
        warn "未检测到已安装的 Realm 或配置文件。"
        info "请先选择“启动 Realm 完整管理脚本”，执行一次安装 / 重置 Realm。"
        return 1
    fi
}

realm_quick_add() {
    local listen_port target remote_port target_type remote local_type rollback status
    realm_quick_ready || { pause; return 1; }

    title "Realm 快速添加转发规则"
    info "支持 IPv4、IPv6 和域名；IPv6 可直接粘贴裸地址，无需手动添加 [ ]。"
    printf '\n'

    read -r -p "本机监听端口: " listen_port
    validate_port "$listen_port" || { error "本机端口必须是 1-65535。"; pause; return 1; }
    if realm_rule_exists "$listen_port"; then
        error "Realm 已存在监听端口 ${listen_port} 的规则。"
        pause
        return 1
    fi

    read -r -p "落地 IP / 域名（不要带端口）: " target
    target="$(realm_strip_brackets "$target")"
    validate_hostname_or_ip "$target" || { error "落地 IP / 域名格式无效。"; pause; return 1; }

    read -r -p "落地端口: " remote_port
    validate_port "$remote_port" || { error "落地端口必须是 1-65535。"; pause; return 1; }

    remote="$(realm_format_remote "$target" "$remote_port")" || { error "无法生成 Realm 目标地址。"; pause; return 1; }
    target_type="$(realm_target_type "$target")"
    local_type="$(realm_local_network_type)"

    printf '\n'
    printf '目标类型：%s\n' "$target_type"
    printf '转发链路：%s → %s 落地\n' "$local_type" "$target_type"
    printf '监听地址：[::]:%s\n' "$listen_port"
    printf '目标地址：%s\n' "$remote"
    if [[ "$target_type" == "IPv6" ]]; then
        success "已自动规范化 IPv6：${remote}"
    fi
    printf '\n'

    confirm "确认添加这条 Realm 转发规则？" || { info "已取消。"; pause; return 0; }

    backup_file "$REALM_CONFIG" "$VPS_TOOLS_ETC/backups/realm" || { pause; return 1; }
    rollback="$(mktemp)" || { error "无法创建临时回滚文件。"; pause; return 1; }
    cp -a "$REALM_CONFIG" "$rollback" || { rm -f "$rollback"; pause; return 1; }

    cat >>"$REALM_CONFIG" <<EOF

[[endpoints]]
listen = "[::]:${listen_port}"
remote = "${remote}"
EOF

    if realm_restart_service; then
        rm -f "$rollback"
        success "Realm 转发规则已添加并生效。"
        printf '访问中转机端口 %s 的流量将转发到 %s。\n' "$listen_port" "$remote"
        pause
        return 0
    fi

    status=$?
    install -m 0600 "$rollback" "$REALM_CONFIG"
    rm -f "$rollback"
    if realm_restart_service; then
        error "新规则导致 Realm 启动失败，已恢复添加前的配置。"
    else
        error "新规则失败后已恢复配置，但 Realm 服务仍未正常启动，请检查日志。"
    fi
    pause
    return "${status:-1}"
}

realm_upstream() {
    if confirm "是否继续启动 Realm 完整管理脚本？"; then
        run_remote_bash "$REALM_UPSTREAM_URL" "wcwq98/realm"
    fi
}

module_main() {
    local choice
    while true; do
        title "VPS 端口中转（Realm）"
        cat <<'TEXT'
1. 快速添加转发规则（IPv4 / IPv6 自动识别）
2. 启动 Realm 完整管理脚本
0. 返回

快速添加支持：
- 双栈中转 → 纯 IPv6 落地
- IPv4 / IPv6 / 域名目标
- 裸 IPv6 自动补 [ ]
- 新规则失败自动恢复原配置

完整管理脚本负责 Realm 安装、删除、端口段、服务、日志和面板管理。
TEXT
        printf '\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) realm_quick_add ;;
            2) realm_upstream; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
