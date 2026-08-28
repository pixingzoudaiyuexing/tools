#!/usr/bin/env bash

TEMP_KEY_DIR="${TEMP_KEY_DIR:-/etc/vps-tools/temp-ssh-keys}"
TEMP_KEY_META="$TEMP_KEY_DIR/keys.tsv"
TEMP_KEY_AUTH="${TEMP_KEY_AUTH:-/root/.ssh/authorized_keys}"
TEMP_KEY_CLEANER="/usr/local/lib/vps-tools/cleanup-temp-ssh-keys.sh"

temp_key_prepare() {
    require_root || return 1
    if ! command_exists ssh-keygen; then
        confirm "缺少 ssh-keygen，是否安装？" || return 1
        apt_install openssh-client || return 1
    fi
    mkdir -p "$TEMP_KEY_DIR" /root/.ssh /usr/local/lib/vps-tools
    chmod 700 "$TEMP_KEY_DIR" /root/.ssh
    [[ -f "$TEMP_KEY_META" ]] || install -m 0600 /dev/null "$TEMP_KEY_META"
    [[ -f "$TEMP_KEY_AUTH" ]] || install -m 0600 /dev/null "$TEMP_KEY_AUTH"
    chmod 600 "$TEMP_KEY_META" "$TEMP_KEY_AUTH"
}

temp_key_install_timer() {
    local cleaner unit timer
    cleaner="$(mktemp)"; unit="$(mktemp)"; timer="$(mktemp)" || return 1
    cat >"$cleaner" <<'CLEANER'
#!/usr/bin/env bash
set -u
meta=/etc/vps-tools/temp-ssh-keys/keys.tsv
auth=/root/.ssh/authorized_keys
[[ -f "$meta" && -f "$auth" ]] || exit 0
now="$(date +%s)"
temp_meta="$(mktemp)"; temp_auth="$(mktemp)" || exit 1
cp "$auth" "$temp_auth"
while IFS=$'\t' read -r id created expires; do
    [[ -n "$id" ]] || continue
    if [[ "$expires" != "0" && "$expires" -le "$now" ]]; then
        awk -v marker="$id" '$NF != marker {print}' "$temp_auth" >"${temp_auth}.next"
        mv "${temp_auth}.next" "$temp_auth"
    else
        printf '%s\t%s\t%s\n' "$id" "$created" "$expires" >>"$temp_meta"
    fi
done <"$meta"
install -m 0600 "$temp_auth" "$auth"
install -m 0600 "$temp_meta" "$meta"
rm -f "$temp_auth" "$temp_meta"
CLEANER
    cat >"$unit" <<'UNIT'
[Unit]
Description=清理 VPS Tools 到期临时 SSH 密钥

[Service]
Type=oneshot
ExecStart=/usr/local/lib/vps-tools/cleanup-temp-ssh-keys.sh
UNIT
    cat >"$timer" <<'TIMER'
[Unit]
Description=定时清理 VPS Tools 临时 SSH 密钥

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
TIMER
    install -m 0755 "$cleaner" "$TEMP_KEY_CLEANER"
    install -m 0644 "$unit" /etc/systemd/system/vps-tools-temp-key-cleanup.service
    install -m 0644 "$timer" /etc/systemd/system/vps-tools-temp-key-cleanup.timer
    rm -f "$cleaner" "$unit" "$timer"
    systemctl daemon-reload
    systemctl enable --now vps-tools-temp-key-cleanup.timer >/dev/null
}

temp_key_cleanup_now() {
    [[ -x "$TEMP_KEY_CLEANER" ]] && "$TEMP_KEY_CLEANER"
}

temp_key_generate() {
    local choice seconds created expires id temp_dir private public
    temp_key_prepare || return 1
    printf '1. 1 小时\n2. 6 小时\n3. 24 小时\n4. 7 天\n5. 永久 / 手动删除\n'
    read -r -p "请选择有效期: " choice
    case "$choice" in
        1) seconds=3600 ;; 2) seconds=21600 ;; 3) seconds=86400 ;; 4) seconds=604800 ;; 5) seconds=0 ;;
        *) error "无效选项。"; return 1 ;;
    esac
    created="$(date +%s)"
    if [[ "$seconds" -eq 0 ]]; then expires=0; else expires=$((created + seconds)); fi
    id="vps-tools-temp-$(date '+%Y%m%d-%H%M%S')-${RANDOM}"
    temp_dir="$(mktemp -d)" || return 1
    private="$temp_dir/id_ed25519"
    ssh-keygen -q -t ed25519 -N '' -C "$id" -f "$private" || { rm -rf "$temp_dir"; return 1; }
    public="$(cat "$private.pub")"
    grep -Fq " $id" "$TEMP_KEY_AUTH" || printf '%s\n' "$public" >>"$TEMP_KEY_AUTH"
    printf '%s\t%s\t%s\n' "$id" "$created" "$expires" >>"$TEMP_KEY_META"
    chmod 600 "$TEMP_KEY_AUTH" "$TEMP_KEY_META"
    temp_key_install_timer || { error "自动清理定时器安装失败。"; rm -rf "$temp_dir"; return 1; }
    printf '\n===== 私钥（仅显示本次，关闭后无法恢复）=====\n'
    cat "$private"
    printf '===== 私钥结束 =====\n\n'
    printf '密钥 ID：%s\n' "$id"
    if [[ "$expires" -eq 0 ]]; then printf '到期时间：永久 / 手动删除\n'; else printf '到期时间：%s\n' "$(date -d "@$expires" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$expires" '+%Y-%m-%d %H:%M:%S')"; fi
    rm -rf "$temp_dir"
    success "服务器端私钥已立即删除，仅保留公钥授权和元数据。"
}

temp_key_list() {
    local index=0 id created expires expiry_text
    temp_key_cleanup_now || true
    while IFS=$'\t' read -r id created expires; do
        [[ -n "$id" ]] || continue
        index=$((index + 1))
        if [[ "$expires" == "0" ]]; then expiry_text="永久"; else expiry_text="$(date -d "@$expires" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$expires" '+%Y-%m-%d %H:%M:%S')"; fi
        printf '%d. %s | 创建 %s | 到期 %s\n' "$index" "$id" "$(date -d "@$created" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$created" '+%Y-%m-%d %H:%M:%S')" "$expiry_text"
    done <"$TEMP_KEY_META"
    ((index > 0)) || info "暂无临时密钥。"
}

temp_key_remove_ids() {
    local mode="$1" choice choice_number target count temp_meta temp_auth id created expires
    temp_key_prepare || return 1
    temp_key_list
    count="$(awk 'NF {n++} END {print n+0}' "$TEMP_KEY_META")"
    ((count > 0)) || return 0
    if [[ "$mode" == "one" ]]; then
        read -r -p "请输入编号: " choice
        [[ "$choice" =~ ^[0-9]+$ ]] || { error "编号无效。"; return 1; }
        choice_number=$((10#$choice))
        ((choice_number >= 1 && choice_number <= count)) || { error "编号无效。"; return 1; }
        target="$(awk -F '\t' -v n="$choice_number" 'NF {i++} i == n {print $1}' "$TEMP_KEY_META")"
        confirm "确认删除临时密钥 ${target}？" || return 0
    else
        confirm "确认删除全部 VPS Tools 临时密钥？" || return 0
        target="*"
    fi
    backup_file "$TEMP_KEY_AUTH" "$TEMP_KEY_DIR/backups" || return 1
    temp_meta="$(mktemp)"; temp_auth="$(mktemp)" || return 1
    cp "$TEMP_KEY_AUTH" "$temp_auth"
    while IFS=$'\t' read -r id created expires; do
        [[ -n "$id" ]] || continue
        if [[ "$target" == "*" || "$id" == "$target" ]]; then
            awk -v marker="$id" '$NF != marker {print}' "$temp_auth" >"${temp_auth}.next"
            mv "${temp_auth}.next" "$temp_auth"
        else
            printf '%s\t%s\t%s\n' "$id" "$created" "$expires" >>"$temp_meta"
        fi
    done <"$TEMP_KEY_META"
    install -m 0600 "$temp_auth" "$TEMP_KEY_AUTH"
    install -m 0600 "$temp_meta" "$TEMP_KEY_META"
    rm -f "$temp_auth" "$temp_meta"
    success "已删除指定授权，用户原有 authorized_keys 未改动。"
}

module_main() {
    local choice
    temp_key_prepare || { pause; return 1; }
    temp_key_install_timer || { pause; return 1; }
    while true; do
        title "临时 SSH 密钥管理"
        printf '1. 生成临时 SSH 密钥\n2. 查看临时密钥\n3. 删除临时密钥\n4. 删除全部临时密钥\n0. 返回\n\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) temp_key_generate; pause ;;
            2) temp_key_list; pause ;;
            3) temp_key_remove_ids one; pause ;;
            4) temp_key_remove_ids all; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
