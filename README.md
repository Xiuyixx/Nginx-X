# Nginx-X

一个基于 Bash 的 Nginx 自动化管理交互脚本（Ubuntu / Debian / CentOS / Alpine / OpenWrt）。

## 项目目标

通过数字菜单统一管理 Nginx，重点保证稳定性：
- 所有配置修改后都会先执行 `nginx -t`
- 校验通过才会 `reload`
- 校验失败会自动回滚，避免把服务改挂

## 安装方式

### 方式一：一键安装（推荐）

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Xiuyixx/Nginx-X/main/install.sh)"
```

### 方式二：手动安装

```bash
git clone https://github.com/Xiuyixx/Nginx-X.git
cd Nginx-X
bash install.sh
```

安装说明：
- 一键安装首次会克隆到 `/opt/Nginx-X`
- 再次执行会自动拉取最新代码
- 如果 `/opt/Nginx-X` 已存在但不是 Git 仓库，安装器会先提示确认，再决定是否清空重装
- 若安装、拉取、依赖安装或软件源刷新失败，安装器会直接提示网络/软件源相关报错，不会静默中断
- **多语言支持**：安装过程中根据系统 locale 自动切换中英文提示

> **安装完成后可直接运行：`nx`**

## 当前功能

### 稳定性设计

- 所有配置变更都会先执行 `nginx -t`
- 校验失败自动回滚，避免把在线 Nginx 配挂
- 443 / HTTPS 端口复用场景会优先走更安全的落地流程
- 证书申请前会做 HTTP-01 自检，并区分"软失败可继续"和"硬失败建议先修复"
- 临时文件使用安全随机文件名，降低冲突和误覆盖风险

1. **安装升级Nginx**
   - 自动检查是否已安装 Nginx
   - 未安装时自动安装依赖：`curl` `wget` `socat` `cron`
   - 自动安装 Nginx 官方 stable 版本（默认使用 nginx.org 官方源，不可达时自动回退国内镜像：清华 TUNA / 中科大 USTC / 阿里云 / 腾讯云 / 华为云）
   - 安装后自动停用 `default.conf`（改名为 `default.conf.bak`）避免与自定义配置冲突
   - 自动创建证书目录：`/etc/nginx/ssl/`
   - 对比本地版本与 Nginx 官网最新版本（若 nginx.org 不可达，会回退为包管理器升级检查）
   - 有新版本时先备份 `/etc/nginx/`，再执行升级
   - 升级后自动校验并平滑重载

2. **配置管理**
   - 二级菜单包含：`内部反代` / `外部反代` / `配置列表` / `导入已有配置`
   - 内部反代：输入域名或本机IPv4、监听端口、后端端口，支持端口复用确认
   - 外部反代：输入域名或本机IPv4、监听端口、外部 `http/https` 上游 URL
   - 外部反代支持模式选择：
     - `标准模式`
     - `Stream 模式`
     - `Emby 分离 HTTP 推流`
     - `Emby 分离 HTTPS 推流`
     - `LilyEmby 方案（访问/推流分离，支持 sub_filter 响应体替换）`
   - Emby/Lily 模式支持配置主站上游、一个或多个推流节点 URL（多个用英文逗号分隔）、源站公开 URL、Referer URL
   - 同端口多域名场景自动适配：若目标端口已用于 HTTPS，会自动处理为可通过 `nginx -t` 的流程
   - 自动生成标准 Proxy Header，配置写入 `/etc/nginx/conf.d/域名-监听端口.conf`
   - 配置列表中的"修改"支持外部反代配置切换方案，并保留证书/HTTPS 联动逻辑
   - 修改配置后自动检测证书状态并提示启用 HTTPS（流程与内部反代一致）
   - 若修改配置时更换域名且发现没有证书，可直接在流程中申请证书并启用 HTTPS
   - 通过"内部反代"或"外部反代"创建配置后，会自动检测证书：
     - 若已有证书：仅需确认是否启用 HTTPS
     - 若无证书：可一键"自动申请证书 + 自动启用 HTTPS（80->443）"
   - 配置列表：统一管理上述两类配置，按状态浏览并进入三级菜单执行 启用 / 停用 / 修改 / 编辑 / 删除
   - 导入已有配置：自动扫描 `conf.d/`、`sites-enabled/`、`sites-available/` 三个目录，发现未纳管的 Nginx 配置后逐个确认导入
   - 导入时自动提取域名、端口、后端地址、HTTPS 状态等元数据，不修改原有 Nginx 指令
   - `sites-available` 的配置会复制到 `conf.d/`，并自动移除 `sites-enabled` 中对应的软链接（避免重复加载）
   - 导入成功后会询问是否删除原始配置文件（推荐删除，避免重复扫描）
   - 已导入到 `conf.d` 的配置不会被重复扫描（按域名+端口去重，含 `.bak` 等停用文件）
   - 首次安装 Nginx 后会自动检测并提示导入已有配置

### IPv6 支持说明

- **对外监听（客户端通过 IPv6 访问）**：脚本在生成配置时会进行最佳努力检测，若系统 IPv6 已启用，会额外写入：
  - `listen [::]:80;`
  - `listen [::]:443 ssl;`（或对应的 HTTPS 监听端口）
- **上游反代到 IPv6**：支持上游 URL 使用 IPv6（需要按 URL 规范使用方括号），例如：
  - `http://[2001:db8::1]:8080`
  - `https://[2400:3200::1]`

> 注意：若你的系统内核禁用了 IPv6（例如 `net.ipv6.conf.all.disable_ipv6=1`），脚本会自动跳过 IPv6 的 `listen` 行，避免 `nginx -t` 失败。

3. **证书管理**
   - 设置邮箱（持久化到 `${XDG_CONFIG_HOME:-$HOME/.config}/nginxx/email.conf`）
   - 自动安装 acme.sh 并申请证书
   - **双验证模式**：交互式选择 HTTP-01 或 DNS-01（适配 NAT / 无 80 端口场景）
   - DNS-01 支持 Cloudflare、DNSPod、阿里云、HE.net、GoDaddy、华为云、AWS Route53、Google Cloud
   - DNS API 配置管理菜单（独立管理 Token，持久化存储）
   - HTTP-01 申请前自动执行自检（DNS/80监听/challenge 路径/域名回源），失败时给出更明确提示并支持切换 DNS-01 或强制继续
   - 证书列表：按编号展示已有证书，并显示续期任务状态
   - 证书操作：支持按编号执行 重新申请 / 启停续期 / 删除证书
   - 启用证书时先从配置列表选择目标配置
   - 若配置已启用 HTTPS，再次选择该配置可按确认执行"停用 HTTPS"
   - 自动检查是否已有证书：有证书直接启用；无证书先申请再启用
   - 一键启用 HTTPS（自动继承原监听端口；80 自动跳转到对应 HTTPS 端口）

4. **实时信息**
   - 二级菜单包含：`实时信息` / `流量统计` / `健康检查`
   - 实时信息：展示连接状态、请求统计、QPS、系统资源、Nginx 信息、网络流量
   - 流量统计：展示系统总流量与当前启用配置的流量估算
   - 若存在 `/var/log/nginx/access.host.log`，会优先按 Host 专用日志做更精确统计
   - 若不存在 Host 专用日志，则回退为基于最近 5000 条 `access.log` 的估算
   - 健康检查支持 `检查所有站点` / `检查单个站点`
   - 健康检查内容包括：入口 URL、HTTP 状态码、DNS 解析结果、命中 IP
   - HTTPS 站点会额外显示证书剩余天数（可获取时）
   - 外部反代会额外显示主上游与推流上游（支持多个推流上游），便于排查
   - 每 5 秒自动刷新，按回车返回上一级

5. **系统信息**
   - 一键展示系统运行环境全貌：操作系统信息（发行版、内核、架构、运行时间、系统 DNS）
   - Nginx 状态：版本号、运行状态、已启用配置数量
   - acme.sh 状态：安装状态、注册邮箱、证书数量、自动续期是否启用
   - DNS API 状态：已配置服务商、API Key 脱敏显示

6. **卸载**
   - 选项1：卸载脚本（彻底卸载本脚本并清理）
   - 选项2：卸载 Nginx（彻底卸载并清空 Nginx 及配置）
   - 选项3：卸载 Acme（彻底卸载并清空 Acme 配置/邮箱信息）
   - 选项4：全部卸载（脚本 + Nginx + Acme 一并清理）
   - 高风险卸载操作会显示删除摘要并要求二次确认

7. **更新脚本**
   - 主菜单一键拉取最新代码并覆盖安装
   - 自动检测安装目录是否为 Git 仓库（对待非仓库目录先确认再重装）

## 系统兼容性

- 原生支持：Ubuntu / Debian / CentOS / Alpine / OpenWrt
- 包管理器自动检测（apt / yum / dnf / apk / opkg）
- BusyBox 兼容（`grep`/`sed`/`awk` 替代 GNU 版本差异）
- Nginx 安装后自动适配配置目录：Alpine 使用 `http.d`，其他系统使用 `conf.d`

## 已知限制

- HTTP-01 自检在 CDN、四层转发、NAT 回环等特殊网络环境下可能出现误判，可切换 DNS-01 方式规避
- 流量统计默认是轻量实现，若未配置 Host 专用日志则属于估算值，不适合作为精准计费依据

## 交互与失败处理说明

- 菜单类入口在缺少前置条件时，会提示原因并返回上一级，不会因为 `set -e` 直接退出整个脚本。
- 安装 / 升级链路里若遇到网络不通、GitHub 不可达、软件源异常、签名密钥下载失败等情况，会给出更明确的错误提示。
- 证书邮箱配置保存在用户配置目录，而不是脚本安装目录，避免因 `/usr/local/bin` 不可写导致保存失败。

## 建议的 Host 专用日志格式

如果你希望"流量统计"更准确，可在 Nginx 主配置里增加类似：

```nginx
log_format nginxx_host '$host $body_bytes_sent $remote_addr [$time_local] '
                      '"$request" $status $http_referer "$http_user_agent"';
access_log /var/log/nginx/access.host.log nginxx_host;
```

这样脚本会优先读取 `access.host.log`，按域名做更准确的请求数和下行统计。

## 开发校验

本仓库已包含 GitHub Actions 基础 CI：

- `bash -n nx.sh`
- `bash -n install.sh`
- `shellcheck -x nx.sh install.sh`
- `bash tests/https_config_regression.sh`

本地也可以直接运行：

```bash
bash -n nx.sh
bash -n install.sh
shellcheck -x nx.sh install.sh tests/https_config_regression.sh
bash tests/https_config_regression.sh
```

## 交互规范

- 主菜单使用数字编号
- `0` 表示退出或返回上一级
- 颜色反馈：
  - 绿色：成功
  - 黄色：警告
  - 红色：错误
