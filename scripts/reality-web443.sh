#!/usr/bin/env bash

REALITY_WEB443_SETUP_URL="https://raw.githubusercontent.com/pixingzoudaiyuexing/reality-web443-setup/main/reality-web443-setup.sh"

module_main() {
    local status

    title "REALITY 443 + 网站 HTTPS 复用"
    cat <<'TEXT'
用于已有 REALITY/VLESS 节点占用公网 443 时，同时让网站继续通过 HTTPS 443 访问。

上游脚本会交互完成：
- 安装 Nginx、Certbot、iptables 等基础工具
- 为网站域名申请 Let's Encrypt 证书
- 创建本机 HTTPS 回落，例如 127.0.0.1:8443 -> 127.0.0.1:5244
- 配置证书自动续期与 Nginx reload
- 可选配置 NAT 兼容转发

脚本来源：
https://github.com/pixingzoudaiyuexing/reality-web443-setup
TEXT

    require_root || { pause; return 1; }

    if ! confirm "确认启动 REALITY 443 + 网站 HTTPS 复用部署脚本？"; then
        info "已取消。"
        pause
        return 0
    fi

    if run_remote_bash "$REALITY_WEB443_SETUP_URL" "REALITY 443 + 网站 HTTPS 复用部署"; then
        status=0
        success "REALITY 443 + 网站 HTTPS 复用脚本执行完成。"
    else
        status=$?
        error "REALITY 443 + 网站 HTTPS 复用脚本执行失败，退出码：$status"
    fi

    pause
    return "$status"
}
