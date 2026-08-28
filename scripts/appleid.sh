#!/usr/bin/env bash

APPLE_DIR="${APPLE_DIR:-/root/appleid}"
APPLE_INSTALL_URL="https://raw.githubusercontent.com/SideCloudGroup/AppleAutoPro-Backend/v4/install.sh"

apple_compose_file() {
    [[ -f "$APPLE_DIR/docker-compose.yml" ]] && printf '%s\n' "$APPLE_DIR/docker-compose.yml" && return 0
    [[ -f "$APPLE_DIR/compose.yml" ]] && printf '%s\n' "$APPLE_DIR/compose.yml" && return 0
    return 1
}

apple_install() {
    local api_url api_key api_key_again node_name script
    require_root || return 1
    read -r -p "API URL [https://id.8babao.com]: " api_url
    api_url="${api_url:-https://id.8babao.com}"
    [[ "$api_url" =~ ^https:// ]] || { error "API URL 必须使用 HTTPS。"; return 1; }
    read -r -s -p "请输入 API Key: " api_key; printf '\n'
    read -r -s -p "请再次输入 API Key: " api_key_again; printf '\n'
    [[ -n "$api_key" && "$api_key" == "$api_key_again" ]] || { error "API Key 为空或两次输入不一致。"; return 1; }
    read -r -p "请输入节点名称（英文、数字、._-）: " node_name
    [[ "$node_name" =~ ^[A-Za-z0-9._-]+$ ]] || { error "节点名称无效。"; return 1; }
    script="$(mktemp)" || return 1
    download_file "$APPLE_INSTALL_URL" "$script" || { rm -f "$script"; return 1; }
    API_URL="$api_url" API_KEY="$api_key" NODENAME="$node_name" INSTALL_DIR="$APPLE_DIR" bash "$script"
    local status=$?
    unset api_key api_key_again
    rm -f "$script"
    [[ "$status" -eq 0 ]] || return "$status"
    chmod 700 "$APPLE_DIR"
    chmod 600 "$APPLE_DIR/docker-compose.yml" 2>/dev/null || true
    docker compose -f "$(apple_compose_file)" up -d || return 1
    success "AppleID 后端已安装并启动。"
}

apple_ready() {
    require_root && docker_compose_available && apple_compose_file >/dev/null
}

apple_upgrade() {
    apple_ready || { error "安装目录、Compose 文件或 Docker Compose 不可用。"; return 1; }
    docker compose -f "$(apple_compose_file)" pull backend &&
        docker compose -f "$(apple_compose_file)" up -d --force-recreate backend
}

module_main() {
    local choice compose
    while true; do
        title "AppleID 后端管理"
        printf '1. 安装 AppleID 后端\n2. 升级 AppleID 后端\n3. 查看状态\n4. 查看日志\n0. 返回\n\n'
        read -r -p "请选择: " choice
        case "$choice" in
            1) apple_install; pause ;;
            2) apple_upgrade && success "升级完成。"; pause ;;
            3) if compose="$(apple_compose_file)"; then docker compose -f "$compose" ps; else warn "尚未安装。"; fi; pause ;;
            4) if compose="$(apple_compose_file)"; then docker compose -f "$compose" logs --tail 100 backend; else warn "尚未安装。"; fi; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
