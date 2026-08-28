#!/usr/bin/env bash

PROXY_DIR="${PROXY_DIR:-/root/3proxy}"
PROXY_COMPOSE="$PROXY_DIR/compose.yml"
PROXY_ENV="$PROXY_DIR/.env"

proxy_require_docker() {
    docker_compose_available && return 0
    error "Docker Compose 不可用，请先通过 Docker 管理菜单安装。"
    return 1
}

proxy_read_values() {
    local username password password_again auto http_port socks_port current_http="" current_socks=""
    read -r -p "代理用户名: " username
    [[ "$username" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || { error "用户名只能包含英文、数字、._-。"; return 1; }
    read -r -p "自动生成强密码？[Y/n]: " auto
    if [[ "$auto" =~ ^[Nn]$ ]]; then
        read -r -s -p "代理密码: " password; printf '\n'
        read -r -s -p "再次输入代理密码: " password_again; printf '\n'
        [[ -n "$password" && "$password" == "$password_again" ]] || { error "密码为空或不一致。"; return 1; }
        [[ "$password" =~ ^[A-Za-z0-9_.@%+=:-]{8,128}$ ]] || { error "密码至少 8 位，且只能使用常见安全字符。"; return 1; }
    else
        command_exists openssl || apt_install openssl || return 1
        password="$(openssl rand -hex 18)"
    fi
    read -r -p "HTTP 代理端口 [3128]: " http_port; http_port="${http_port:-3128}"
    read -r -p "SOCKS5 代理端口 [1080]: " socks_port; socks_port="${socks_port:-1080}"
    if ! validate_port "$http_port" || ! validate_port "$socks_port"; then error "端口无效。"; return 1; fi
    [[ "$http_port" != "$socks_port" ]] || { error "两个端口不能相同。"; return 1; }
    if [[ -f "$PROXY_ENV" ]]; then
        current_http="$(sed -n 's/^HTTP_PORT=//p' "$PROXY_ENV")"
        current_socks="$(sed -n 's/^SOCKS_PORT=//p' "$PROXY_ENV")"
    fi
    if command_exists ss; then
        if [[ "$http_port" != "$current_http" ]] && ss -lntuH "sport = :$http_port" | grep -q .; then
            error "HTTP 端口已被占用。"; return 1
        fi
        if [[ "$socks_port" != "$current_socks" ]] && ss -lntuH "sport = :$socks_port" | grep -q .; then
            error "SOCKS5 端口已被占用。"; return 1
        fi
    fi
    PROXY_USERNAME="$username" PROXY_PASSWORD="$password" PROXY_HTTP_PORT="$http_port" PROXY_SOCKS_PORT="$socks_port"
    export PROXY_USERNAME PROXY_PASSWORD PROXY_HTTP_PORT PROXY_SOCKS_PORT
}

proxy_write_config() {
    local temp_env temp_compose
    mkdir -p "$PROXY_DIR"; chmod 700 "$PROXY_DIR"
    [[ ! -f "$PROXY_ENV" ]] || backup_file "$PROXY_ENV" "$VPS_TOOLS_ETC/backups/3proxy" || return 1
    [[ ! -f "$PROXY_COMPOSE" ]] || backup_file "$PROXY_COMPOSE" "$VPS_TOOLS_ETC/backups/3proxy" || return 1
    temp_env="$(mktemp)"; temp_compose="$(mktemp)" || return 1
    {
        printf 'PROXY_LOGIN=%s\n' "$PROXY_USERNAME"
        printf 'PROXY_PASSWORD=%s\n' "$PROXY_PASSWORD"
        printf 'HTTP_PORT=%s\n' "$PROXY_HTTP_PORT"
        printf 'SOCKS_PORT=%s\n' "$PROXY_SOCKS_PORT"
    } >"$temp_env"
    cat >"$temp_compose" <<'COMPOSE'
services:
  proxy:
    image: ghcr.io/tarampampam/3proxy:2
    container_name: vps-tools-3proxy
    restart: unless-stopped
    environment:
      PROXY_LOGIN: ${PROXY_LOGIN}
      PROXY_PASSWORD: ${PROXY_PASSWORD}
      PROXY_PORT: ${HTTP_PORT}
      SOCKS_PORT: ${SOCKS_PORT}
    ports:
      - "${HTTP_PORT}:${HTTP_PORT}/tcp"
      - "${SOCKS_PORT}:${SOCKS_PORT}/tcp"
    security_opt:
      - no-new-privileges:true
COMPOSE
    install -m 0600 "$temp_env" "$PROXY_ENV"
    install -m 0600 "$temp_compose" "$PROXY_COMPOSE"
    rm -f "$temp_env" "$temp_compose"
}

proxy_install() {
    require_root || return 1
    proxy_require_docker || return 1
    proxy_read_values || return 1
    proxy_write_config || return 1
    (cd "$PROXY_DIR" && docker compose pull && docker compose up -d) || return 1
    unset PROXY_PASSWORD
    proxy_show
}

proxy_show() {
    local host username password http_port socks_port
    [[ -f "$PROXY_ENV" ]] || { info "尚未安装。"; return 0; }
    # .env 内容由本脚本的严格字符集生成。
    username="$(sed -n 's/^PROXY_LOGIN=//p' "$PROXY_ENV")"
    password="$(sed -n 's/^PROXY_PASSWORD=//p' "$PROXY_ENV")"
    http_port="$(sed -n 's/^HTTP_PORT=//p' "$PROXY_ENV")"
    socks_port="$(sed -n 's/^SOCKS_PORT=//p' "$PROXY_ENV")"
    host="$(get_public_ip 4)"; [[ -n "$host" ]] || host="[$(get_public_ip 6)]"
    printf '服务器地址：%s\nHTTP 地址：http://%s:%s\nSOCKS5 地址：socks5://%s:%s\n用户名：%s\n密码：%s\n' "$host" "$host" "$http_port" "$host" "$socks_port" "$username" "$password"
    docker compose -f "$PROXY_COMPOSE" ps 2>/dev/null || true
}

proxy_action() {
    local action="$1"
    proxy_require_docker || return 1
    [[ -f "$PROXY_COMPOSE" ]] || { error "尚未安装。"; return 1; }
    docker compose -f "$PROXY_COMPOSE" "$action"
}

proxy_upgrade() {
    proxy_require_docker || return 1
    [[ -f "$PROXY_COMPOSE" ]] || return 1
    docker compose -f "$PROXY_COMPOSE" pull && docker compose -f "$PROXY_COMPOSE" up -d
}

proxy_uninstall() {
    local answer
    require_root || return 1
    [[ -d "$PROXY_DIR" ]] || { info "尚未安装。"; return 0; }
    confirm "确认卸载 3proxy 并删除本地凭证？" || return 0
    [[ ! -f "$PROXY_ENV" ]] || backup_file "$PROXY_ENV" "$VPS_TOOLS_ETC/backups/3proxy" || return 1
    [[ ! -f "$PROXY_COMPOSE" ]] || backup_file "$PROXY_COMPOSE" "$VPS_TOOLS_ETC/backups/3proxy" || return 1
    [[ ! -f "$PROXY_COMPOSE" ]] || docker compose -f "$PROXY_COMPOSE" down --remove-orphans
    rm -rf -- "$PROXY_DIR"
    read -r -p "是否同时删除包含凭证的历史备份？[Y/n]: " answer
    if [[ ! "$answer" =~ ^[Nn]$ ]]; then
        find "$VPS_TOOLS_ETC/backups/3proxy" -maxdepth 1 -type f \( -name '.env.*.bak' -o -name 'compose.yml.*.bak' \) -delete 2>/dev/null || true
        success "3proxy 已卸载，凭证备份已删除。"
    else
        warn "历史备份中仍可能保存用户名 / 密码。"
        success "3proxy 已卸载，本地配置备份保留在 $VPS_TOOLS_ETC/backups/3proxy。"
    fi
}

module_main() {
    local choice
    while true; do
        title "HTTP / SOCKS5 代理（3proxy）"
        printf '1. 安装\n2. 查看代理信息\n3. 修改用户名 / 密码\n4. 修改端口\n5. 启动\n6. 停止\n7. 重启\n8. 升级\n9. 卸载\n0. 返回\n\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1|3|4) proxy_install; pause ;;
            2) proxy_show; pause ;;
            5) proxy_action start; pause ;;
            6) proxy_action stop; pause ;;
            7) proxy_action restart; pause ;;
            8) proxy_upgrade && success "升级完成。"; pause ;;
            9) proxy_uninstall; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
