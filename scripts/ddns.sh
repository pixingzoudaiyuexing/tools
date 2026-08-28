#!/usr/bin/env bash

DDNS_DIR="${DDNS_DIR:-/etc/vps-tools/ddns-go}"
DDNS_CONFIG="$DDNS_DIR/config.yaml"
DDNS_BIN="/usr/local/bin/ddns-go"
DDNS_UNIT="/etc/systemd/system/vps-tools-ddns-go.service"

ddns_json_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

ddns_latest_version() {
    local location
    location="$(curl -fsSIL --connect-timeout 10 --max-time 30 https://github.com/jeessy2/ddns-go/releases/latest 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^location:/ {gsub("\\r", ""); value=$2} END{print value}')"
    basename "$location" | sed 's/^v//'
}

ddns_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86_64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        armv7l) printf 'armv7\n' ;;
        i386|i686) printf 'i386\n' ;;
        riscv64) printf 'riscv64\n' ;;
        *) error "ddns-go 不支持当前架构：$(uname -m)"; return 1 ;;
    esac
}

ddns_install_binary() {
    local version arch temp_dir archive checksums asset base_url
    require_root || return 1
    command_exists tar || apt_install tar || return 1
    version="$(ddns_latest_version)"
    arch="$(ddns_arch)" || return 1
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { error "无法获得 ddns-go 最新版本。"; return 1; }
    temp_dir="$(mktemp -d)" || return 1
    asset="ddns-go_${version}_linux_${arch}.tar.gz"
    archive="$temp_dir/$asset"; checksums="$temp_dir/checksums.txt"
    base_url="https://github.com/jeessy2/ddns-go/releases/download/v${version}"
    download_file "$base_url/$asset" "$archive" || { rm -rf "$temp_dir"; return 1; }
    download_file "$base_url/checksums.txt" "$checksums" || { rm -rf "$temp_dir"; return 1; }
    if command_exists sha256sum; then
        (cd "$temp_dir" && grep -F "  $asset" checksums.txt | sha256sum -c -) || { rm -rf "$temp_dir"; error "ddns-go 校验和不匹配。"; return 1; }
    else
        warn "系统缺少 sha256sum，跳过发行包校验。"
    fi
    tar -xzf "$archive" -C "$temp_dir" || { rm -rf "$temp_dir"; return 1; }
    [[ -f "$temp_dir/ddns-go" ]] || { rm -rf "$temp_dir"; error "发行包中没有 ddns-go。"; return 1; }
    install -m 0755 "$temp_dir/ddns-go" "$DDNS_BIN"
    rm -rf "$temp_dir"
    success "已安装 ddns-go v${version}。"
}

ddns_read_domains() {
    local prompt="$1" value domain output=""
    local domains=()
    read -r -p "${prompt}（多个用逗号分隔）: " value
    IFS=',' read -r -a domains <<<"$value"
    for domain in "${domains[@]}"; do
        domain="${domain//[[:space:]]/}"
        [[ "$domain" =~ ^[A-Za-z0-9._:-]+\.[A-Za-z0-9._:-]+$ ]] || { error "域名格式无效：$domain"; return 1; }
        output+="        - $(ddns_json_quote "$domain")"$'\n'
    done
    printf '%s' "$output"
}

ddns_choose_provider() {
    local choice
    printf '1. Cloudflare\n2. 华为云\n3. 阿里云\n4. DNSPod\n' >&2
    read -r -p "请选择服务商: " choice
    case "$choice" in
        1) printf 'cloudflare\n' ;; 2) printf 'huaweicloud\n' ;; 3) printf 'alidns\n' ;; 4) printf 'dnspod\n' ;;
        *) error "无效服务商。"; return 1 ;;
    esac
}

ddns_write_config() {
    local provider dns_id dns_secret dns_secret_again enable4 enable6 domains4="" domains6=""
    local get4="url" url4="https://ip.p3terx.com" iface4="" warp4 temp
    provider="$(ddns_choose_provider)" || return 1
    case "$provider" in
        cloudflare)
            dns_id=""
            read -r -s -p "请输入 Cloudflare API Token: " dns_secret; printf '\n'
            read -r -s -p "请再次输入 API Token: " dns_secret_again; printf '\n'
            ;;
        dnspod)
            read -r -p "请输入 DNSPod Token ID: " dns_id
            read -r -s -p "请输入 DNSPod Token: " dns_secret; printf '\n'
            read -r -s -p "请再次输入 Token: " dns_secret_again; printf '\n'
            ;;
        *)
            read -r -p "请输入 Access Key ID: " dns_id
            read -r -s -p "请输入 Access Key Secret: " dns_secret; printf '\n'
            read -r -s -p "请再次输入 Secret: " dns_secret_again; printf '\n'
            ;;
    esac
    [[ -n "$dns_secret" && "$dns_secret" == "$dns_secret_again" ]] || { error "凭证为空或两次输入不一致。"; return 1; }
    read -r -p "启用 IPv4 A 记录？[Y/n]: " enable4
    if [[ "$enable4" =~ ^[Nn]$ ]]; then enable4=false; else enable4=true; fi
    read -r -p "启用 IPv6 AAAA 记录？[Y/n]: " enable6
    if [[ "$enable6" =~ ^[Nn]$ ]]; then enable6=false; else enable6=true; fi
    [[ "$enable4" == true || "$enable6" == true ]] || { error "至少启用一个协议族。"; return 1; }
    if [[ "$enable4" == true ]]; then
        domains4="$(ddns_read_domains "请输入 IPv4 域名")" || return 1
        warp4="$(get_cloudflare_warp_state 4)"
        if [[ "$warp4" =~ ^(on|plus)$ ]]; then
            warn "检测到 IPv4 通过 WARP，不能把 WARP 出口默认当作 VPS 真实 IPv4。"
            ip -o -4 addr show scope global 2>/dev/null | awk '{print $2, $4}' | grep -Ev '^(wgcf|warp|docker|br-|veth)' || true
            read -r -p "请输入承载真实 IPv4 的网卡名: " iface4
            [[ "$iface4" =~ ^[A-Za-z0-9_.:-]+$ ]] || { error "网卡名无效。"; return 1; }
            ip -4 addr show dev "$iface4" scope global >/dev/null 2>&1 || { error "该网卡没有全局 IPv4。"; return 1; }
            get4="netInterface"; url4=""
        fi
    fi
    [[ "$enable6" == false ]] || domains6="$(ddns_read_domains "请输入 IPv6 域名")" || return 1
    mkdir -p "$DDNS_DIR"; chmod 700 "$DDNS_DIR"
    [[ ! -f "$DDNS_CONFIG" ]] || backup_file "$DDNS_CONFIG" "$DDNS_DIR/backups" || return 1
    temp="$(mktemp)" || return 1
    {
        printf 'dnsconf:\n  - name: "VPS Tools"\n'
        printf '    ipv4:\n      enable: %s\n      gettype: %s\n      url: %s\n      netinterface: %s\n      cmd: ""\n      domains:' "$enable4" "$(ddns_json_quote "$get4")" "$(ddns_json_quote "$url4")" "$(ddns_json_quote "$iface4")"
        if [[ -n "$domains4" ]]; then printf '\n%s\n' "$domains4"; else printf ' []\n'; fi
        printf '    ipv6:\n      enable: %s\n      gettype: "url"\n      url: "https://ip.p3terx.com"\n      netinterface: ""\n      cmd: ""\n      ipv6reg: ""\n      domains:' "$enable6"
        if [[ -n "$domains6" ]]; then printf '\n%s\n' "$domains6"; else printf ' []\n'; fi
        printf '    dns:\n      name: %s\n      id: %s\n      secret: %s\n      extparam: ""\n' "$(ddns_json_quote "$provider")" "$(ddns_json_quote "$dns_id")" "$(ddns_json_quote "$dns_secret")"
        printf '    ttl: ""\n    httpinterface: ""\nusername: ""\npassword: ""\nwebhookurl: ""\nwebhookrequestbody: ""\nwebhookheaders: ""\nnotallowwanaccess: true\nlang: "zh"\n'
    } >"$temp"
    install -m 0600 "$temp" "$DDNS_CONFIG"
    rm -f "$temp"
    unset dns_secret dns_secret_again
    success "DDNS 配置已保存为本地 600 权限文件。"
}

ddns_install_service() {
    local temp
    [[ -x "$DDNS_BIN" && -f "$DDNS_CONFIG" ]] || return 1
    temp="$(mktemp)" || return 1
    cat >"$temp" <<UNIT
[Unit]
Description=VPS Tools DDNS-GO
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$DDNS_BIN -c $DDNS_CONFIG -noweb -f 300
Restart=on-failure
RestartSec=10s
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT
    install -m 0644 "$temp" "$DDNS_UNIT"
    rm -f "$temp"
    systemctl daemon-reload
    systemctl enable --now vps-tools-ddns-go
}

ddns_add_or_modify() {
    require_root || return 1
    [[ -x "$DDNS_BIN" ]] || ddns_install_binary || return 1
    ddns_write_config || return 1
    ddns_install_service && success "DDNS-GO 已以 -noweb 模式启动。"
}

ddns_show_config() {
    [[ -f "$DDNS_CONFIG" ]] || { info "尚未配置 DDNS。"; return 0; }
    sed -E 's/^([[:space:]]*(secret|id):).*/\1 "***"/' "$DDNS_CONFIG"
}

ddns_delete() {
    local answer
    require_root || return 1
    confirm "确认删除 VPS Tools DDNS 服务和本地凭证配置？" || return 0
    systemctl disable --now vps-tools-ddns-go 2>/dev/null || true
    rm -f "$DDNS_UNIT"
    systemctl daemon-reload
    [[ ! -f "$DDNS_CONFIG" ]] || backup_file "$DDNS_CONFIG" "$DDNS_DIR/backups" || return 1
    rm -f "$DDNS_CONFIG"
    read -r -p "是否同时删除包含凭证的历史备份？[Y/n]: " answer
    if [[ ! "$answer" =~ ^[Nn]$ ]]; then
        find "$DDNS_DIR/backups" -maxdepth 1 -type f -name 'config.yaml.*.bak' -delete 2>/dev/null || true
        success "DDNS 配置及其凭证备份已删除。"
    else
        warn "历史备份中仍可能保存 API Token / 密码。"
        success "DDNS 配置已删除；备份仍保留在 $DDNS_DIR/backups。"
    fi
}

module_main() {
    local choice
    while true; do
        title "DDNS 管理（DDNS-GO）"
        printf '1. 添加 DDNS\n2. 查看配置\n3. 立即同步\n4. 修改配置\n5. 删除 DDNS\n6. 查看日志\n7. 重启服务\n8. 升级 ddns-go\n0. 返回\n\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1|4) ddns_add_or_modify; pause ;;
            2) ddns_show_config; pause ;;
            3) require_root && systemctl restart vps-tools-ddns-go && journalctl -u vps-tools-ddns-go -n 30 --no-pager; pause ;;
            5) ddns_delete; pause ;;
            6) journalctl -u vps-tools-ddns-go -n 100 --no-pager; pause ;;
            7) require_root && systemctl restart vps-tools-ddns-go; pause ;;
            8) ddns_install_binary && systemctl restart vps-tools-ddns-go && success "升级完成。"; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
