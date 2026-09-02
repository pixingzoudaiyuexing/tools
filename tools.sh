#!/usr/bin/env bash

set -u

RAW_BASE="${VPS_TOOLS_RAW_BASE:-https://raw.githubusercontent.com/pixingzoudaiyuexing/tools/main}"
TEMP_ROOT=""
CA_BUNDLE="${VPS_TOOLS_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"

cleanup() {
    [[ -n "$TEMP_ROOT" && -d "$TEMP_ROOT" ]] && rm -rf "$TEMP_ROOT"
    return 0
}

handle_interrupt() {
    printf '\n已退出 VPS Tools。\n'
    exit 130
}

handle_terminate() {
    exit 143
}

trap cleanup EXIT
trap handle_interrupt INT
trap handle_terminate TERM

bootstrap_is_debian_ubuntu() (
    [[ -r /etc/os-release ]] || return 1
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) return 0 ;;
        *) return 1 ;;
    esac
)

bootstrap_download_environment() {
    if command -v curl >/dev/null 2>&1 && command -v wget >/dev/null 2>&1 && { ! bootstrap_is_debian_ubuntu || [[ -s "$CA_BUNDLE" ]]; }; then
        return 0
    fi

    if ! bootstrap_is_debian_ubuntu; then
        printf '缺少可用的 curl / wget，当前系统无法自动修复。\n' >&2
        return 1
    fi
    if [[ "$(id -u)" -ne 0 ]]; then
        printf '检测到 curl、wget 或 CA 证书环境异常，请先使用 sudo -i 获取 root 权限后重试。\n' >&2
        return 1
    fi

    printf '检测到 curl、wget 或 CA 证书环境异常，正在自动修复...\n'
    mkdir -p "$(dirname "$CA_BUNDLE")" || return 1
    DEBIAN_FRONTEND=noninteractive apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y openssl ca-certificates || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget || return 1
    update-ca-certificates --fresh || return 1

    command -v curl >/dev/null 2>&1 || return 1
    command -v wget >/dev/null 2>&1 || return 1
    [[ -s "$CA_BUNDLE" ]] || return 1
    printf 'curl、wget 与 CA 证书环境修复完成。\n'
}

resolve_local_root() {
    local source_dir
    source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || return 1
    [[ -f "$source_dir/lib/common.sh" ]] || return 1
    printf '%s\n' "$source_dir"
}

prepare_runtime() {
    if [[ -n "${VPS_TOOLS_LOCAL_ROOT:-}" && -f "$VPS_TOOLS_LOCAL_ROOT/lib/common.sh" ]]; then
        VPS_TOOLS_ROOT="$VPS_TOOLS_LOCAL_ROOT"
    elif VPS_TOOLS_ROOT="$(resolve_local_root)"; then
        :
    else
        bootstrap_download_environment || { printf '基础下载环境修复失败。\n' >&2; exit 1; }
        TEMP_ROOT="$(mktemp -d)" || { printf '无法创建临时目录。\n' >&2; exit 1; }
        mkdir -p "$TEMP_ROOT/lib" "$TEMP_ROOT/scripts"
        if ! curl -fL --retry 2 --connect-timeout 10 --max-time 60 --proto '=https' --tlsv1.2 \
            -o "$TEMP_ROOT/lib/common.sh" "$RAW_BASE/lib/common.sh"; then
            printf '公共库下载失败，请检查网络后重试。\n' >&2
            exit 1
        fi
        VPS_TOOLS_ROOT="$TEMP_ROOT"
    fi
    export VPS_TOOLS_ROOT VPS_TOOLS_RAW_BASE="$RAW_BASE"
    # shellcheck source=lib/common.sh
    . "$VPS_TOOLS_ROOT/lib/common.sh"
}

load_module() {
    local module="$1" module_file status
    module_file="$VPS_TOOLS_ROOT/scripts/$module.sh"
    if [[ ! -f "$module_file" ]]; then
        mkdir -p "$(dirname "$module_file")"
        download_file "$RAW_BASE/scripts/$module.sh" "$module_file" || return 1
    fi
    # shellcheck disable=SC1090
    . "$module_file"
    if ! declare -F module_main >/dev/null; then
        error "模块 $module 缺少入口函数。"
        return 1
    fi
    if module_main; then
        status=0
    else
        status=$?
    fi
    unset -f module_main 2>/dev/null || true
    return "$status"
}

install_shortcut() {
    require_root || return 1
    local target="/usr/local/bin/tools" temp_file
    temp_file="$(mktemp)" || return 1
    cat >"$temp_file" <<'LAUNCHER'
#!/usr/bin/env bash
set -o pipefail
url="https://raw.githubusercontent.com/pixingzoudaiyuexing/tools/main/tools.sh"
temp_file="$(mktemp)" || exit 1
cleanup_launcher() {
    rm -f "$temp_file"
}
repair_launcher_environment() {
    if command -v curl >/dev/null 2>&1 && command -v wget >/dev/null 2>&1 && [[ -s /etc/ssl/certs/ca-certificates.crt ]]; then
        return 0
    fi
    [[ "$(id -u)" -eq 0 ]] || { printf 'curl、wget 或 CA 证书环境异常，请先使用 sudo -i 后重试。\n' >&2; return 1; }
    [[ -r /etc/os-release ]] || return 1
    (
        . /etc/os-release
        case "${ID:-}" in debian|ubuntu) exit 0 ;; *) exit 1 ;; esac
    ) || { printf '当前系统无法自动修复 curl / wget / CA 环境。\n' >&2; return 1; }
    printf '检测到 curl、wget 或 CA 证书环境异常，正在自动修复...\n'
    mkdir -p /etc/ssl/certs || return 1
    DEBIAN_FRONTEND=noninteractive apt-get update || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y openssl ca-certificates || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget || return 1
    update-ca-certificates --fresh || return 1
    command -v curl >/dev/null 2>&1 && command -v wget >/dev/null 2>&1 && [[ -s /etc/ssl/certs/ca-certificates.crt ]]
}
trap cleanup_launcher EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
repair_launcher_environment || exit 1
curl -fL --retry 2 --connect-timeout 10 --max-time 120 --proto '=https' --tlsv1.2 -o "$temp_file" "$url" || exit 1
[[ -s "$temp_file" ]] || exit 1
bash "$temp_file" "$@"
exit $?
LAUNCHER
    install -m 0755 "$temp_file" "$target"
    rm -f "$temp_file"
    success "快捷命令已安装：$target"
    info "以后输入 tools 即可加载 GitHub 最新版。"
}

show_info() {
    title "VPS Tools 工具箱信息"
    printf '版本：%s\n' "$VPS_TOOLS_VERSION"
    printf '仓库：https://github.com/pixingzoudaiyuexing/tools\n'
    printf '运行目录：%s\n' "$VPS_TOOLS_ROOT"
    printf '当前时间：%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    pause
}

main_menu() {
    local choice
    while true; do
        title "VPS Tools"
        cat <<'MENU'
[节点 / 服务]
 1. V2Node 多节点管理
 2. AppleID 后端管理

[网络工具]
 3. 查看公网 IPv4 / IPv6
 4. 端口占用 / 监听查询
 5. UDP / Hy2 端口跳跃
 6. VPS 端口中转（Realm）
 7. 路由 / 链路测试
 8. WARP 网络管理
 9. DDNS 管理
10. HTTP / SOCKS5 代理
11. BBRv3 内核 / 网络优化
12. 流媒体 / 地区解锁检测
13. TikTok 地区检测
14. 樱花 VPS IPv6 启用

[系统工具]
15. Linux 系统换源
16. Swap 管理
17. 时间 / 时区管理
18. Root SSH 管理
19. 临时 SSH 密钥管理
20. VPS 系统重装

[Docker]
21. Docker 管理

[工具箱]
98. 安装 tools 快捷命令
99. 查看工具箱信息
 0. 退出
MENU
        printf '\n'
        read -r -p "请选择功能: " choice
        case "$choice" in
            1) load_module v2node ;;
            2) load_module appleid ;;
            3) load_module ip-check ;;
            4) load_module port-check ;;
            5) load_module porthop ;;
            6) load_module realm ;;
            7) load_module route-test ;;
            8) load_module warp ;;
            9) load_module ddns ;;
            10) load_module proxy ;;
            11) load_module bbr ;;
            12) load_module media ;;
            13) load_module tiktok ;;
            14) load_module sakura-ipv6 ;;
            15) load_module mirrors ;;
            16) load_module swap ;;
            17) load_module time ;;
            18) load_module root-ssh ;;
            19) load_module temp-ssh-key ;;
            20) load_module reinstall ;;
            21) load_module docker ;;
            98) install_shortcut; pause ;;
            99) show_info ;;
            0) success "已退出。"; return 0 ;;
            *) warn "无效选项。"; pause ;;
        esac
    done
}

prepare_runtime
if [[ -n "${VPS_TOOLS_MODULE:-}" ]]; then
    load_module "$VPS_TOOLS_MODULE"
else
    main_menu
fi
