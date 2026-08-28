#!/usr/bin/env bash

docker_status_header() {
    local total=0 running=0 images=0
    if command_exists docker; then
        total="$(docker ps -aq 2>/dev/null | awk 'NF {n++} END {print n+0}')"
        running="$(docker ps -q 2>/dev/null | awk 'NF {n++} END {print n+0}')"
        images="$(docker image ls -q 2>/dev/null | sort -u | awk 'NF {n++} END {print n+0}')"
        printf 'Docker 状态：%s\n' "$(docker info >/dev/null 2>&1 && printf '运行中' || printf '不可用')"
        printf 'Docker 版本：%s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || docker --version 2>/dev/null || printf '未知')"
    else
        printf 'Docker 状态：未安装\nDocker 版本：-\n'
    fi
    printf '容器数量：%s（运行 %s）\n镜像数量：%s\n\n' "$total" "$running" "$images"
}

docker_require() {
    docker_available || { error "Docker 未安装、未运行或当前用户无权限。"; return 1; }
}

docker_select_container() {
    local filter="${1:-all}" choice choice_number i
    local containers=()
    if [[ "$filter" == "running" ]]; then
        mapfile -t containers < <(docker ps --format '{{.Names}}')
    elif [[ "$filter" == "stopped" ]]; then
        mapfile -t containers < <(docker ps -a --filter status=exited --filter status=created --format '{{.Names}}')
    else
        mapfile -t containers < <(docker ps -a --format '{{.Names}}')
    fi
    ((${#containers[@]} > 0)) || { warn "没有可选容器。"; return 1; }
    for i in "${!containers[@]}"; do printf '%d. %s\n' "$((i + 1))" "${containers[$i]}" >&2; done
    read -r -p "请选择容器编号: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || { error "编号无效。"; return 1; }
    choice_number=$((10#$choice))
    ((choice_number >= 1 && choice_number <= ${#containers[@]})) || { error "编号无效。"; return 1; }
    printf '%s\n' "${containers[$((choice_number - 1))]}"
}

docker_select_image() {
    local choice choice_number i selected
    local images=()
    mapfile -t images < <(docker image ls --format '{{.Repository}}:{{.Tag}}|{{.ID}}')
    ((${#images[@]} > 0)) || { warn "没有可选镜像。"; return 1; }
    for i in "${!images[@]}"; do printf '%d. %s\n' "$((i + 1))" "${images[$i]%%|*}" >&2; done
    read -r -p "请选择镜像编号: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || { error "编号无效。"; return 1; }
    choice_number=$((10#$choice))
    ((choice_number >= 1 && choice_number <= ${#images[@]})) || { error "编号无效。"; return 1; }
    selected="${images[$((choice_number - 1))]}"
    printf '%s\n' "${selected##*|}"
}

docker_logs_menu() {
    local container choice
    container="$(docker_select_container all)" || return 1
    printf '1. 最近 100 行\n2. 最近 500 行\n3. 实时跟踪\n0. 返回\n'
    read -r -p "请选择: " choice
    case "$choice" in
        1) docker logs --tail 100 "$container" ;;
        2) docker logs --tail 500 "$container" ;;
        3) info "按 Ctrl+C 返回，不会停止容器。"; docker logs -f --tail 100 "$container" || true ;;
        0) return 0 ;;
        *) error "无效选项。"; return 1 ;;
    esac
}

docker_one_action() {
    local action="$1" filter="${2:-all}" container
    container="$(docker_select_container "$filter")" || return 1
    if [[ "$action" == "rm" ]]; then
        confirm "确认删除容器 ${container}？" || return 0
        docker rm -f "$container"
    else
        docker "$action" "$container"
    fi
}

docker_all_action() {
    local action="$1" filter="$2" prompt="$3"
    local ids=()
    case "$filter" in
        all) mapfile -t ids < <(docker ps -aq) ;;
        running) mapfile -t ids < <(docker ps -q) ;;
        stopped) mapfile -t ids < <(docker ps -aq --filter status=exited --filter status=created) ;;
    esac
    ((${#ids[@]} > 0)) || { info "没有符合条件的容器。"; return 0; }
    [[ -z "$prompt" ]] || confirm "$prompt" || return 0
    if [[ "$action" == "rm" ]]; then
        docker rm -f "${ids[@]}"
    else
        docker "$action" "${ids[@]}"
    fi
}

docker_remove_image() {
    local image
    image="$(docker_select_image)" || return 1
    confirm "确认删除所选镜像？" && docker image rm "$image"
}

docker_remove_all_images() {
    local ids=()
    mapfile -t ids < <(docker image ls -q | sort -u)
    ((${#ids[@]} > 0)) || { info "没有镜像。"; return 0; }
    confirm "确认删除所有可删除镜像？正在被容器使用的镜像会保留。" || return 0
    docker image rm "${ids[@]}" || warn "部分镜像正在使用，未被删除。"
}

docker_official_install() {
    local script
    require_root || return 1
    if command_exists docker; then info "Docker 已安装。"; return 0; fi
    confirm "使用 Docker 官方 get.docker.com 安装脚本？" || return 0
    script="$(mktemp)" || return 1
    download_file "https://get.docker.com" "$script" || { rm -f "$script"; return 1; }
    sh "$script" || { rm -f "$script"; return 1; }
    rm -f "$script"
    systemctl enable --now docker
    docker version
}

docker_linuxmirrors() {
    local only_registry="${1:-0}" script
    require_root || return 1
    script="$(mktemp)" || return 1
    download_file "https://linuxmirrors.cn/docker.sh" "$script" || { rm -f "$script"; return 1; }
    if [[ "$only_registry" == "1" ]]; then
        bash "$script" --only-registry
    else
        bash "$script"
    fi
    local status=$?
    rm -f "$script"
    return "$status"
}

module_main() {
    local choice
    while true; do
        title "Docker 管理"
        docker_status_header
        cat <<'MENU'
[容器管理]
 1. 列出所有容器
 2. 查看容器日志
 3. 重启某个容器
 4. 重启所有容器
 5. 停止某个容器
 6. 停止所有容器
 7. 启动某个容器
 8. 启动所有已停止容器
 9. 删除某个容器
10. 删除所有容器

[镜像管理]
11. 列出所有镜像
12. 删除某个镜像
13. 删除所有镜像

[Docker 服务]
14. 重启 Docker 服务
15. 查看 Docker 状态
16. 查看 Docker 磁盘占用

[安装 / 维护]
17. 官方方式安装 Docker
18. LinuxMirrors 安装 Docker
19. Docker 镜像源管理
 0. 返回
MENU
        printf '\n'; read -r -p "请选择: " choice
        case "$choice" in
            1) docker_require && docker ps -a; pause ;;
            2) docker_require && docker_logs_menu; pause ;;
            3) docker_require && docker_one_action restart all; pause ;;
            4) docker_require && docker_all_action restart all ""; pause ;;
            5) docker_require && docker_one_action stop running; pause ;;
            6) docker_require && docker_all_action stop running "确认停止所有运行中容器？"; pause ;;
            7) docker_require && docker_one_action start stopped; pause ;;
            8) docker_require && docker_all_action start stopped ""; pause ;;
            9) docker_require && docker_one_action rm all; pause ;;
            10) docker_require && docker_all_action rm all "确认删除所有容器？"; pause ;;
            11) docker_require && docker image ls; pause ;;
            12) docker_require && docker_remove_image; pause ;;
            13) docker_require && docker_remove_all_images; pause ;;
            14) require_root && systemctl restart docker; pause ;;
            15) systemctl status docker --no-pager -n 30; pause ;;
            16) docker_require && docker system df; pause ;;
            17) docker_official_install; pause ;;
            18) docker_linuxmirrors 0; pause ;;
            19) docker_linuxmirrors 1; pause ;;
            0) return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}
