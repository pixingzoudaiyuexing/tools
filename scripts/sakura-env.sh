#!/usr/bin/env bash

module_main() {
    title "樱花 VPS 基础环境修复"
    cat <<'TEXT'
主要用于樱花 VPS Debian 12 刚开机后的基础下载环境修复。
会执行：
- 创建 /etc/ssl/certs
- apt-get update
- 重新安装 openssl / ca-certificates
- 安装 curl / wget
- update-ca-certificates --fresh

也可用于 Debian / Ubuntu 的 curl、wget 或 CA 证书异常修复。
TEXT

    require_root || { pause; return 1; }
    require_debian_ubuntu || { pause; return 1; }

    if ! confirm "确认修复 curl / wget / CA 证书环境？"; then
        info "已取消。"
        pause
        return 0
    fi

    if repair_download_environment; then
        printf '\n'
        printf 'curl：%s\n' "$(curl --version 2>/dev/null | head -n1 || printf '不可用')"
        printf 'wget：%s\n' "$(wget --version 2>/dev/null | head -n1 || printf '不可用')"
        if [[ -s /etc/ssl/certs/ca-certificates.crt ]]; then
            success "CA 证书文件正常：/etc/ssl/certs/ca-certificates.crt"
        else
            error "CA 证书文件仍不存在或为空。"
            pause
            return 1
        fi
    else
        error "基础环境修复失败。"
        pause
        return 1
    fi

    pause
}
