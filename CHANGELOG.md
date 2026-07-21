# Changelog

---

## [Unreleased]

### Fixed
- **LilyEmby 方案非标端口修复**：当反代监听端口非 443（如 443 被占用改用 8443）时，`sub_filter` / `proxy_redirect` 的重写目标现在会带上端口后缀（`https://域名:端口/sN`）。此前重写目标丢失端口，指向默认 443，客户端在非标端口访问时拿到不可达地址，导致播放大流量绕过反代直连源推流域名（issue #6）。标准 443 端口行为不变。

---

## [2.1.0] - 2026-07-21

### Added
- **镜像源容灾**：Nginx 安装/升级时 `nginx.org` 不可达自动回退国内镜像（清华 TUNA / 中科大 USTC / 阿里云 / 腾讯云 / 华为云），GPG 密钥和软件包下载遍历镜像选取最快可用源
- **系统信息面板**：主菜单新增 `5) 系统信息`，一键展示操作系统、Nginx 状态、acme.sh 证书与邮箱、DNS API 配置（Key 脱敏显示）、系统 DNS 服务器

### Fixed
- 镜像探测路径修正：国内镜像仅镜像软件包目录，不托管 HTML 页面，版本检测回退为仅走 nginx.org，避免遍历镜像白等超时
- 修复 shellcheck SC2086 警告（`show_system_info` 中 acme.sh 路径未加引号）

### Changed
- 主菜单编号调整：新增 `5) 系统信息`，卸载顺延为 `6`，更新脚本顺延为 `7`

---

## [2.0.0] - 2026-07-02

### Added
- **Alpine Linux / OpenWrt 兼容**：BusyBox 适配（`grep`/`sed`/`awk`/`mktemp` 模板），包管理器自动检测（apt / yum / dnf / apk / opkg），Nginx 配置目录自动识别（`http.d` vs `conf.d`），Nginx 安装完成后重新检测 `CONF_DIR`
- **OpenRC 支持**：`rc-service` / `rc-update` 分支，Alpine/dcron periodic 自动续期回退
- **DNS-01 证书验证**：支持 Cloudflare / DNSPod / 阿里云 / HE.net / GoDaddy / 华为云 / AWS Route53 / Google Cloud
- **DNS API 配置管理菜单**：独立管理 DNS 服务商 Token
- **交互式证书验证方式选择**：HTTP-01 / DNS-01 二选一，适配 NAT / 无 80 端口场景；HTTP-01 挑战失败时自动提示切换 DNS-01
- **系统 DNS 设置菜单**：内置常见 DNS 供应商（Google / Cloudflare / 阿里 / 腾讯 / 自定义）
- **脚本自更新**：主菜单一键 `git pull` 拉取最新代码
- OpenSSL 依赖自动安装 + acme.sh 引导安装
- 安装时根据系统 locale 自动切换中英文提示（仅当当前 locale 为中文时才安装中文语言包）
- 版本号后附代码修改日期 `(YYYY-MM-DD)`

### Fixed
- 修复 `select_cert_mode_interactive` 中 `warn`/`error` 输出到 stdout 被 `$()` 捕获，导致选择 DNS-01 后误触发 HTTP-01 自检
- 未安装 Nginx 时 WebSocket map 检查不再报错
- WebSocket map 注入时 grep 转义修正；当 `conf.d` 位于 nginx.conf http 块之外时，直接向 nginx.conf 注入 map
- 证书模式菜单改用 ASCII 字符，避免 Alpine 编码异常
- BusyBox 兼容：`mktemp` 模板中的 `XXXXXX` 一律放在末尾

### Security
- DNS API 密钥文件写入前设置 `umask 077`，写入后 `chmod 600`，避免明文密钥被同机其他用户读取
- 系统 DNS 设置检测 `systemd-resolved` / `resolvconf` / `NetworkManager` 是否托管 `/etc/resolv.conf`，托管时二次确认后再覆盖；处理软链场景

### Changed
- 更新脚本菜单：优先使用当前脚本所在 Git 仓库目录，其次回退到 `/opt/Nginx-X`；安装目标从 `command -v nx` 推断，兼容非默认安装路径
