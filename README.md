# VPS Tools

个人长期使用的中文 VPS 运维工具箱。主入口保持轻量，功能按模块从 GitHub 当前 `main` 分支按需加载，不会在 VPS 上保存整套工具箱副本。

## 一键使用

普通 Debian / Ubuntu：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pixingzoudaiyuexing/tools/main/tools.sh)
```

### 樱花 VPS Debian 12 首次初始化

部分樱花 VPS 的 Debian 12 初始系统可能没有安装 `curl` / `wget`，或者 `/etc/ssl/certs` / CA 证书环境不完整。第一次使用时先执行下面这一条完整命令；其中已经包含 `apt update`、CA 证书修复以及 `curl` / `wget` 安装：

```bash
mkdir -p /etc/ssl/certs && \
apt update && \
DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y openssl ca-certificates && \
DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget && \
update-ca-certificates --fresh && \
bash <(curl -fsSL https://raw.githubusercontent.com/pixingzoudaiyuexing/tools/main/tools.sh)
```

如果已经可以正常运行 `curl`、`wget` 且 `/etc/ssl/certs/ca-certificates.crt` 存在，直接使用普通一键命令即可。

工具箱内部在后续下载模块时也会检查 Debian / Ubuntu 的 `curl`、`wget` 与 CA 证书环境；如果发现缺失并且当前是 root，会自动执行 `apt-get update`、重新安装 `openssl` / `ca-certificates`、安装 `curl` / `wget` 并刷新 CA 证书。

系统级功能需要 root。普通 sudo 用户可先执行 `sudo -i`，再运行上面的命令。

在主菜单选择 `98. 安装 tools 快捷命令` 后，会创建：

```text
/usr/local/bin/tools
```

以后直接输入：

```bash
tools
```

快捷启动器每次联网加载 GitHub 最新版 `tools.sh`，不会保存工具箱副本；快捷启动器也会在 Debian / Ubuntu 上检查并尝试修复 `curl` / `wget` / CA 证书环境。

## 功能

### 节点 / 服务

- V2Node 多节点管理。
- AppleID 后端管理。
- REALITY 443 + 网站 HTTPS 复用：直接调用 [pixingzoudaiyuexing/reality-web443-setup](https://github.com/pixingzoudaiyuexing/reality-web443-setup) 最新脚本，为已占用公网 443 的 REALITY/VLESS 节点配置网站 HTTPS 回落、Let's Encrypt 证书、Nginx、自动续期以及可选 NAT 兼容转发。

### 网络工具

- 公网 IPv4 / IPv6 检测，任一协议族失败不会中断另一个。
- TCP/UDP 监听和指定端口占用查询，使用 `ss`，可选安装 `lsof`。
- UDP / Hy2 端口跳跃：IPv4/IPv6 独立网卡、多规则、冲突检查、nftables 语法检查和 systemd 持久化。
- Realm 端口中转：提供 IPv4 / IPv6 自动识别的快速添加入口，支持“双栈中转 → 纯 IPv6 落地”；裸 IPv6 会自动转换为 `[IPv6]:端口`，写入前显示目标类型和转发链路。若上游脚本安装的 Realm 出现 `GLIBC_x.xx not found`，VPS Tools 会自动从 Realm 官方最新 Release 选择 `glibc2.28` 兼容构建替换二进制并重启服务，也可在 Realm 菜单手动执行“glibc 兼容修复”；不会升级系统 glibc。新规则导致 Realm 启动失败时会自动恢复原配置；完整上游 Realm 管理脚本仍保留用于安装、删除、端口段、日志和面板管理。
- NextTrace ICMP/TCP/UDP 路由测试和 MTR 丢包/延迟测试。
- WARP：提供“纯 IPv4 机器一键添加 IPv6”和“纯 IPv6 机器一键添加 IPv4”两个快捷入口。选择后自动检测原生协议族、自动调用 `warp-yg` 完成后续部署并验证目标状态，不需要继续在上游菜单中手动选择；同时提供“一键卸载所有 WARP”，统一停止并清理 WARP-GO、WGCF、Socks5-WARP / `cloudflare-warp`、`warp-yg` 在线监测和已知残留，完成后自动检查 WARP 与当前 IPv4 / IPv6 状态。
- WARP 自动快捷项只允许在真实纯 IPv4 / 纯 IPv6 网络上执行；双栈机器会直接拒绝。若同时检测到 warp-go 与 WGCF 配置，也会停止自动部署，避免盲目修改路由。首次安装默认使用 WARP-GO；若已经存在单一 WARP 后端，则尽量沿用现有后端。WARP 一键卸载不会删除通用 `wireguard-tools`，也不会执行全局 iptables / nftables 清空。
- DDNS-GO：Cloudflare、华为云、阿里云、DNSPod，A/AAAA 可分别启用，本地 `-noweb` 服务。
- 3proxy Docker：带认证的 HTTP / SOCKS5 代理安装、修改、启停、升级和卸载。
- BBR / BBRv3：12 号菜单提供“快速开启 BBR + FQ”，选择后直接使用当前内核已有 BBR 自动设置 `net.ipv4.tcp_congestion_control=bbr` 和 `net.core.default_qdisc=fq`，写入独立 sysctl 持久化配置并验证状态，不需要再进入上游分级菜单；若当前内核没有 BBR，则提示使用保留的 Actions-bbr-v3 完整管理脚本。
- 流媒体解锁、TikTok 地区检测入口。
- 樱花 VPS Debian 12 预置 IPv6 精确启用和验证。
- 樱花 VPS 基础环境修复：`apt-get update`、重新安装 `openssl` / `ca-certificates`、安装 `curl` / `wget` 并刷新 CA 证书。

### 系统工具

- LinuxMirrors 系统换源。
- `/swapfile` 专属 Swap 查看、创建、修改和删除；不会执行 `swapoff -a`。
- 时区、时间同步状态、systemd-timesyncd / chrony 管理。
- Root SSH 密码登录：仅写入 `/etc/ssh/sshd_config.d/00-vps-tools-root.conf`，修改前后执行 `sshd -t` 并验证实际生效配置。
- Root 临时 Ed25519 密钥：1 小时、6 小时、24 小时、7 天或永久，systemd timer 负责真正到期失效。
- bin456789/reinstall 系统重装入口。

### Docker

- 容器列表、日志、启停、重启和删除，单个对象均通过编号选择。
- 镜像列表和删除。
- Docker 服务状态、重启和磁盘占用。
- Docker 官方安装、LinuxMirrors 安装和 `--only-registry` 镜像源管理。
- 不提供 `docker system prune -a`。

## 支持系统

优先支持：

- Debian 11 / 12 / 13
- Ubuntu 22.04 / 24.04 及现代版本

各模块会在执行前检查系统、root、命令和服务。樱花 IPv6 模块只支持其官方文档对应的 Debian 12；BBRv3 当前上游最低安装环境已调整为 Debian 12 / Ubuntu 24.04。

## 安全边界

- VPS Tools 自身的确认提示统一使用 `[Y/n]`：直接回车表示 Yes，只有明确输入 `n` / `N` 才取消。
- 高风险操作仍会显示明确警告，但不要求输入特殊确认字符串。
- Realm glibc 兼容修复只替换 Realm 自己的二进制并保留备份，不会安装、升级或替换系统 `glibc` / `libc6`。
- BBR + FQ 快捷项不会安装或切换内核，只操作当前内核已有的拥塞控制和默认队列；使用独立 `/etc/sysctl.d/99-vps-tools-bbr-fq.conf` 持久化，应用失败时恢复修改前的运行参数和原配置文件。
- WARP 两个自动快捷项在用户选择后不再二次询问；因此会先严格验证机器确实是纯 IPv4 或纯 IPv6，并检查冲突后端和上游菜单结构，任何一项不符合都会停止而不是猜测执行。
- WARP 一键卸载会先显示 `[Y/n]` 确认，然后自动完成后续清理；不会卸载通用 WireGuard 软件包，也不会清空用户已有的 iptables / nftables 规则。
- 端口跳跃只创建 `table ip vps_tools_porthop` 和 `table ip6 vps_tools_porthop`，不会执行 `nft flush ruleset`，不会清空其他防火墙。
- Root SSH 只管理自己的 drop-in 文件，恢复时不会重写原始 `sshd_config`。
- 临时 SSH 密钥只删除带唯一 `vps-tools-temp-*` ID 的公钥行；私钥只显示一次，随后立即从服务器删除。
- DDNS 凭证、AppleID API Key 和代理密码只在 VPS 本地交互输入和保存，不写入 GitHub。敏感配置权限为 `600`。
- DDNS 检测到 IPv4 `warp=on` 时，不会默认把 WARP 出口作为 A 记录，而会要求选择真实 IPv4 网卡。
- 修改重要系统配置前会在 `/etc/vps-tools/` 相应目录下创建备份。

运行 Root SSH、WARP、nftables、Docker 删除、内核安装或系统重装前，请确保有 VPS 控制台、救援模式和可用备份。

## V2Node 旧入口兼容

旧 URL 仍可使用，它会转入新的 V2Node 模块：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pixingzoudaiyuexing/tools/main/node)
```

## 第三方项目

本仓库只提供安全下载、环境检查和管理包装，不复制以下项目源码：

- [wcwq98/realm](https://github.com/wcwq98/realm)：Realm 端口中转管理。原 `wcwq99/realm` 地址当前会重定向到这里。
- [nxtrace/NTrace-core](https://github.com/nxtrace/NTrace-core)：NextTrace 路由测试。
- [yonggekkk/warp-yg](https://github.com/yonggekkk/warp-yg)：WARP 安装和主管理逻辑。
- [jeessy2/ddns-go](https://github.com/jeessy2/ddns-go)：DDNS 核心和服务商 API。
- [tarampampam/3proxy-docker](https://github.com/tarampampam/3proxy-docker)：3proxy 容器镜像。
- [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3)：BBRv3 内核和网络优化。
- [lmc999/RegionRestrictionCheck](https://github.com/lmc999/RegionRestrictionCheck)：流媒体解锁检测。
- [lmc999/TikTokCheck](https://github.com/lmc999/TikTokCheck)：TikTok 地区检测。
- [SuperManito/LinuxMirrors](https://github.com/SuperManito/LinuxMirrors)：系统源和 Docker 安装/镜像源。
- [SideCloudGroup/AppleAutoPro-Backend](https://github.com/SideCloudGroup/AppleAutoPro-Backend)：AppleID v4 后端。
- [bin456789/reinstall](https://github.com/bin456789/reinstall)：VPS 系统重装。

第三方项目版权和许可证归各自作者所有。本仓库的包装不会改变其许可证、免责声明或运行风险。

## 本地检查

```bash
tests/run.sh
```

测试会执行全部 Shell 语法检查，以及公共校验、V2Node fixture、DDNS YAML、nftables 规则生成、下载/CA 环境修复、REALITY web443 入口、Realm IPv6 快速转发、Realm glibc 兼容修复、BBR + FQ 快捷开启、WARP 自动快捷项、WARP 一键卸载和危险命令静态测试；不会真实修改开发机的 SSH、防火墙、Swap、Docker、systemd 或执行重装。
