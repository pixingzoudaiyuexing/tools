#!/usr/bin/env bash

PORTHOP_DIR="${PORTHOP_DIR:-/etc/vps-tools/porthop}"
PORTHOP_CONFIG="$PORTHOP_DIR/rules.tsv"
PORTHOP_RULES="$PORTHOP_DIR/rules.nft"
PORTHOP_APPLY="/usr/local/lib/vps-tools/apply-porthop.sh"
PORTHOP_UNIT="/etc/systemd/system/vps-tools-porthop.service"

porthop_prepare() {
    require_root || return 1
    require_debian_ubuntu || return 1
    if ! command_exists nft; then
        confirm "nftables 未安装，是否安装？" || return 1
        apt_install nftables || return 1
    fi
    mkdir -p "$PORTHOP_DIR" /usr/local/lib/vps-tools
    chmod 700 "$PORTHOP_DIR"
    [[ -f "$PORTHOP_CONFIG" ]] || install -m 0600 /dev/null "$PORTHOP_CONFIG"
}

porthop_ranges_overlap() {
    local start_a="$1" end_a="$2" start_b="$3" end_b="$4"
    ((10#$start_a <= 10#$end_b && 10#$start_b <= 10#$end_a))
}

porthop_has_conflict() {
    local start="$1" end="$2" family="$3" iface="$4"
    local id old_start old_end v4port v4iface v6port v6iface old_port old_iface
    while IFS=$'\t' read -r id old_start old_end v4port v4iface v6port v6iface; do
        [[ -n "$id" ]] || continue
        if [[ "$family" == "4" ]]; then old_port="$v4port"; old_iface="$v4iface"; else old_port="$v6port"; old_iface="$v6iface"; fi
        [[ "$old_port" != "-" && "$old_iface" == "$iface" ]] || continue
        porthop_ranges_overlap "$start" "$end" "$old_start" "$old_end" && return 0
    done <"$PORTHOP_CONFIG"
    return 1
}

porthop_render() {
    local output="$1" table_suffix="${2:-}" id start end v4port v4iface v6port v6iface
    local have4=0 have6=0
    while IFS=$'\t' read -r id start end v4port v4iface v6port v6iface; do
        [[ "$v4port" != "-" ]] && have4=1
        [[ "$v6port" != "-" ]] && have6=1
    done <"$PORTHOP_CONFIG"
    : >"$output"
    if ((have4)); then
        {
            printf 'table ip vps_tools_porthop%s {\n' "$table_suffix"
            printf '  chain prerouting {\n'
            printf '    type nat hook prerouting priority dstnat; policy accept;\n'
            while IFS=$'\t' read -r id start end v4port v4iface v6port v6iface; do
                [[ "$v4port" != "-" ]] || continue
                printf '    iifname "%s" udp dport %s-%s redirect to :%s comment "vps-tools:%s"\n' "$v4iface" "$start" "$end" "$v4port" "$id"
            done <"$PORTHOP_CONFIG"
            printf '  }\n}\n'
        } >>"$output"
    fi
    if ((have6)); then
        {
            printf 'table ip6 vps_tools_porthop%s {\n' "$table_suffix"
            printf '  chain prerouting {\n'
            printf '    type nat hook prerouting priority dstnat; policy accept;\n'
            while IFS=$'\t' read -r id start end v4port v4iface v6port v6iface; do
                [[ "$v6port" != "-" ]] || continue
                printf '    iifname "%s" udp dport %s-%s redirect to :%s comment "vps-tools:%s"\n' "$v6iface" "$start" "$end" "$v6port" "$id"
            done <"$PORTHOP_CONFIG"
            printf '  }\n}\n'
        } >>"$output"
    fi
    chmod 600 "$output"
}

porthop_install_service() {
    local temp_apply temp_unit
    temp_apply="$(mktemp)"; temp_unit="$(mktemp)" || return 1
    cat >"$temp_apply" <<'SCRIPT'
#!/usr/bin/env bash
set -e
nft delete table ip vps_tools_porthop 2>/dev/null || true
nft delete table ip6 vps_tools_porthop 2>/dev/null || true
[[ ! -s /etc/vps-tools/porthop/rules.nft ]] || nft -f /etc/vps-tools/porthop/rules.nft
SCRIPT
    cat >"$temp_unit" <<'UNIT'
[Unit]
Description=VPS Tools UDP 端口跳跃
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/vps-tools/apply-porthop.sh
ExecReload=/usr/local/lib/vps-tools/apply-porthop.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    install -m 0755 "$temp_apply" "$PORTHOP_APPLY"
    install -m 0644 "$temp_unit" "$PORTHOP_UNIT"
    rm -f "$temp_apply" "$temp_unit"
    systemctl daemon-reload
    systemctl enable vps-tools-porthop.service >/dev/null
}

porthop_apply() {
    local check_file
    porthop_render "$PORTHOP_RULES"
    check_file="$(mktemp)" || return 1
    porthop_render "$check_file" "_check"
    if [[ -s "$check_file" ]] && ! nft -c -f "$check_file"; then
        rm -f "$check_file"
        error "nftables 语法检查失败，未应用规则。"
        return 1
    fi
    rm -f "$check_file"
    porthop_install_service || return 1
    systemctl restart vps-tools-porthop.service || { error "端口跳跃服务启动失败。"; return 1; }
    success "规则已通过语法检查并应用，开机恢复服务已启用。"
}

porthop_add() {
    local start end iface4 iface6 port4 port6 id temp
    read -r -p "请输入跳跃起始端口: " start
    read -r -p "请输入跳跃结束端口: " end
    validate_port_range "$start" "$end" || { error "端口范围无效。"; return 1; }
    iface4="$(detect_default_interface 4)"
    iface6="$(detect_default_interface 6)"
    if [[ -n "$iface4" ]]; then
        read -r -p "IPv4 实际 UDP 端口（留空跳过，接口 ${iface4}）: " port4
        [[ -z "$port4" ]] || validate_port "$port4" || { error "IPv4 实际端口无效。"; return 1; }
    else
        info "未检测到 IPv4 默认出口，跳过 IPv4。"
        port4=""
    fi
    if [[ -n "$iface6" ]]; then
        read -r -p "IPv6 实际 UDP 端口（留空跳过，接口 ${iface6}）: " port6
        [[ -z "$port6" ]] || validate_port "$port6" || { error "IPv6 实际端口无效。"; return 1; }
    else
        info "未检测到 IPv6 默认出口，跳过 IPv6。"
        port6=""
    fi
    [[ -n "$port4" || -n "$port6" ]] || { error "IPv4 和 IPv6 不能同时跳过。"; return 1; }
    [[ -z "$port4" ]] || ! porthop_has_conflict "$start" "$end" 4 "$iface4" || { error "IPv4 范围与已有规则冲突。"; return 1; }
    [[ -z "$port6" ]] || ! porthop_has_conflict "$start" "$end" 6 "$iface6" || { error "IPv6 范围与已有规则冲突。"; return 1; }
    id="$(date '+%Y%m%d%H%M%S')-$RANDOM"
    backup_file "$PORTHOP_CONFIG" "$PORTHOP_DIR/backups" || return 1
    temp="$(mktemp)" || return 1
    cp "$PORTHOP_CONFIG" "$temp"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$start" "$end" "${port4:--}" "${iface4:--}" "${port6:--}" "${iface6:--}" >>"$temp"
    install -m 0600 "$temp" "$PORTHOP_CONFIG"
    rm -f "$temp"
    if ! porthop_apply; then
        error "应用失败，请从 $PORTHOP_DIR/backups 恢复配置后重新应用。"
        return 1
    fi
}

porthop_list() {
    local number=0 id start end v4port v4iface v6port v6iface
    while IFS=$'\t' read -r id start end v4port v4iface v6port v6iface; do
        [[ -n "$id" ]] || continue
        number=$((number + 1))
        [[ "$v4port" == "-" ]] && v4port="跳过"
        [[ "$v6port" == "-" ]] && v6port="跳过"
        printf '%d. ID=%s 端口=%s-%s IPv4=%s@%s IPv6=%s@%s\n' "$number" "$id" "$start" "$end" "$v4port" "$v4iface" "$v6port" "$v6iface"
    done <"$PORTHOP_CONFIG"
    ((number > 0)) || info "暂无规则。"
}

porthop_delete() {
    local choice choice_number count temp
    porthop_list
    count="$(awk 'NF {count++} END {print count+0}' "$PORTHOP_CONFIG")"
    ((count > 0)) || return 0
    read -r -p "请输入要删除的编号: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || { error "编号无效。"; return 1; }
    choice_number=$((10#$choice))
    ((choice_number >= 1 && choice_number <= count)) || { error "编号无效。"; return 1; }
    confirm "确认删除第 $choice_number 条规则？" || return 0
    backup_file "$PORTHOP_CONFIG" "$PORTHOP_DIR/backups" || return 1
    temp="$(mktemp)" || return 1
    awk -v target="$choice_number" 'NF {n++} n != target {print}' "$PORTHOP_CONFIG" >"$temp"
    install -m 0600 "$temp" "$PORTHOP_CONFIG"
    rm -f "$temp"
    porthop_apply
}

porthop_show_live() {
    porthop_list
    printf '\n[nftables IPv4]\n'
    nft list table ip vps_tools_porthop 2>/dev/null || info "IPv4 表不存在。"
    printf '\n[nftables IPv6]\n'
    nft list table ip6 vps_tools_porthop 2>/dev/null || info "IPv6 表不存在。"
}

module_main() {
    local choice
    porthop_prepare || { pause; return 1; }
    while true; do
        title "UDP / Hy2 端口跳跃"
        printf '适用于 v2node Hysteria2 / QUIC / 其他 UDP 服务。\n\n'
        printf '1. 添加规则\n2. 删除规则\n3. 查看规则\n4. 重新应用\n0. 返回\n\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) porthop_add; pause ;;
            2) porthop_delete; pause ;;
            3) porthop_show_live; pause ;;
            4) porthop_apply; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
