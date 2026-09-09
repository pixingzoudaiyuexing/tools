#!/usr/bin/env bash

# VPS Tools 自维护 Realm 管理器。
# 只使用 zhboner/realm 官方 Release 二进制，不调用第三方 Realm 管理脚本。

REALM_BIN="${REALM_BIN:-/usr/local/bin/realm}"
REALM_CONFIG="${REALM_CONFIG:-/etc/realm/config.toml}"
REALM_SERVICE="${REALM_SERVICE:-realm}"
REALM_SERVICE_FILE="${REALM_SERVICE_FILE:-/etc/systemd/system/${REALM_SERVICE}.service}"
REALM_RELEASE_API="${REALM_RELEASE_API:-https://api.github.com/repos/zhboner/realm/releases/latest}"
REALM_RELEASE_DOWNLOAD_BASE="${REALM_RELEASE_DOWNLOAD_BASE:-https://github.com/zhboner/realm/releases/download}"
REALM_LEGACY_CONFIG="${REALM_LEGACY_CONFIG:-/root/.realm/config.toml}"
REALM_LEGACY_BIN="${REALM_LEGACY_BIN:-/root/realm/realm}"
REALM_MAX_RANGE_RULES="${REALM_MAX_RANGE_RULES:-1000}"

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

realm_require_systemd() {
    command_exists systemctl || {
        error "当前 Realm 自维护管理器要求 systemd。"
        return 1
    }
}

realm_detect_libc() {
    local output
    if command_exists ldd; then
        output="$(ldd --version 2>&1 || true)"
        if grep -qi 'musl' <<<"$output"; then
            printf 'musl\n'
            return 0
        fi
        if grep -qiE 'glibc|GNU libc|GNU C Library' <<<"$output"; then
            printf 'glibc\n'
            return 0
        fi
    fi
    if command_exists getconf && getconf GNU_LIBC_VERSION >/dev/null 2>&1; then
        printf 'glibc\n'
        return 0
    fi
    [[ -e /lib/ld-musl-x86_64.so.1 || -e /lib/ld-musl-aarch64.so.1 ]] && {
        printf 'musl\n'
        return 0
    }
    return 1
}

realm_asset_name() {
    local arch="${1:-$(uname -m)}" libc="${2:-$(realm_detect_libc 2>/dev/null || true)}"
    case "${arch}:${libc}" in
        x86_64:glibc|amd64:glibc) printf 'realm-x86_64-unknown-linux-gnu-glibc2.28.tar.gz\n' ;;
        x86_64:musl|amd64:musl) printf 'realm-x86_64-unknown-linux-musl.tar.gz\n' ;;
        aarch64:glibc|arm64:glibc) printf 'realm-aarch64-unknown-linux-gnu-glibc2.28.tar.gz\n' ;;
        aarch64:musl|arm64:musl) printf 'realm-aarch64-unknown-linux-musl.tar.gz\n' ;;
        armv7l:glibc|armv7:glibc) printf 'realm-armv7-unknown-linux-gnueabihf-glibc2.28.tar.gz\n' ;;
        armv7l:musl|armv7:musl) printf 'realm-armv7-unknown-linux-musleabihf.tar.gz\n' ;;
        *) return 1 ;;
    esac
}

realm_latest_release_tag() {
    local json tag
    ensure_download_environment || return 1
    json="$(curl -fsSL --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github+json' \
        -H 'User-Agent: vps-tools-realm' \
        "$REALM_RELEASE_API")" || return 1
    tag="$(grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"$json" | head -n1 | cut -d'"' -f4)"
    [[ "$tag" =~ ^v?[0-9]+(\.[0-9]+){1,3}([._-][A-Za-z0-9.-]+)?$ ]] || return 1
    printf '%s\n' "$tag"
}

realm_version_output() {
    local bin="${1:-$REALM_BIN}"
    [[ -x "$bin" ]] || return 1
    "$bin" --version 2>&1
}

realm_version_number() {
    local output
    output="$(realm_version_output "${1:-$REALM_BIN}" 2>/dev/null || true)"
    grep -oE '[0-9]+(\.[0-9]+){1,3}' <<<"$output" | head -n1
}

REALM_DOWNLOAD_TAG=""
REALM_DOWNLOAD_ASSET=""
REALM_DOWNLOAD_CANDIDATE=""

realm_download_official_binary() {
    local temp_dir="$1" arch libc asset tag archive extract_dir candidate version_output
    ensure_download_environment || return 1
    command_exists tar || apt_install tar || return 1

    arch="$(uname -m)"
    libc="$(realm_detect_libc 2>/dev/null || true)"
    [[ -n "$libc" ]] || { error "无法识别当前 libc（glibc / musl）。"; return 1; }
    asset="$(realm_asset_name "$arch" "$libc")" || {
        error "Realm 官方自动安装暂不支持：架构=${arch}，libc=${libc}。"
        return 1
    }
    tag="$(realm_latest_release_tag)" || { error "无法获取 zhboner/realm 官方最新 Release。"; return 1; }

    archive="$temp_dir/realm.tar.gz"
    extract_dir="$temp_dir/extract"
    mkdir -p "$extract_dir"
    info "Realm 官方版本：$tag"
    info "下载构建：$asset"
    download_file "${REALM_RELEASE_DOWNLOAD_BASE}/${tag}/${asset}" "$archive" || {
        error "官方 Release 中未能下载兼容构建：$asset"
        return 1
    }
    tar -xzf "$archive" -C "$extract_dir" || { error "Realm 官方压缩包解压失败。"; return 1; }
    candidate="$(find "$extract_dir" -type f -name realm -print -quit 2>/dev/null || true)"
    [[ -n "$candidate" && -f "$candidate" ]] || { error "压缩包中没有找到 realm 二进制。"; return 1; }
    chmod 0755 "$candidate" || return 1
    if ! version_output="$(realm_version_output "$candidate")"; then
        error "下载的 Realm 官方二进制无法在当前系统运行。"
        printf '%s\n' "$version_output"
        return 1
    fi
    [[ -n "$version_output" ]] || { error "Realm 版本验证没有输出。"; return 1; }

    REALM_DOWNLOAD_TAG="$tag"
    REALM_DOWNLOAD_ASSET="$asset"
    REALM_DOWNLOAD_CANDIDATE="$candidate"
}

realm_service_active() {
    realm_require_systemd >/dev/null 2>&1 || return 1
    systemctl is-active --quiet "$REALM_SERVICE"
}

realm_start_service() {
    realm_require_systemd || return 1
    systemctl start "$REALM_SERVICE" || return 1
    systemctl is-active --quiet "$REALM_SERVICE"
}

realm_stop_service() {
    realm_require_systemd || return 1
    systemctl stop "$REALM_SERVICE" >/dev/null 2>&1 || true
}

realm_restart_service() {
    realm_require_systemd || return 1
    systemctl restart "$REALM_SERVICE" || return 1
    systemctl is-active --quiet "$REALM_SERVICE"
}

realm_show_diagnostics() {
    printf '\n[Realm 诊断信息]\n'
    printf '二进制：%s\n配置文件：%s\n服务文件：%s\n' "$REALM_BIN" "$REALM_CONFIG" "$REALM_SERVICE_FILE"
    if command_exists systemctl; then
        printf '\n[服务状态]\n'
        systemctl status "$REALM_SERVICE" --no-pager -l -n 40 2>&1 || true
        if command_exists journalctl; then
            printf '\n[最近日志]\n'
            journalctl -u "$REALM_SERVICE" -n 100 --no-pager 2>&1 || true
        fi
        printf '\n[服务定义]\n'
        systemctl cat "$REALM_SERVICE" 2>&1 || true
    fi
}

realm_write_service_file() {
    local temp status
    mkdir -p "$(dirname "$REALM_SERVICE_FILE")" || return 1
    temp="$(mktemp)" || return 1
    cat >"$temp" <<EOF_UNIT
[Unit]
Description=Realm Relay Service (managed by VPS Tools)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${REALM_BIN} -c ${REALM_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_UNIT
    install -m 0644 "$temp" "$REALM_SERVICE_FILE"
    status=$?
    rm -f "$temp"
    return "$status"
}

realm_create_default_config() {
    local destination="$1"
    mkdir -p "$(dirname "$destination")" || return 1
    cat >"$destination" <<'EOF_CONFIG'
[log]
level = "warn"
output = "stdout"

[network]
no_tcp = false
use_udp = true
ipv6_only = false
EOF_CONFIG
    chmod 0644 "$destination" 2>/dev/null || true
}

realm_prepare_config() {
    [[ -f "$REALM_CONFIG" ]] && return 0
    mkdir -p "$(dirname "$REALM_CONFIG")" || return 1
    if [[ -f "$REALM_LEGACY_CONFIG" ]]; then
        backup_file "$REALM_LEGACY_CONFIG" "$VPS_TOOLS_ETC/backups/realm" || return 1
        cp -a -- "$REALM_LEGACY_CONFIG" "$REALM_CONFIG" || return 1
        chmod 0644 "$REALM_CONFIG" 2>/dev/null || true
        success "已迁移旧 Realm 配置：$REALM_LEGACY_CONFIG → $REALM_CONFIG"
    else
        realm_create_default_config "$REALM_CONFIG" || return 1
        success "已创建 Realm 默认配置：$REALM_CONFIG"
    fi
}

realm_validate_config_file() {
    local config="${1:-$REALM_CONFIG}" bin="${2:-$REALM_BIN}" output status
    [[ -x "$bin" && -f "$config" ]] || return 1
    command_exists timeout || { error "缺少 timeout，无法安全验证 Realm 配置。"; return 1; }
    output="$(mktemp)" || return 1
    if timeout 2 "$bin" -c "$config" >"$output" 2>&1; then
        status=0
    else
        status=$?
    fi
    if [[ "$status" -eq 0 || "$status" -eq 124 ]]; then
        rm -f "$output"
        return 0
    fi
    error "Realm 配置启动验证失败。"
    cat "$output" 2>/dev/null || true
    rm -f "$output"
    return 1
}

realm_ready() {
    require_root || return 1
    realm_require_systemd || return 1
    [[ -x "$REALM_BIN" ]] || { error "Realm 尚未安装。请先选择“安装 / 修复 Realm（官方）”。"; return 1; }
    [[ -f "$REALM_CONFIG" ]] || { error "Realm 配置不存在：$REALM_CONFIG"; return 1; }
    [[ -f "$REALM_SERVICE_FILE" ]] || { error "VPS Tools Realm systemd 服务文件不存在，请先执行安装 / 修复。"; return 1; }
}

realm_rule_lines() {
    [[ -f "$REALM_CONFIG" ]] || return 0
    awk '
        /^[[:space:]]*\[\[endpoints\]\][[:space:]]*$/ {
            if (inside) print idx "|" listen "|" remote
            idx++; inside=1; listen=""; remote=""; next
        }
        inside && /^[[:space:]]*listen[[:space:]]*=/ {
            line=$0; sub(/^[^=]*=[[:space:]]*"/, "", line); sub(/"[[:space:]]*$/, "", line); listen=line; next
        }
        inside && /^[[:space:]]*remote[[:space:]]*=/ {
            line=$0; sub(/^[^=]*=[[:space:]]*"/, "", line); sub(/"[[:space:]]*$/, "", line); remote=line; next
        }
        END { if (inside) print idx "|" listen "|" remote }
    ' "$REALM_CONFIG"
}

realm_rule_count() {
    local lines
    lines="$(realm_rule_lines)"
    [[ -n "$lines" ]] || { printf '0\n'; return 0; }
    printf '%s\n' "$lines" | wc -l | tr -d ' '
}

realm_list_rules() {
    local lines idx listen remote
    lines="$(realm_rule_lines)"
    [[ -n "$lines" ]] || { printf '当前没有 Realm 转发规则。\n'; return 0; }
    while IFS='|' read -r idx listen remote; do
        printf '%3s. %-28s -> %s\n' "$idx" "${listen:-未识别}" "${remote:-未识别}"
    done <<<"$lines"
}

realm_port_in_config() {
    local port="$1" idx listen remote
    while IFS='|' read -r idx listen remote; do
        [[ -n "$listen" && "$listen" == *":${port}" ]] && return 0
    done < <(realm_rule_lines)
    return 1
}

realm_install_or_repair() {
    local temp_dir rollback_bin rollback_unit="" had_bin=0 had_unit=0 created_config=0 was_active=0 rules
    require_root || return 1
    realm_require_systemd || return 1
    ensure_download_environment || return 1

    title "安装 / 修复 Realm（官方）"
    info "仅从 zhboner/realm 官方 Release 下载，不调用第三方 Realm 管理脚本。"
    temp_dir="$(mktemp -d)" || return 1
    rollback_bin="$temp_dir/realm.previous"
    realm_download_official_binary "$temp_dir" || { rm -rf "$temp_dir"; return 1; }

    realm_service_active && was_active=1
    if [[ -x "$REALM_BIN" ]]; then
        had_bin=1
        cp -a -- "$REALM_BIN" "$rollback_bin" || { rm -rf "$temp_dir"; return 1; }
        backup_file "$REALM_BIN" "$VPS_TOOLS_ETC/backups/realm" || { rm -rf "$temp_dir"; return 1; }
    fi
    if [[ -f "$REALM_SERVICE_FILE" ]]; then
        had_unit=1
        rollback_unit="$temp_dir/realm.service.previous"
        cp -a -- "$REALM_SERVICE_FILE" "$rollback_unit" || { rm -rf "$temp_dir"; return 1; }
        backup_file "$REALM_SERVICE_FILE" "$VPS_TOOLS_ETC/backups/realm" || { rm -rf "$temp_dir"; return 1; }
    fi
    if [[ ! -f "$REALM_CONFIG" ]]; then
        created_config=1
    else
        backup_file "$REALM_CONFIG" "$VPS_TOOLS_ETC/backups/realm" || { rm -rf "$temp_dir"; return 1; }
    fi
    realm_prepare_config || { rm -rf "$temp_dir"; return 1; }

    realm_stop_service
    mkdir -p "$(dirname "$REALM_BIN")" || { rm -rf "$temp_dir"; return 1; }
    install -m 0755 "$REALM_DOWNLOAD_CANDIDATE" "$REALM_BIN" || { rm -rf "$temp_dir"; return 1; }
    if ! realm_write_service_file; then
        [[ "$had_bin" -eq 1 ]] && cp -a -- "$rollback_bin" "$REALM_BIN" || rm -f "$REALM_BIN"
        rm -rf "$temp_dir"
        return 1
    fi
    systemctl daemon-reload || true
    systemctl enable "$REALM_SERVICE" >/dev/null 2>&1 || true

    rules="$(realm_rule_count)"
    if [[ "$rules" -eq 0 ]]; then
        success "Realm 官方版安装完成；当前没有转发规则，服务保持停止。"
        printf '版本：%s\n构建：%s\n二进制：%s\n配置：%s\n' \
            "$(realm_version_output 2>/dev/null || printf '未知')" "$REALM_DOWNLOAD_ASSET" "$REALM_BIN" "$REALM_CONFIG"
        rm -rf "$temp_dir"
        return 0
    fi

    if realm_restart_service; then
        success "Realm 官方版安装 / 修复完成。"
        printf '版本：%s\n构建：%s\n二进制：%s\n配置：%s\n' \
            "$(realm_version_output 2>/dev/null || printf '未知')" "$REALM_DOWNLOAD_ASSET" "$REALM_BIN" "$REALM_CONFIG"
        [[ -f "$REALM_LEGACY_CONFIG" || -x "$REALM_LEGACY_BIN" ]] && \
            info "旧 Realm 文件已不再被 VPS Tools 服务使用，可暂留作人工备份。"
        rm -rf "$temp_dir"
        return 0
    fi

    error "新 Realm 未能正常启动，正在恢复安装前状态。"
    realm_stop_service
    [[ "$had_bin" -eq 1 ]] && cp -a -- "$rollback_bin" "$REALM_BIN" || rm -f "$REALM_BIN"
    [[ "$had_unit" -eq 1 ]] && cp -a -- "$rollback_unit" "$REALM_SERVICE_FILE" || rm -f "$REALM_SERVICE_FILE"
    [[ "$created_config" -eq 1 ]] && rm -f "$REALM_CONFIG"
    systemctl daemon-reload || true
    [[ "$was_active" -eq 1 ]] && systemctl start "$REALM_SERVICE" >/dev/null 2>&1 || true
    realm_show_diagnostics
    rm -rf "$temp_dir"
    return 1
}

realm_choose_listen_mode() {
    local choice
    cat <<'TEXT'
监听方式：
1. IPv4 入口（推荐，0.0.0.0）
2. IPv4 + IPv6 双栈入口（[::]，ipv6_only=false）
3. 仅 IPv6 入口（[::]，ipv6_only=true）
TEXT
    read -r -p "请选择 [1-3，回车=1]: " choice
    choice="${choice:-1}"
    case "$choice" in
        1|2|3) REALM_LISTEN_MODE="$choice" ;;
        *) error "监听方式无效。"; return 1 ;;
    esac
}

realm_listen_address() {
    case "$1" in
        1) printf '0.0.0.0:%s\n' "$2" ;;
        2|3) printf '[::]:%s\n' "$2" ;;
        *) return 1 ;;
    esac
}

realm_append_endpoint() {
    local file="$1" mode="$2" listen="$3" remote="$4"
    cat >>"$file" <<EOF_ENDPOINT

[[endpoints]]
listen = "${listen}"
remote = "${remote}"
EOF_ENDPOINT
    case "$mode" in
        2) printf '[endpoints.network]\nipv6_only = false\n' >>"$file" ;;
        3) printf '[endpoints.network]\nipv6_only = true\n' >>"$file" ;;
    esac
}

realm_apply_candidate_config() {
    local candidate="$1" start_if_stopped="${2:-0}" rollback was_active=0 status=0
    [[ -f "$candidate" ]] || return 1
    backup_file "$REALM_CONFIG" "$VPS_TOOLS_ETC/backups/realm" || return 1
    rollback="$(mktemp)" || return 1
    cp -a -- "$REALM_CONFIG" "$rollback" || { rm -f "$rollback"; return 1; }
    realm_service_active && was_active=1
    cp -a -- "$candidate" "$REALM_CONFIG" || { rm -f "$rollback"; return 1; }

    if [[ "$was_active" -eq 1 ]]; then
        realm_restart_service || status=$?
    else
        realm_validate_config_file "$REALM_CONFIG" "$REALM_BIN" || status=$?
        if [[ "$status" -eq 0 && "$start_if_stopped" -eq 1 && "$(realm_rule_count)" -gt 0 ]]; then
            realm_start_service || status=$?
        fi
    fi
    if [[ "$status" -eq 0 ]]; then
        rm -f "$rollback"
        return 0
    fi

    error "新配置未通过 Realm 运行验证，正在恢复原配置。"
    cp -a -- "$rollback" "$REALM_CONFIG"
    rm -f "$rollback"
    [[ "$was_active" -eq 1 ]] && realm_restart_service >/dev/null 2>&1 || true
    realm_show_diagnostics
    return "$status"
}

realm_add_single() {
    local listen_port target remote_port remote target_type listen candidate
    realm_ready || { pause; return 1; }
    title "Realm 添加单端口转发"
    realm_list_rules
    printf '\n'
    read -r -p "本机监听端口: " listen_port
    validate_port "$listen_port" || { error "端口必须是 1-65535。"; pause; return 1; }
    realm_port_in_config "$listen_port" && { error "Realm 已存在监听端口 $listen_port。"; pause; return 1; }
    realm_choose_listen_mode || { pause; return 1; }
    listen="$(realm_listen_address "$REALM_LISTEN_MODE" "$listen_port")"

    read -r -p "落地 IP / 域名（不要带端口）: " target
    target="$(realm_strip_brackets "$target")"
    validate_hostname_or_ip "$target" || { error "落地 IP / 域名格式无效。"; pause; return 1; }
    read -r -p "落地端口: " remote_port
    validate_port "$remote_port" || { error "落地端口必须是 1-65535。"; pause; return 1; }
    remote="$(realm_format_remote "$target" "$remote_port")" || { error "无法生成目标地址。"; pause; return 1; }
    target_type="$(realm_target_type "$target")"

    printf '\n监听：%s\n目标：%s（%s）\n' "$listen" "$remote" "$target_type"
    [[ "$REALM_LISTEN_MODE" == "1" && "$target_type" == "IPv6" ]] && success "这是明确的 IPv4 入口 → IPv6 落地转发。"
    confirm "确认添加这条 Realm 转发规则？" || { info "已取消。"; pause; return 0; }

    candidate="$(mktemp)" || return 1
    cp -a -- "$REALM_CONFIG" "$candidate" || { rm -f "$candidate"; return 1; }
    realm_append_endpoint "$candidate" "$REALM_LISTEN_MODE" "$listen" "$remote"
    if realm_apply_candidate_config "$candidate" 1; then
        success "Realm 转发规则已添加并启动服务。"
        rm -f "$candidate"
        pause
        return 0
    fi
    rm -f "$candidate"
    pause
    return 1
}

realm_add_range() {
    local local_start local_end target mapping remote_start remote_fixed count offset lp rp remote listen candidate
    realm_ready || { pause; return 1; }
    title "Realm 添加端口段转发"
    read -r -p "本机起始端口: " local_start
    read -r -p "本机结束端口: " local_end
    validate_port_range "$local_start" "$local_end" || { error "端口段无效。"; pause; return 1; }
    count=$((10#$local_end - 10#$local_start + 1))
    ((count <= REALM_MAX_RANGE_RULES)) || { error "一次最多添加 ${REALM_MAX_RANGE_RULES} 条规则。"; pause; return 1; }
    for ((lp=10#$local_start; lp<=10#$local_end; lp++)); do
        realm_port_in_config "$lp" && { error "监听端口 $lp 已存在，整段操作取消。"; pause; return 1; }
    done

    realm_choose_listen_mode || { pause; return 1; }
    read -r -p "落地 IP / 域名（不要带端口）: " target
    target="$(realm_strip_brackets "$target")"
    validate_hostname_or_ip "$target" || { error "落地 IP / 域名格式无效。"; pause; return 1; }
    cat <<'TEXT'

端口映射：
1. 连续对应（例如 10000-10010 → 20000-20010）
2. 全部转发到同一个落地端口
TEXT
    read -r -p "请选择 [1-2]: " mapping
    case "$mapping" in
        1)
            read -r -p "落地起始端口: " remote_start
            validate_port "$remote_start" || { error "落地起始端口无效。"; pause; return 1; }
            ((10#$remote_start + count - 1 <= 65535)) || { error "映射后的落地端口超过 65535。"; pause; return 1; }
            ;;
        2)
            read -r -p "落地端口: " remote_fixed
            validate_port "$remote_fixed" || { error "落地端口无效。"; pause; return 1; }
            ;;
        *) error "映射方式无效。"; pause; return 1 ;;
    esac
    printf '\n将添加 %s 条 Realm 规则，落地目标：%s\n' "$count" "$target"
    confirm "确认批量添加？" || { info "已取消。"; pause; return 0; }

    candidate="$(mktemp)" || return 1
    cp -a -- "$REALM_CONFIG" "$candidate" || { rm -f "$candidate"; return 1; }
    offset=0
    for ((lp=10#$local_start; lp<=10#$local_end; lp++)); do
        if [[ "$mapping" == "1" ]]; then rp=$((10#$remote_start + offset)); else rp=$((10#$remote_fixed)); fi
        listen="$(realm_listen_address "$REALM_LISTEN_MODE" "$lp")"
        remote="$(realm_format_remote "$target" "$rp")" || { rm -f "$candidate"; return 1; }
        realm_append_endpoint "$candidate" "$REALM_LISTEN_MODE" "$listen" "$remote"
        offset=$((offset + 1))
    done
    if realm_apply_candidate_config "$candidate" 1; then
        success "端口段转发已添加：共 ${count} 条规则。"
        rm -f "$candidate"
        pause
        return 0
    fi
    rm -f "$candidate"
    pause
    return 1
}

realm_build_config_without_rule() {
    local source="$1" target_index="$2" destination="$3"
    awk -v target="$target_index" '
        /^[[:space:]]*\[\[endpoints\]\][[:space:]]*$/ {
            idx++; skipping=(idx == target); if (!skipping) print; next
        }
        skipping {
            if ($0 ~ /^[[:space:]]*\[endpoints\.[^]]+\][[:space:]]*$/) next
            if ($0 ~ /^[[:space:]]*\[/) { skipping=0; print }
            next
        }
        { print }
    ' "$source" >"$destination"
}

realm_delete_rule() {
    local count index candidate
    realm_ready || { pause; return 1; }
    title "Realm 删除转发规则"
    count="$(realm_rule_count)"
    [[ "$count" -gt 0 ]] || { info "当前没有 Realm 转发规则。"; pause; return 0; }
    realm_list_rules
    printf '\n'
    read -r -p "请输入要删除的规则编号: " index
    validate_positive_integer "$index" || { error "规则编号无效。"; pause; return 1; }
    ((10#$index >= 1 && 10#$index <= count)) || { error "规则编号超出范围。"; pause; return 1; }
    confirm "确认删除第 ${index} 条 Realm 规则？" || { info "已取消。"; pause; return 0; }
    candidate="$(mktemp)" || return 1
    realm_build_config_without_rule "$REALM_CONFIG" "$index" "$candidate" || { rm -f "$candidate"; return 1; }
    if realm_apply_candidate_config "$candidate" 0; then
        success "Realm 第 ${index} 条规则已删除。"
        if [[ "$(realm_rule_count)" -eq 0 ]] && realm_service_active; then
            realm_stop_service
            info "已无转发规则，Realm 服务已停止。"
        fi
        rm -f "$candidate"
        pause
        return 0
    fi
    rm -f "$candidate"
    pause
    return 1
}

realm_view_config() {
    title "Realm 当前配置 / 规则"
    printf 'Realm：%s\n二进制：%s\n配置：%s\n' \
        "$(realm_version_output 2>/dev/null || printf '未安装')" "$REALM_BIN" "$REALM_CONFIG"
    if realm_service_active; then printf '服务状态：运行中\n'; else printf '服务状态：未运行\n'; fi
    printf '\n[转发规则]\n'
    realm_list_rules
    printf '\n[原始配置]\n'
    [[ -f "$REALM_CONFIG" ]] && cat "$REALM_CONFIG" || printf '配置文件不存在。\n'
    pause
}

realm_service_start_menu() {
    realm_ready || { pause; return 1; }
    if [[ "$(realm_rule_count)" -eq 0 ]]; then warn "当前没有转发规则，未启动 Realm。"; pause; return 0; fi
    if realm_start_service; then success "Realm 已启动。"; else error "Realm 启动失败。"; realm_show_diagnostics; fi
    pause
}

realm_service_stop_menu() {
    realm_ready || { pause; return 1; }
    realm_stop_service
    success "Realm 已停止。"
    pause
}

realm_service_restart_menu() {
    realm_ready || { pause; return 1; }
    if [[ "$(realm_rule_count)" -eq 0 ]]; then warn "当前没有转发规则，未启动 Realm。"; pause; return 0; fi
    if realm_restart_service; then success "Realm 已重启。"; else error "Realm 重启失败。"; realm_show_diagnostics; fi
    pause
}

realm_status_logs() {
    title "Realm 状态 / 日志"
    printf '版本：%s\n规则数：%s\n\n' "$(realm_version_output 2>/dev/null || printf '未安装 / 无法运行')" "$(realm_rule_count)"
    command_exists systemctl && systemctl status "$REALM_SERVICE" --no-pager -l -n 50 2>&1 || true
    if command_exists journalctl; then
        printf '\n[最近 100 条日志]\n'
        journalctl -u "$REALM_SERVICE" -n 100 --no-pager 2>&1 || true
    fi
    pause
}

realm_update() {
    local temp_dir current latest was_active=0 rollback
    realm_ready || { pause; return 1; }
    require_root || return 1
    title "更新 Realm（官方）"
    temp_dir="$(mktemp -d)" || return 1
    realm_download_official_binary "$temp_dir" || { rm -rf "$temp_dir"; pause; return 1; }
    current="$(realm_version_number 2>/dev/null || true)"
    latest="${REALM_DOWNLOAD_TAG#v}"
    printf '当前版本：%s\n官方最新：%s\n' "${current:-未知}" "$latest"
    if [[ -n "$current" && "$current" == "$latest" ]]; then success "当前已经是官方最新版本。"; rm -rf "$temp_dir"; pause; return 0; fi
    confirm "确认更新 Realm 到 ${REALM_DOWNLOAD_TAG}？" || { rm -rf "$temp_dir"; info "已取消。"; pause; return 0; }

    rollback="$temp_dir/realm.previous"
    cp -a -- "$REALM_BIN" "$rollback" || { rm -rf "$temp_dir"; return 1; }
    backup_file "$REALM_BIN" "$VPS_TOOLS_ETC/backups/realm" || { rm -rf "$temp_dir"; return 1; }
    realm_service_active && was_active=1
    realm_stop_service
    install -m 0755 "$REALM_DOWNLOAD_CANDIDATE" "$REALM_BIN" || { cp -a -- "$rollback" "$REALM_BIN"; rm -rf "$temp_dir"; return 1; }

    if [[ "$was_active" -eq 1 ]]; then
        if ! realm_restart_service; then
            error "新版本启动失败，正在回滚旧二进制。"
            realm_stop_service; cp -a -- "$rollback" "$REALM_BIN"; realm_restart_service >/dev/null 2>&1 || true
            realm_show_diagnostics; rm -rf "$temp_dir"; pause; return 1
        fi
    elif ! realm_validate_config_file "$REALM_CONFIG" "$REALM_BIN"; then
        error "新版本与现有配置验证失败，正在回滚。"
        cp -a -- "$rollback" "$REALM_BIN"; rm -rf "$temp_dir"; pause; return 1
    fi
    success "Realm 已更新到 ${REALM_DOWNLOAD_TAG}。"
    rm -rf "$temp_dir"
    pause
}

realm_uninstall() {
    require_root || return 1
    realm_require_systemd || return 1
    title "卸载 Realm"
    warn "将停止 Realm，并删除 VPS Tools 管理的 systemd 服务和 $REALM_BIN。"
    warn "不会删除 /etc/vps-tools/ 备份，也不会自动删除旧 /root/.realm 文件。"
    confirm "确认卸载 Realm？" || { info "已取消。"; pause; return 0; }
    [[ -f "$REALM_CONFIG" ]] && backup_file "$REALM_CONFIG" "$VPS_TOOLS_ETC/backups/realm" || true
    [[ -x "$REALM_BIN" ]] && backup_file "$REALM_BIN" "$VPS_TOOLS_ETC/backups/realm" || true
    [[ -f "$REALM_SERVICE_FILE" ]] && backup_file "$REALM_SERVICE_FILE" "$VPS_TOOLS_ETC/backups/realm" || true
    systemctl disable --now "$REALM_SERVICE" >/dev/null 2>&1 || true
    rm -f "$REALM_SERVICE_FILE" "$REALM_BIN"
    systemctl daemon-reload || true
    if [[ -f "$REALM_CONFIG" ]]; then
        if confirm "是否同时删除当前 Realm 配置 $REALM_CONFIG？"; then
            rm -f "$REALM_CONFIG"; rmdir "$(dirname "$REALM_CONFIG")" 2>/dev/null || true
        else
            info "已保留 Realm 配置：$REALM_CONFIG"
        fi
    fi
    success "VPS Tools 管理的 Realm 已卸载。"
    pause
}

realm_migration_status() {
    [[ -f "$REALM_LEGACY_CONFIG" || -x "$REALM_LEGACY_BIN" ]] && \
        printf '旧版文件：检测到（安装 / 修复时迁移配置，但不再使用旧二进制）\n'
}

module_main() {
    local choice
    while true; do
        title "VPS 端口中转（Realm）"
        printf '官方项目：zhboner/realm\n二进制：%s\n配置：%s\n' "$REALM_BIN" "$REALM_CONFIG"
        realm_migration_status
        if realm_service_active; then printf '状态：运行中'; else printf '状态：未运行'; fi
        [[ -x "$REALM_BIN" ]] && printf ' | %s' "$(realm_version_output 2>/dev/null || printf '版本未知')"
        printf '\n\n'
        cat <<'TEXT'
 1. 安装 / 修复 Realm（官方）
 2. 添加单端口转发
 3. 添加端口段转发
 4. 删除转发规则
 5. 查看当前配置 / 规则
------------------------------------------------
 6. 启动服务
 7. 停止服务
 8. 重启服务
 9. 查看状态 / 日志
------------------------------------------------
10. 更新 Realm（官方）
11. 卸载 Realm
 0. 返回

说明：
- 不调用任何第三方 Realm 管理脚本。
- 安装 / 更新只下载 zhboner/realm 官方 Release。
- glibc 系统使用官方 glibc2.28 兼容构建，不升级系统 glibc。
- 默认监听为 IPv4，可直接实现 IPv4 入口 → 纯 IPv6 落地。
- 修改规则前自动备份；启动验证失败会恢复原配置。
TEXT
        printf '\n'
        read -r -p "请选择 [0-11]: " choice
        case "$choice" in
            1) realm_install_or_repair; pause ;;
            2) realm_add_single ;;
            3) realm_add_range ;;
            4) realm_delete_rule ;;
            5) realm_view_config ;;
            6) realm_service_start_menu ;;
            7) realm_service_stop_menu ;;
            8) realm_service_restart_menu ;;
            9) realm_status_logs ;;
            10) realm_update ;;
            11) realm_uninstall ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
