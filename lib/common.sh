#!/usr/bin/env bash

# VPS Tools 公共函数库。模块通过主入口加载，不应单独保存敏感信息。

VPS_TOOLS_VERSION="1.0.0"
VPS_TOOLS_ETC="${VPS_TOOLS_ETC:-/etc/vps-tools}"
export VPS_TOOLS_VERSION

if [[ -t 1 && "${NO_COLOR:-0}" != "1" ]]; then
    COLOR_RED='\033[31m'
    COLOR_GREEN='\033[32m'
    COLOR_YELLOW='\033[33m'
    COLOR_BLUE='\033[36m'
    COLOR_RESET='\033[0m'
else
    COLOR_RED=''
    COLOR_GREEN=''
    COLOR_YELLOW=''
    COLOR_BLUE=''
    COLOR_RESET=''
fi

info() { printf '%b[信息]%b %s\n' "$COLOR_BLUE" "$COLOR_RESET" "$*"; }
success() { printf '%b[成功]%b %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"; }
warn() { printf '%b[注意]%b %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2; }
error() { printf '%b[错误]%b %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2; }

title() {
    clear 2>/dev/null || true
    printf '%b========================================%b\n' "$COLOR_BLUE" "$COLOR_RESET"
    printf '  %s\n' "$1"
    printf '%b========================================%b\n\n' "$COLOR_BLUE" "$COLOR_RESET"
}

pause() {
    [[ "${VPS_TOOLS_NONINTERACTIVE:-0}" == "1" ]] && return 0
    printf '\n'
    read -r -p "按回车键继续..." _unused
}

command_exists() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ "$(id -u)" -eq 0 ]]; }

require_root() {
    if is_root; then
        return 0
    fi
    error "此功能需要 root 权限。请使用 sudo -i 后重新运行工具箱。"
    return 1
}

require_debian_ubuntu() {
    if [[ ! -r /etc/os-release ]]; then
        error "无法识别系统，仅支持 Debian / Ubuntu。"
        return 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) return 0 ;;
        *) error "当前系统 ${PRETTY_NAME:-未知} 不受此功能支持。"; return 1 ;;
    esac
}

apt_install() {
    require_root || return 1
    require_debian_ubuntu || return 1
    local missing=() package
    for package in "$@"; do
        dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' || missing+=("$package")
    done
    ((${#missing[@]} == 0)) && return 0
    info "正在安装：${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update || { error "apt-get update 失败。"; return 1; }
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" || { error "软件安装失败：${missing[*]}"; return 1; }
}

confirm() {
    local prompt="${1:-确认继续吗？}" answer
    [[ "${VPS_TOOLS_ASSUME_YES:-0}" == "1" ]] && return 0
    read -r -p "$prompt [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

validate_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 > 0))
}

validate_port_range() {
    validate_port "$1" && validate_port "$2" && ((10#$1 <= 10#$2))
}

validate_hostname_or_ip() {
    local target="$1"
    [[ -n "$target" && "$target" =~ ^[A-Za-z0-9._:-]+$ && "$target" != -* ]]
}

backup_file() {
    local file="$1" backup_dir="${2:-$VPS_TOOLS_ETC/backups}" stamp
    [[ -e "$file" ]] || return 0
    stamp="$(date '+%Y%m%d-%H%M%S')"
    mkdir -p "$backup_dir"
    chmod 700 "$backup_dir"
    cp -a -- "$file" "$backup_dir/$(basename "$file").$stamp.bak"
    info "已备份 $file"
}

download_file() {
    local url="$1" destination="$2"
    command_exists curl || apt_install curl ca-certificates || return 1
    curl -fL --retry 2 --connect-timeout 10 --max-time 120 --proto '=https' --tlsv1.2 \
        -o "$destination" "$url" || { error "下载失败：$url"; rm -f "$destination"; return 1; }
    [[ -s "$destination" ]] || { error "下载内容为空：$url"; rm -f "$destination"; return 1; }
}

run_remote_bash() {
    local url="$1" label="$2" temp_file status
    temp_file="$(mktemp)" || return 1
    if ! download_file "$url" "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi
    info "即将启动第三方项目：$label"
    bash "$temp_file"
    status=$?
    rm -f "$temp_file"
    return "$status"
}

get_public_ip() {
    local family="$1" result
    result="$(curl "-$family" -fsS --connect-timeout 5 --max-time 10 https://ip.p3terx.com 2>/dev/null || true)"
    [[ -n "$result" ]] && printf '%s\n' "$result"
}

get_cloudflare_warp_state() {
    local family="$1" result
    result="$(curl "-$family" -kfsS --connect-timeout 5 --max-time 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '$1 == "warp" {print $2}' || true)"
    printf '%s\n' "${result:-不可用}"
}

detect_default_interface() {
    local family="$1" probe route
    if [[ "$family" == "4" ]]; then probe="1.1.1.1"; else probe="2606:4700:4700::1111"; fi
    route="$(ip "-$family" route get "$probe" 2>/dev/null | head -n1 || true)"
    awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}' <<<"$route"
}

is_virtual_interface_name() {
    case "$1" in
        lo|docker*|br-*|veth*|wg*|warp*|tun*|tap*|tailscale*|zt*|virbr*) return 0 ;;
        *) return 1 ;;
    esac
}

detect_inbound_interface() {
    local family="$1" line iface address fallback=""
    while read -r line; do
        iface="${line%% *}"
        [[ "$iface" == *"@"* ]] && iface="${iface%%@*}"
        is_virtual_interface_name "$iface" && continue
        address="$(awk '{print $2}' <<<"$line")"
        [[ -n "$address" ]] || continue
        if [[ -z "$fallback" ]]; then fallback="$iface"; fi
        printf '%s\n' "$iface"
        return 0
    done < <(ip "-$family" -o addr show scope global 2>/dev/null | awk '{print $2, $4}')
    if [[ -n "$fallback" ]]; then printf '%s\n' "$fallback"; return 0; fi
    fallback="$(detect_default_interface "$family")"
    is_virtual_interface_name "$fallback" && return 0
    printf '%s\n' "$fallback"
}

docker_available() { command_exists docker && docker info >/dev/null 2>&1; }
docker_compose_available() { command_exists docker && docker compose version >/dev/null 2>&1; }

service_name_for_ssh() {
    if systemctl list-unit-files ssh.service --no-legend 2>/dev/null | grep -q '^ssh.service'; then
        printf 'ssh\n'
    elif systemctl list-unit-files sshd.service --no-legend 2>/dev/null | grep -q '^sshd.service'; then
        printf 'sshd\n'
    else
        return 1
    fi
}

safe_systemctl() {
    command_exists systemctl || { error "当前系统未提供 systemd。"; return 1; }
    systemctl "$@"
}
