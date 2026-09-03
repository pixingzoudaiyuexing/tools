#!/usr/bin/env bash

REALM_UPSTREAM_URL="https://raw.githubusercontent.com/wcwq98/realm/main/realm.sh"
REALM_CONFIG="${REALM_CONFIG:-/root/.realm/config.toml}"
REALM_BIN="${REALM_BIN:-/root/realm/realm}"
REALM_SERVICE="${REALM_SERVICE:-realm}"
REALM_RELEASE_API="${REALM_RELEASE_API:-https://api.github.com/repos/zhboner/realm/releases/latest}"
REALM_RELEASE_DOWNLOAD_BASE="${REALM_RELEASE_DOWNLOAD_BASE:-https://github.com/zhboner/realm/releases/download}"

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

realm_service_installed() {
    if command_exists systemctl; then
        systemctl cat "$REALM_SERVICE" >/dev/null 2>&1 && return 0
        systemctl list-unit-files "${REALM_SERVICE}.service" --no-legend 2>/dev/null | grep -q "^${REALM_SERVICE}\.service" && return 0
        return 1
    fi
    if command_exists rc-service; then
        [[ -x "/etc/init.d/${REALM_SERVICE}" ]]
        return $?
    fi
    return 1
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

realm_stop_service() {
    if command_exists systemctl; then
        systemctl stop "$REALM_SERVICE" >/dev/null 2>&1 || true
    elif command_exists rc-service; then
        rc-service "$REALM_SERVICE" stop >/dev/null 2>&1 || true
    fi
}

realm_show_diagnostics() {
    printf '\n[Realm 诊断信息]\n'
    printf '二进制：%s\n' "$REALM_BIN"
    printf '配置文件：%s\n' "$REALM_CONFIG"
    printf '服务名：%s\n' "$REALM_SERVICE"
    if command_exists systemctl; then
        printf '\n[服务状态]\n'
        systemctl status "$REALM_SERVICE" --no-pager -l -n 30 2>&1 || true
        printf '\n[最近日志]\n'
        journalctl -u "$REALM_SERVICE" -n 60 --no-pager 2>&1 || true
        printf '\n[服务定义]\n'
        systemctl cat "$REALM_SERVICE" 2>&1 || true
    elif command_exists rc-service; then
        printf '\n[服务状态]\n'
        rc-service "$REALM_SERVICE" status 2>&1 || true
    fi
    printf '\n'
}

realm_glibc_version() {
    local output
    if command_exists getconf; then
        output="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
        if [[ "$output" =~ ^glibc[[:space:]]+([0-9.]+)$ ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    fi
    if command_exists ldd; then
        output="$(ldd --version 2>/dev/null | head -n1 || true)"
        if [[ "$output" =~ ([0-9]+\.[0-9]+)$ ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    fi
    return 1
}

realm_binary_loader_output() {
    [[ -x "$REALM_BIN" ]] || return 1
    "$REALM_BIN" --version 2>&1 || true
}

realm_binary_glibc_incompatible() {
    local output
    output="$(realm_binary_loader_output 2>/dev/null || true)"
    grep -Eq 'GLIBC_[0-9.]+.*not found' <<<"$output"
}

realm_compat_asset_name() {
    local arch="${1:-$(uname -m)}"
    case "$arch" in
        x86_64|amd64)
            printf 'realm-x86_64-unknown-linux-gnu-glibc2.28.tar.gz\n'
            ;;
        aarch64|arm64)
            printf 'realm-aarch64-unknown-linux-gnu-glibc2.28.tar.gz\n'
            ;;
        *)
            return 1
            ;;
    esac
}

realm_latest_release_tag() {
    local json tag
    ensure_download_environment || return 1
    json="$(curl -fsSL --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: vps-tools-realm-compat' \
        "$REALM_RELEASE_API")" || return 1
    tag="$(grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"$json" | head -n1 | cut -d'"' -f4)"
    [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    printf '%s\n' "$tag"
}

realm_repair_glibc_compat() {
    local arch asset tag url temp_dir archive extract_dir candidate rollback current_glibc version_output
    require_root || return 1
    [[ -x "$REALM_BIN" ]] || { error "未找到 Realm 二进制：$REALM_BIN"; return 1; }

    if ! realm_binary_glibc_incompatible; then
        success "当前 Realm 二进制没有检测到 glibc 版本不兼容，无需替换。"
        version_output="$("$REALM_BIN" --version 2>/dev/null || true)"
        [[ -n "$version_output" ]] && printf 'Realm：%s\n' "$version_output"
        return 0
    fi

    arch="$(uname -m)"
    asset="$(realm_compat_asset_name "$arch")" || {
        error "当前架构 ${arch} 暂未纳入 Realm glibc 兼容自动修复。"
        return 1
    }
    current_glibc="$(realm_glibc_version || true)"
    warn "检测到 Realm 二进制需要当前系统不存在的 GLIBC 版本。"
    printf '系统架构：%s\n' "$arch"
    printf '当前 glibc：%s\n' "${current_glibc:-无法识别}"
    printf '兼容构建：%s\n' "$asset"

    tag="$(realm_latest_release_tag)" || {
        error "无法获取 Realm 官方最新 Release 版本。"
        return 1
    }
    url="${REALM_RELEASE_DOWNLOAD_BASE}/${tag}/${asset}"

    temp_dir="$(mktemp -d)" || return 1
    archive="$temp_dir/realm.tar.gz"
    extract_dir="$temp_dir/extract"
    rollback="$temp_dir/realm.original"
    mkdir -p "$extract_dir"

    if ! download_file "$url" "$archive"; then
        rm -rf "$temp_dir"
        return 1
    fi
    if ! command_exists tar; then
        apt_install tar || { rm -rf "$temp_dir"; return 1; }
    fi
    if ! tar -xzf "$archive" -C "$extract_dir"; then
        error "Realm 兼容包解压失败。"
        rm -rf "$temp_dir"
        return 1
    fi
    candidate="$(find "$extract_dir" -type f -name realm -print -quit 2>/dev/null || true)"
    [[ -n "$candidate" && -f "$candidate" ]] || {
        error "Realm 兼容包中没有找到 realm 二进制。"
        rm -rf "$temp_dir"
        return 1
    }
    chmod +x "$candidate"

    version_output="$("$candidate" --version 2>&1 || true)"
    if grep -Eq 'GLIBC_[0-9.]+.*not found' <<<"$version_output"; then
        error "下载的 glibc2.28 兼容构建在当前系统仍无法运行。"
        printf '%s\n' "$version_output"
        rm -rf "$temp_dir"
        return 1
    fi

    backup_file "$REALM_BIN" "$VPS_TOOLS_ETC/backups/realm" || {
        rm -rf "$temp_dir"
        return 1
    }
    cp -a -- "$REALM_BIN" "$rollback" || {
        error "无法创建 Realm 二进制临时回滚副本。"
        rm -rf "$temp_dir"
        return 1
    }

    info "正在停止 Realm 的失败重启循环并替换兼容二进制..."
    realm_stop_service
    if ! install -m 0755 "$candidate" "$REALM_BIN"; then
        error "替换 Realm 二进制失败。"
        cp -a -- "$rollback" "$REALM_BIN" || true
        rm -rf "$temp_dir"
        return 1
    fi

    if realm_binary_glibc_incompatible; then
        error "替换后仍检测到 GLIBC 兼容错误，正在恢复原二进制。"
        realm_stop_service
        cp -a -- "$rollback" "$REALM_BIN" || true
        rm -rf "$temp_dir"
        return 1
    fi

    if realm_service_installed; then
        if realm_restart_service; then
            success "Realm glibc 兼容修复完成，服务已正常启动。"
            version_output="$("$REALM_BIN" --version 2>/dev/null || true)"
            [[ -n "$version_output" ]] && printf 'Realm：%s\n' "$version_output"
            printf '兼容构建：%s / %s\n' "$tag" "$asset"
            rm -rf "$temp_dir"
            return 0
        fi

        error "兼容二进制可以运行，但 Realm 服务仍启动失败；正在恢复原二进制。"
        realm_stop_service
        cp -a -- "$rollback" "$REALM_BIN" || true
        realm_stop_service
        rm -rf "$temp_dir"
        realm_show_diagnostics
        return 1
    fi

    success "Realm glibc 兼容二进制已替换；当前未检测到 Realm 服务，未执行自动启动。"
    rm -rf "$temp_dir"
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
    if ! realm_service_installed; then
        error "检测到 Realm 二进制和配置，但没有找到 ${REALM_SERVICE} 服务。"
        info "请先进入 Realm 完整管理脚本执行“安装 / 重置 Realm”，补齐服务文件。"
        realm_show_diagnostics
        return 1
    fi

    info "正在检查修改前的 Realm 服务状态..."
    if ! realm_restart_service; then
        if realm_binary_glibc_incompatible; then
            warn "检测到 Realm 因 glibc 版本不兼容无法启动，正在自动修复。"
            if realm_repair_glibc_compat; then
                success "Realm 兼容修复成功，原配置已恢复正常运行。"
                return 0
            fi
            error "Realm glibc 自动修复未成功，已取消快速添加；配置文件没有被修改。"
            realm_show_diagnostics
            return 1
        fi
        error "当前 Realm 使用原配置就无法正常启动，已取消快速添加；配置文件没有被修改。"
        realm_show_diagnostics
        return 1
    fi
    success "Realm 原配置启动正常，可以安全添加新规则。"
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
    else
        status=$?
    fi

    cp -a -- "$rollback" "$REALM_CONFIG"
    rm -f "$rollback"
    if realm_restart_service; then
        error "新规则导致 Realm 启动失败，已恢复添加前的配置。"
        realm_show_diagnostics
    else
        error "新规则失败后已恢复配置，但 Realm 服务仍未正常启动。"
        realm_show_diagnostics
    fi
    pause
    return "$status"
}

realm_upstream() {
    local status=0
    if confirm "是否继续启动 Realm 完整管理脚本？"; then
        run_remote_bash "$REALM_UPSTREAM_URL" "wcwq98/realm"
        status=$?
        if [[ -x "$REALM_BIN" ]] && realm_binary_glibc_incompatible; then
            warn "上游脚本安装的 Realm 与当前 glibc 不兼容，正在自动替换官方兼容构建。"
            realm_repair_glibc_compat || status=1
        fi
    fi
    return "$status"
}

realm_compat_menu() {
    title "Realm glibc 兼容修复"
    realm_repair_glibc_compat
    pause
}

module_main() {
    local choice
    while true; do
        title "VPS 端口中转（Realm）"
        cat <<'TEXT'
1. 快速添加转发规则（IPv4 / IPv6 自动识别）
2. 启动 Realm 完整管理脚本
3. Realm glibc 兼容修复
0. 返回

快速添加支持：
- 双栈中转 → 纯 IPv6 落地
- IPv4 / IPv6 / 域名目标
- 裸 IPv6 自动补 [ ]
- 添加前检查原 Realm 服务是否正常
- 检测到 GLIBC_x.xx not found 时自动换官方 glibc2.28 兼容构建
- 新规则失败自动恢复原配置并显示诊断日志

完整管理脚本仍负责 Realm 安装、删除、端口段、服务、日志和面板管理。
TEXT
        printf '\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) realm_quick_add ;;
            2) realm_upstream; pause ;;
            3) realm_compat_menu ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
