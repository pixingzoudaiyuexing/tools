# VPS Tools

个人长期使用的中文 VPS 运维工具箱。主入口保持轻量，功能按模块从 GitHub 当前 `main` 分支按需加载，不会在 VPS 上保存整套工具箱副本。

## 一键使用

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pixingzoudaiyuexing/tools/main/tools.sh)
```

系统级功能需要 root。普通 sudo 用户可先执行 `sudo -i`，再运行上面的命令。

在主菜单选择 `98. 安装 tools 快捷命令` 后，会创建：

```text
/usr/local/bin/tools
```

以后直接输入：

```bash
tools
```

快捷启动器每次联网加载 GitHub 最新版 `tools.sh`，不会保存工具箱副本。

## 功能



### 网络工具

- 公网 IPv4 / IPv6 检测，任一协议族失败不会中断另一个。
- TCP/UDP 监听和指定端口占用查询，使用 `ss`，可选安装 `lsof`。
- UDP / Hy2 端口跳跃：IPv4/IPv6 独立网卡、多规则、冲突检查、nftables 语法检查和 systemd 持久化。
- Realm 端口中转入口。
- NextTrace ICMP/TCP/UDP 路由测试和 MTR 丢包/延迟测试。
- WARP 环境检查、纯 IPv6 + WARP IPv4 验证、日志诊断、旧 wgcf 冲突检查和保守修复。
- DDNS-GO：Cloudflare、华为云、阿里云、DNSPod，A/AAAA 可分别启用，本地 `-noweb` 服务。
- 3proxy Docker：带认证的 HTTP / SOCKS5 代理安装、修改、启停、升级和卸载。
- BBRv3、流媒体解锁、TikTok 地区检测入口。
- 樱花 VPS Debian 12 预置 IPv6 精确启用和验证。

### 系统工具

- LinuxMirrors 系统换源。
- `/swapfile` 专属 Swap 查看、创建、修改和删除；不会执行 `swapoff -a`。
- 时区、时间同步状态、systemd-timesyncd / chrony 管理。
- Root SSH 密码登录：仅写入 `/etc/ssh/sshd_config.d/99-vps-tools-root.conf`，修改前后执行 `sshd -t`。
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

- 高风险操作均使用普通 `[y/N]` 确认，不要求输入特殊确认字符串。
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

测试会执行全部 Shell 语法检查，以及公共校验、V2Node fixture、DDNS YAML、nftables 规则生成和危险命令静态测试；不会真实修改开发机的 SSH、防火墙、Swap、Docker、systemd 或执行重装。
