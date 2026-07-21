#!/usr/bin/env bash
set -euo pipefail

# ==============================
# Nginx-X: Nginx 自动化管理脚本
# 支持：Ubuntu / Debian / CentOS / Alpine / OpenWrt
# ==============================

# ---------- ANSI 颜色 ----------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------- 全局变量 ----------
APP_NAME="Nginx-X"
APP_VERSION="2.1.0 (2026-07-21)"
# Alpine 的 nginx 把 server 配置放在 http.d，其他系统用 conf.d
if [[ -f /etc/nginx/http.d ]] || [[ -d /etc/nginx/http.d ]]; then
  CONF_DIR="/etc/nginx/http.d"
else
  CONF_DIR="/etc/nginx/conf.d"
fi
SSL_DIR="/etc/nginx/ssl"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/nginxx"
EMAIL_CONF="${STATE_DIR}/email.conf"
DNS_CONF="${STATE_DIR}/dns.conf"
REPO_URL="https://github.com/Xiuyixx/Nginx-X.git"
REPO_BRANCH="main"
REPO_INSTALL_DIR="/opt/Nginx-X"

NGINX_MIRRORS=(
  "https://nginx.org"
  "https://mirrors.tuna.tsinghua.edu.cn/nginx"
  "https://mirrors.ustc.edu.cn/nginx"
  "https://mirrors.aliyun.com/nginx"
  "https://mirrors.cloud.tencent.com/nginx"
  "https://mirrors.huaweicloud.com/nginx"
)

SUDO=""
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  SUDO="sudo"
fi

# ---------- 输出函数 ----------
info() { echo -e "${GREEN}[成功]${NC} $*"; }
warn() { echo -e "${YELLOW}[警告]${NC} $*"; }
error() { echo -e "${RED}[错误]${NC} $*"; }
note() { echo -e "${BLUE}[信息]${NC} $*"; }

pause() {
  echo
  read -rp "按回车继续..." _
}

cleanup_tmp_file() {
  local f="${1:-}"
  [[ -n "$f" && -f "$f" ]] && rm -f "$f"
}

confirm() {
  local prompt="$1"
  read -rp "${prompt} [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

run_menu_action() {
  # In long-running interactive shells, bash may cache command paths.
  # After uninstalling packages (e.g. nginx), the cached path can point to a deleted binary.
  # Refresh hash table before each menu action so check_cmd / execution are accurate.
  hash -r 2>/dev/null || true
  "$@" || true
}

# ---------- 基础能力 ----------
check_cmd() {
  # Avoid false positives from bash's command hash cache (set -u friendly).
  local p
  p="$(command -v "$1" 2>/dev/null || true)"
  [[ -n "$p" && -x "$p" ]]
}

require_nginx_installed() {
  if ! check_cmd nginx; then
    error "未检测到 Nginx。请先到主菜单执行 [1) 安装升级Nginx]。"
    return 1
  fi
}

run_safe() {
  # 统一命令执行入口，便于后续扩展日志
  "$@"
}

run_editor() {
  local target="$1"
  local editor_cmd
  local -a editor_args

  if [[ -n "${EDITOR:-}" ]]; then
    editor_cmd="$EDITOR"
  elif check_cmd nano; then
    editor_cmd="nano"
  else
    editor_cmd="vi"
  fi

  read -r -a editor_args <<< "$editor_cmd"
  [[ ${#editor_args[@]} -gt 0 ]] || return 1

  if [[ -n "$SUDO" ]]; then
    ${SUDO} "${editor_args[@]}" "$target"
  else
    "${editor_args[@]}" "$target"
  fi
}

nginx_test() {
  # 所有配置变更后必须调用 nginx -t
  require_nginx_installed || return 1
  ${SUDO} nginx -t >/dev/null 2>&1
}

reload_nginx_safe() {
  # reload 前必须先测试配置
  if ! nginx_test; then
    error "配置校验失败，已拦截 reload。"
    ${SUDO} nginx -t || true
    return 1
  fi

  if check_cmd systemctl; then
    if ${SUDO} systemctl is-active --quiet nginx; then
      ${SUDO} systemctl reload nginx
      info "Nginx 已重载。"
    else
      ${SUDO} systemctl start nginx
      info "检测到 Nginx 未运行，已自动启动。"
    fi
  elif check_cmd rc-service; then
    if ${SUDO} rc-service nginx status 2>/dev/null; then
      ${SUDO} rc-service nginx reload 2>/dev/null || ${SUDO} rc-service nginx restart
      info "Nginx 已重载。"
    else
      ${SUDO} rc-service nginx start
      info "检测到 Nginx 未运行，已自动启动。"
    fi
  else
    if ${SUDO} service nginx status >/dev/null 2>&1; then
      ${SUDO} service nginx reload
      info "Nginx 已重载。"
    else
      ${SUDO} service nginx start
      info "检测到 Nginx 未运行，已自动启动。"
    fi
  fi
}

ensure_dirs() {
  ${SUDO} mkdir -p "$CONF_DIR"
  ${SUDO} mkdir -p "$SSL_DIR"
}

# 写入 WebSocket upgrade map，避免对普通 HTTP 请求发送固定 Connection: upgrade
ensure_websocket_map() {
  local map_conf="${CONF_DIR}/00-websocket-map.conf"

  # Skip if nginx is not installed yet (no nginx.conf)
  if [[ ! -f /etc/nginx/nginx.conf ]]; then
    return 0
  fi

  # Skip if nginx.conf already defines the map (e.g. Alpine default config)
  # shellcheck disable=SC2016  # $http_upgrade is literal nginx variable syntax, matched as-is
  if grep -qF 'map $http_upgrade' /etc/nginx/nginx.conf 2>/dev/null; then
    return 0
  fi

  # Detect if CONF_DIR is included inside the http block or at root level.
  # The "map" directive is only valid in http context.
  # If conf.d is included at root level (before http{}), we must inject
  # the map into nginx.conf directly or use http.d instead.
  local need_inject=0
  if ! awk '
    BEGIN { in_http = 0 }
    /^[[:space:]]*http[[:space:]]*\{/ { in_http = 1 }
    in_http && /include/ && /(conf\.d|http\.d)/ { found = 1; exit }
    in_http && /^\}/ { in_http = 0 }
    END { exit found ? 0 : 1 }
  ' /etc/nginx/nginx.conf 2>/dev/null; then
    need_inject=1
  fi

  if [[ "$need_inject" -eq 1 ]]; then
    # CONF_DIR is included at root level → inject map into nginx.conf http block
    local tmp_nginx
    tmp_nginx="$(mktemp /tmp/nginxx-map-XXXXXX)"
    trap 'rm -f "${tmp_nginx:-}"' RETURN
    awk '
      /^[[:space:]]*http[[:space:]]*\{/ {
        print $0
        print ""
        print "    # managed_by=Nginx-X"
        print "    map $http_upgrade $connection_upgrade {"
        print "        default upgrade;"
        print "        \"\"      close;"
        print "    }"
        print ""
        next
      }
      { print }
    ' /etc/nginx/nginx.conf > "$tmp_nginx"

    ${SUDO} cp -a /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak."$(date +%s)" 2>/dev/null || true
    ${SUDO} cp -a "$tmp_nginx" /etc/nginx/nginx.conf
    rm -f "$tmp_nginx"
    info "已将 WebSocket map 注入 nginx.conf http 块。"
    return 0
  fi

  # Standard: CONF_DIR is inside http block, map file is safe
  if [[ ! -f "$map_conf" ]]; then
    ${SUDO} tee "$map_conf" > /dev/null <<'EOF'
# managed_by=Nginx-X
# WebSocket upgrade map — included by all proxy configs via conf.d
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
    info "已写入 WebSocket map：${map_conf}"
  fi
}

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
}

disable_default_conf_if_exists() {
  local default_conf="${CONF_DIR}/default.conf"
  local disabled_conf="${CONF_DIR}/default.conf.bak"

  if [[ -f "$default_conf" ]]; then
    ${SUDO} mv "$default_conf" "$disabled_conf"
    info "已自动停用默认配置：${default_conf} -> ${disabled_conf}"
  fi
}

detect_os_id() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${ID:-unknown}"
  else
    echo "unknown"
  fi
}

detect_pkg_mgr() {
  if check_cmd apt-get; then
    echo "apt"
  elif check_cmd dnf; then
    echo "dnf"
  elif check_cmd yum; then
    echo "yum"
  elif check_cmd apk; then
    echo "apk"
  elif check_cmd opkg; then
    echo "opkg"
  else
    echo "unknown"
  fi
}

setup_chinese_locale() {
  local pkg
  pkg="$(detect_pkg_mgr)"

  note "正在设置中文 locale 支持..."

  case "$pkg" in
    apt)
      if ! ${SUDO} apt-get install -y locales; then
        warn "locales 包安装失败，跳过中文 locale 设置。"
        return 0
      fi
      if ${SUDO} locale-gen zh_CN.UTF-8 2>/dev/null; then
        ${SUDO} update-locale LANG=zh_CN.UTF-8 2>/dev/null || true
        info "中文 locale (zh_CN.UTF-8) 设置完成。"
      else
        warn "zh_CN.UTF-8 locale 生成失败。"
      fi
      ;;
    dnf|yum)
      if ${SUDO} "$pkg" install -y glibc-langpack-zh 2>/dev/null; then
        info "中文语言包安装完成。"
      elif ${SUDO} "$pkg" install -y glibc-common 2>/dev/null; then
        info "中文语言包安装完成。"
      else
        warn "中文语言包安装失败。"
        return 0
      fi
      if ${SUDO} localectl set-locale LANG=zh_CN.UTF-8 2>/dev/null; then
        info "中文 locale (zh_CN.UTF-8) 设置完成。"
      else
        warn "locale 设置失败，请手动设置。"
      fi
      ;;
    apk)
      if ${SUDO} apk add musl-locales 2>/dev/null; then
        info "musl-locales 安装完成。"
        if [[ ! -f /etc/profile.d/locale.sh ]]; then
          echo 'export LANG=zh_CN.UTF-8' | ${SUDO} tee /etc/profile.d/locale.sh >/dev/null
          ${SUDO} chmod +x /etc/profile.d/locale.sh
        fi
        if ! grep -q "LANG=zh_CN.UTF-8" /etc/environment 2>/dev/null; then
          echo 'LANG=zh_CN.UTF-8' | ${SUDO} tee -a /etc/environment >/dev/null
        fi
        export LANG=zh_CN.UTF-8
        LC_ALL=zh_CN.UTF-8
        info "中文 locale (zh_CN.UTF-8) 设置完成。"
      else
        warn "musl-locales 安装失败，跳过中文 locale 设置。"
      fi
      ;;
    opkg)
      note "OpenWrt 环境，尝试安装中文语言包..."
      ${SUDO} opkg install luci-i18n-base-zh-cn 2>/dev/null || warn "OpenWrt 中文语言包安装失败或已安装，可忽略。"
      ;;
    *)
      warn "未知包管理器，跳过中文 locale 设置。"
      ;;
  esac
}

nginx_local_version() {
  if ! check_cmd nginx; then
    echo ""
    return
  fi
  nginx -v 2>&1 | sed -E 's#^nginx version: nginx/##' || echo ""
}

probe_nginx_mirror() {
  local path="${1:-/keys/nginx_signing.key}"
  local mirror
  for mirror in "${NGINX_MIRRORS[@]}"; do
    note "尝试连接镜像: ${mirror}"
    if curl -fsSL --connect-timeout 3 --max-time 6 -A 'Nginx-X mirror-probe' -o /dev/null "${mirror}${path}" 2>/dev/null; then
      echo "$mirror"
      return 0
    fi
  done
  return 1
}

nginx_latest_version_online() {
  local latest page
  page="$(curl -fsSL --connect-timeout 4 --max-time 8 \
    -A 'Nginx-X version-check' \
    https://nginx.org/en/download.html 2>/dev/null || true)"
  if [[ -z "$page" ]]; then
    page="$(curl -fsSL --connect-timeout 4 --max-time 8 \
      -A 'Nginx-X version-check' \
      http://nginx.org/en/download.html 2>/dev/null || true)"
  fi

  latest="$(printf '%s' "$page" | awk '
    /Stable version/ {in_stable=1; next}
    in_stable && /Mainline version/ {in_stable=0}
    in_stable {
      while (match($0, /nginx-[0-9]+\.[0-9]+\.[0-9]+/)) {
        print substr($0, RSTART + 6, RLENGTH - 6)
        $0 = substr($0, RSTART + RLENGTH)
      }
    }
  ' | sort -V | tail -n1 || true)"

  echo "$latest"
}

curl_error_hint() {
  # Translate common curl failures into short hints for end users.
  # Input: curl exit code
  local rc="${1:-0}"
  case "$rc" in
    6)  echo "DNS 解析失败（无法解析域名）" ;;
    7)  echo "连接失败（可能被防火墙阻断或端口不可达）" ;;
    28) echo "连接超时（网络不通或链路较慢）" ;;
    35) echo "TLS 握手失败（证书链/协议问题）" ;;
    52) echo "服务器无响应（连接被中断）" ;;
    56) echo "网络接收失败（连接被重置）" ;;
    *)  echo "未知错误（curl rc=${rc}）" ;;
  esac
}

pkg_upgrade_error_hint() {
  # Provide short, actionable hints for common package manager failures.
  # Input: package manager name + output text
  local pkg="${1:-}"
  local out="${2:-}"

  case "$pkg" in
    apt)
      if echo "$out" | grep -qiE 'Could not resolve|Temporary failure in name resolution'; then
        echo "APT 网络/DNS 异常：请检查 DNS、网络连通性或是否被墙。"
      elif echo "$out" | grep -qiE 'Could not get lock|Unable to acquire the dpkg frontend lock|dpkg was interrupted'; then
        echo "APT 被锁或中断：可能有其它 apt/dpkg 进程在运行，或需要先执行 dpkg --configure -a。"
      elif echo "$out" | grep -qiE 'Held broken packages|held packages'; then
        echo "存在被 hold 的包：可尝试 apt-mark showhold 查看并处理，或手动解决依赖冲突。"
      elif echo "$out" | grep -qiE 'Release file|The repository .* does not have a Release file'; then
        echo "APT 源异常：可能源地址不对、系统版本不匹配或镜像不可用。"
      else
        echo "APT 升级失败：请检查上方输出（网络/源/依赖）。"
      fi
      ;;
    yum|dnf)
      if echo "$out" | grep -qiE 'Could not resolve host|Name or service not known'; then
        echo "YUM/DNF 网络/DNS 异常：请检查 DNS、网络连通性。"
      elif echo "$out" | grep -qiE 'repomd\.xml|Cannot download repodata|Failed to download metadata'; then
        echo "YUM/DNF 元数据下载失败：可能仓库不可达或被拦截，稍后重试或更换源。"
      elif echo "$out" | grep -qiE 'GPG key retrieval failed|Public key for|NOKEY|gpgcheck'; then
        echo "YUM/DNF GPG 校验失败：请检查仓库 GPG key 是否可下载、系统时间是否正确。"
      else
        echo "YUM/DNF 升级失败：请检查上方输出（网络/源/GPG）。"
      fi
      ;;
    apk)
      if echo "$out" | grep -qiE 'temporary error|network error|unreachable|resolve'; then
        echo "APK 网络/DNS 异常：请检查 DNS、网络连通性或更换镜像源。"
      elif echo "$out" | grep -qiE 'unsatisfiable constraints'; then
        echo "APK 依赖冲突：可能包版本不兼容，请尝试 apk update 后重试。"
      else
        echo "APK 升级失败：请检查上方输出（网络/源/依赖）。"
      fi
      ;;
    opkg)
      if echo "$out" | grep -qiE 'wget returned|download failed|signature check failed'; then
        echo "OPKG 下载或签名失败：请检查网络、软件源或系统时间。"
      else
        echo "OPKG 升级失败：请检查上方输出（网络/源）。"
      fi
      ;;
    *)
      echo "升级失败：请检查上方输出。"
      ;;
  esac
}

escape_ere() {
  printf '%s' "$1" | sed -e 's/[][\\.^$*+?(){}|/]/\\&/g'
}

version_gt() {
  # 若 $1 > $2 返回 0
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" && "$1" != "$2" ]]
}

# ---------- 功能1：安装与初始化 ----------
install_nginx_official() {
  local os_id pkg
  os_id="$(detect_os_id)"
  pkg="$(detect_pkg_mgr)"

  ensure_dirs

  if check_cmd nginx; then
    warn "检测到 Nginx 已安装，跳过安装步骤。"
    info "已确保目录存在：${SSL_DIR}"
    return 0
  fi

  # 仅在用户当前 locale 已为中文时才自动安装中文语言包；
  # 避免在英文环境下强制引入不必要的依赖。
  local _cur_locale="${LC_ALL:-${LANG:-}}"
  if [[ "$_cur_locale" =~ ^zh([._-]|$) ]]; then
    setup_chinese_locale
  fi

  note "开始安装依赖：curl wget socat cron"

  case "$pkg" in
    apt)
      if ! ${SUDO} apt-get update; then
        error "依赖索引刷新失败。请检查网络连接、APT 源状态或稍后重试。"
        return 1
      fi
      if ! ${SUDO} apt-get install -y curl wget socat cron gpg lsb-release ca-certificates; then
        error "依赖安装失败。请检查网络连接、APT 源状态或稍后重试。"
        return 1
      fi

      note "配置 Nginx 官方 stable 源..."
      local gpg_mirror repo_mirror gpg_ok
      gpg_ok=0
      for gpg_mirror in "${NGINX_MIRRORS[@]}"; do
        note "尝试从 ${gpg_mirror} 下载签名密钥..."
        if curl -fsSL --connect-timeout 6 --max-time 12 "${gpg_mirror}/keys/nginx_signing.key" | ${SUDO} gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg 2>/dev/null; then
          gpg_ok=1
          break
        fi
      done
      if [[ "$gpg_ok" != "1" ]]; then
        error "下载或导入 Nginx 官方签名密钥失败。请检查网络连接后重试。"
        return 1
      fi

      repo_mirror="$(probe_nginx_mirror "/packages/$(. /etc/os-release; echo "${ID}")" || echo "https://nginx.org")"
      note "使用镜像源: ${repo_mirror}"
      # shellcheck disable=SC1091
      echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] ${repo_mirror}/packages/$(. /etc/os-release; echo "${ID}") $(lsb_release -cs) nginx" | ${SUDO} tee /etc/apt/sources.list.d/nginx.list >/dev/null
      if ! ${SUDO} apt-get update; then
        error "Nginx 官方源刷新失败。请检查网络连接、软件源配置或稍后重试。"
        return 1
      fi
      if ! ${SUDO} apt-get install -y nginx; then
        error "Nginx 安装失败。请检查网络连接、软件源状态或稍后重试。"
        return 1
      fi
      ;;
    dnf|yum)
      if [[ "$os_id" != "centos" && "$os_id" != "rhel" && "$os_id" != "rocky" && "$os_id" != "almalinux" ]]; then
        warn "当前系统 ID=$os_id，仍尝试按 RHEL 系列方式安装。"
      fi
      ${SUDO} "$pkg" install -y epel-release || true
      if ! ${SUDO} "$pkg" install -y curl wget socat cronie; then
        error "依赖安装失败。请检查网络连接、YUM/DNF 源状态或稍后重试。"
        return 1
      fi

      note "配置 Nginx 官方 stable 源..."
      local yum_mirror
      yum_mirror="$(probe_nginx_mirror "/packages/centos" || echo "https://nginx.org")"
      note "使用镜像源: ${yum_mirror}"
      cat <<REPO | ${SUDO} tee /etc/yum.repos.d/nginx.repo >/dev/null
[nginx-stable]
name=nginx stable repo
baseurl=${yum_mirror}/packages/centos/\$releasever/\$basearch/
gpgcheck=1
enabled=1
gpgkey=${yum_mirror}/keys/nginx_signing.key
module_hotfixes=true
REPO
      ${SUDO} "$pkg" makecache -y || true
      if ! ${SUDO} "$pkg" install -y nginx; then
        error "Nginx 安装失败。请检查网络连接、软件源状态或稍后重试。"
        return 1
      fi
      ;;
    apk)
      if ! ${SUDO} apk add curl wget socat dcron openssl; then
        error "依赖安装失败。请检查网络连接、APK 源状态或稍后重试。"
        return 1
      fi

      note "安装 Nginx..."
      ${SUDO} apk add nginx nginx-mod-stream || {
        error "Nginx 安装失败。请检查网络连接、APK 源状态或稍后重试。"
        return 1
      }
      ;;
    opkg)
      if ! ${SUDO} opkg update; then
        error "OPKG 索引刷新失败。请检查网络连接、软件源状态或稍后重试。"
        return 1
      fi
      if ! ${SUDO} opkg install curl wget socat cron nginx openssl-util; then
        error "依赖和 Nginx 安装失败。请检查网络连接、软件源状态或稍后重试。"
        return 1
      fi
      ;;
    *)
      error "不支持的包管理器，无法自动安装。"
      return 1
      ;;
  esac

  if check_cmd systemctl; then
    ${SUDO} systemctl enable --now nginx || true
    ${SUDO} systemctl enable --now cron 2>/dev/null || ${SUDO} systemctl enable --now crond 2>/dev/null || true
  elif check_cmd rc-service; then
    ${SUDO} rc-update add nginx default 2>/dev/null || true
    ${SUDO} rc-service nginx start 2>/dev/null || true
    ${SUDO} rc-update add dcron default 2>/dev/null || ${SUDO} rc-update add crond default 2>/dev/null || true
    ${SUDO} rc-service dcron start 2>/dev/null || ${SUDO} rc-service crond start 2>/dev/null || true
  fi

  # 安装后自动停用可能引发冲突的默认配置
  disable_default_conf_if_exists

  # 安装后重新检测 conf 目录（Alpine 装完才有 http.d）
  if [[ -d /etc/nginx/http.d ]]; then
    CONF_DIR="/etc/nginx/http.d"
    ensure_dirs
  fi

  reload_nginx_safe || true

  # 自动安装 acme.sh
  note "安装 acme.sh 证书工具..."
  ensure_acme_installed || warn "acme.sh 安装失败，可稍后在证书管理中手动安装。"

  info "Nginx 与依赖安装完成。"
  info "已创建证书目录：${SSL_DIR}"
}

# ---------- 功能2：智能版本升级 ----------
upgrade_nginx_smart() {
  if ! check_cmd nginx; then
    warn "Nginx 尚未安装，请先执行安装。"
    return 1
  fi

  local local_ver latest_ver backup_dir pkg
  local_ver="$(nginx_local_version)"

  # 仅在检测到 nginx 官方源时，才按官网版本做对比，避免 Debian/Ubuntu 默认源误判
  local using_official_repo="0"
  if grep -rqsF 'nginx.org\|mirrors\.\|/nginx/packages' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    using_official_repo="1"
  elif [[ -f /etc/yum.repos.d/nginx.repo ]] || grep -rqsF 'nginx.org\|mirrors\.' /etc/yum.repos.d/ 2>/dev/null; then
    using_official_repo="1"
  fi

  if [[ "$using_official_repo" == "1" ]]; then
    latest_ver="$(nginx_latest_version_online)"
  else
    latest_ver=""
  fi

  note "本地版本：${local_ver}"
  if [[ "$using_official_repo" == "1" ]]; then
    if [[ -z "$latest_ver" ]]; then
      # Try a quick curl probe to classify failure (best-effort)
      local probe_rc=0
      curl -fsSL --connect-timeout 4 --max-time 8 -A 'Nginx-X version-check' https://nginx.org/en/download.html >/dev/null 2>&1 || probe_rc=$?
      if [[ "$probe_rc" -ne 0 ]]; then
        curl -fsSL --connect-timeout 4 --max-time 8 -A 'Nginx-X version-check' http://nginx.org/en/download.html >/dev/null 2>&1 || probe_rc=$?
      fi
      warn "无法获取官方最新版本（nginx.org 访问失败：$(curl_error_hint "$probe_rc")），将改为直接通过包管理器检查并尝试升级。"
      using_official_repo="0"
    else
      note "官方最新：${latest_ver}"

      if ! version_gt "$latest_ver" "$local_ver"; then
        info "当前已是最新版本，无需升级。"
        return 0
      fi
    fi
  fi
  if [[ "$using_official_repo" != "1" ]]; then
    warn "当前未检测到或无法使用 nginx 官方源（nginx.org），将按系统仓库执行升级检查。"
    note "将执行包管理器升级检查（无新版本不会升级）。"
  fi

  backup_dir="/etc/nginx-backup-$(date +%F-%H%M%S)"
  note "检测到可升级版本，先备份配置到：${backup_dir}"
  ${SUDO} cp -a /etc/nginx "$backup_dir"

  pkg="$(detect_pkg_mgr)"
  case "$pkg" in
    apt)
      note "将执行：apt-get install -y --only-upgrade nginx"
      ;;
    dnf|yum)
      note "将执行：${pkg} update -y nginx"
      ;;
    apk)
      note "将执行：apk upgrade nginx"
      ;;
    opkg)
      note "将执行：opkg upgrade nginx"
      ;;
  esac
  case "$pkg" in
    apt)
      local apt_out=""
      if ! ${SUDO} apt-get update; then
        error "APT 索引刷新失败。"
        return 1
      fi
      apt_out="$(${SUDO} apt-get install -y --only-upgrade nginx 2>&1)" || {
        error "APT 升级失败。"
        warn "$(pkg_upgrade_error_hint apt "$apt_out")"
        echo "$apt_out"
        return 1
      }
      ;;
    dnf|yum)
      local pm_out=""
      pm_out="$(${SUDO} "$pkg" update -y nginx 2>&1)" || {
        error "${pkg} 升级失败。"
        warn "$(pkg_upgrade_error_hint "$pkg" "$pm_out")"
        echo "$pm_out"
        return 1
      }
      ;;
    apk)
      local apk_out=""
      if ! ${SUDO} apk update; then
        error "APK 索引刷新失败。"
        return 1
      fi
      apk_out="$(${SUDO} apk upgrade nginx 2>&1)" || {
        error "APK 升级失败。"
        warn "$(pkg_upgrade_error_hint apk "$apk_out")"
        echo "$apk_out"
        return 1
      }
      ;;
    opkg)
      local opkg_out=""
      if ! ${SUDO} opkg update; then
        error "OPKG 索引刷新失败。"
        return 1
      fi
      opkg_out="$(${SUDO} opkg upgrade nginx 2>&1)" || {
        error "OPKG 升级失败。"
        warn "$(pkg_upgrade_error_hint opkg "$opkg_out")"
        echo "$opkg_out"
        return 1
      }
      ;;
    *)
      error "不支持的包管理器，无法自动升级。"
      return 1
      ;;
  esac

  if nginx_test; then
    reload_nginx_safe
    info "Nginx 已平滑升级完成。"
  else
    error "升级后配置校验失败，请检查。备份目录：${backup_dir}"
    ${SUDO} nginx -t || true
    return 1
  fi
}

# ---------- 功能1：安装升级Nginx（合并入口） ----------
install_or_upgrade_nginx() {
  # 未安装时先安装；已安装时走智能升级逻辑
  if ! check_cmd nginx; then
    install_nginx_official
    auto_import_after_install
  else
    upgrade_nginx_smart
  fi
}

# ---------- 反向代理配置通用 ----------
valid_domain() {
  local d="$1"
  # NOTE: local IFS is scoped to this function and restored on return
  local IFS=.
  local -a labels
  local label

  [[ "$d" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  [[ "$d" == *.* ]] || return 1
  [[ "$d" != .* && "$d" != *. && "$d" != *..* ]] || return 1

  read -r -a labels <<< "$d"
  [[ ${#labels[@]} -ge 2 ]] || return 1

  for label in "${labels[@]}"; do
    [[ -n "$label" ]] || return 1
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
  done

  [[ "${labels[-1]}" =~ ^[A-Za-z]{2,63}$ ]]
}

valid_ipv4_host() {
  local ip="$1"
  # NOTE: local IFS is scoped to this function and restored on return
  local IFS=.
  local -a octets

  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  read -r -a octets <<< "$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1

  local octet
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}

valid_server_name_input() {
  local v="$1"
  valid_domain "$v" || valid_ipv4_host "$v"
}

valid_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

valid_url() {
  # 验证 URL 格式并拒绝可能注入 nginx 配置的危险字符
  local url="$1"
  [[ "$url" =~ ^https?:// ]] || return 1
  [[ ${#url} -gt 2048 ]] && return 1
  [[ "$url" =~ [[:space:]] ]] && return 1
  [[ "$url" == *$'\n'* || "$url" == *$'\r'* ]] && return 1
  [[ "$url" == *'{'* ]] && return 1
  [[ "$url" == *'}'* ]] && return 1
  [[ "$url" == *\\* ]] && return 1
  [[ "$url" == *';'* ]] && return 1
  [[ "$url" == *"'"* ]] && return 1
  [[ "$url" == *'`'* ]] && return 1
  return 0
}

is_port_used_os() {
  local p="$1"
  ss -lnt "( sport = :${p} )" 2>/dev/null | awk 'NR>1{print}' | grep -q .
}

port_has_ssl_listener() {
  local p="$1"
  grep -R -E "listen[[:space:]]+${p}([[:space:]]|;).*ssl" "${CONF_DIR}"/*.conf >/dev/null 2>&1
}

conf_target_path() {
  local domain="$1"
  local listen_port="$2"
  echo "${CONF_DIR}/${domain}-${listen_port}.conf"
}

conf_meta_get() {
  local conf_file="$1"
  local key="$2"
  grep -E "^# ${key}=" "$conf_file" 2>/dev/null | head -n1 | sed "s/^# ${key}=//" || true
}

mark_conf_manual_edited() {
  local conf_file="$1"
  local tmp

  grep -q '^# edited=true$' "$conf_file" 2>/dev/null && return 0

  tmp="$(mktemp /tmp/nginxx-edited-XXXXXX)"
  {
    echo "# edited=true"
    cat "$conf_file"
  } > "$tmp"
  ${SUDO} cp -a "$tmp" "$conf_file"
  rm -f "$tmp"
}

conf_server_block_count() {
  local conf_file="$1"
  grep -cE '^[[:space:]]*server[[:space:]]*\{' "$conf_file" 2>/dev/null || true
}

conf_has_custom_locations() {
  local conf_file="$1"

  # Nginx-X template rebuilds are only safe for locations it can regenerate.
  # Treat any extra custom location as user-authored logic and avoid silently
  # deleting it during modify/HTTPS toggle operations.
  awk '
    /^[[:space:]]*location[[:space:]]+/ {
      line=$0
      if (line ~ /^[[:space:]]*location[[:space:]]+\/[[:space:]]*\{/) next
      if (line ~ /^[[:space:]]*location[[:space:]]+\^~[[:space:]]+\/\.well-known\/acme-challenge\/[[:space:]]*\{/) next
      if (line ~ /^[[:space:]]*location[[:space:]]+\/s[0-9]+\/[[:space:]]*\{/) next
      bad=1
    }
    END { exit bad ? 0 : 1 }
  ' "$conf_file" 2>/dev/null
}

conf_safe_for_template_rebuild() {
  local conf_file="$1"
  local servers

  [[ "$(conf_meta_get "$conf_file" imported)" == "true" ]] && return 1
  [[ "$(conf_meta_get "$conf_file" edited)" == "true" ]] && return 1

  servers="$(conf_server_block_count "$conf_file")"
  [[ -z "$servers" ]] && servers=0
  (( servers <= 2 )) || return 1

  if conf_has_custom_locations "$conf_file"; then
    return 1
  fi

  return 0
}

require_template_rebuild_safe() {
  local conf_file="$1"
  local action_name="$2"

  if conf_safe_for_template_rebuild "$conf_file"; then
    return 0
  fi

  warn "已阻止${action_name}：该配置可能是导入/手工编辑/复杂配置。"
  warn "此操作会按模板重建整份配置，可能删除自定义 location、header、rewrite、鉴权等规则。"
  warn "请使用 '编辑' 手动调整，或先拆分/整理为 Nginx-X 原生生成的单站点配置。"
  return 1
}

cert_referenced_confs() {
  local domain="$1"
  grep -R -l -F "${SSL_DIR}/${domain}/" \
    "${CONF_DIR}"/*.conf "${CONF_DIR}"/*.conf.* 2>/dev/null || true
}

url_host() {
  local url="$1"

  # Extract host part from URL, including IPv6-in-brackets.
  # Examples:
  #   http://example.com:8080/path   -> example.com
  #   https://1.2.3.4/path           -> 1.2.3.4
  #   http://[2001:db8::1]:8080/     -> 2001:db8::1
  url="${url#*://}"
  url="${url%%/*}" # authority

  if [[ "$url" == \[*\]* ]]; then
    # If no port, authority may look like: [2001:db8::1]
    # If with port: [2001:db8::1]:8080
    url="${url#[}"
    url="${url%%]*}"
    echo "$url"
    return 0
  fi

  url="${url%%:*}"
  echo "$url"
}

ipv6_available() {
  # Best-effort detection: kernel IPv6 enabled and has at least one interface entry.
  [[ -f /proc/net/if_inet6 ]] || return 1
  [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" == "0" ]] || return 1
  return 0
}

nginx_listen_ipv6_line() {
  # Print an additional IPv6 listen line for a given port, if IPv6 is available.
  # Usage: nginx_listen_ipv6_line 80 ""  -> "    listen [::]:80;"
  #        nginx_listen_ipv6_line 443 "ssl http2" -> "    listen [::]:443 ssl http2;"
  local p="$1"
  local flags="${2:-}"

  if ipv6_available; then
    if [[ -n "$flags" ]]; then
      echo "    listen [::]:${p} ${flags};"
    else
      echo "    listen [::]:${p};"
    fi
  fi
}

url_scheme() {
  local url="$1"
  echo "$url" | sed -E 's#^([a-zA-Z][a-zA-Z0-9+.-]*)://.*#\1#'
}

default_referer_from_url() {
  local base="$1"
  base="${base%/}"
  echo "${base}/web/index.html"
}

trim_spaces() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  echo "$v"
}

normalize_url_list() {
  local raw="$1"
  local -a parts
  local part out=""

  IFS=',' read -r -a parts <<< "$raw"
  for part in "${parts[@]}"; do
    part="$(trim_spaces "$part")"
    [[ -z "$part" ]] && continue
    if ! valid_url "$part"; then
      return 1
    fi
    out+="${out:+|}${part}"
  done

  [[ -n "$out" ]] || return 1
  echo "$out"
}

stream_urls_to_array() {
  local raw="$1"
  local -n _out="$2"

  _out=()
  [[ -z "$raw" ]] && return 0
  IFS='|' read -r -a _out <<< "$raw"
}

external_mode_name() {
  case "$1" in
    normal) echo "标准模式" ;;
    media) echo "Stream 模式" ;;
    emby_http) echo "Emby 分离 HTTP 推流" ;;
    emby_https) echo "Emby 分离 HTTPS 推流" ;;
    emby_lily) echo "LilyEmby 方案（访问/推流分离）" ;;
    *) echo "$1" ;;
  esac
}

select_external_mode() {
  local current="${1:-normal}"
  local choice=""

  echo "请选择外部反代模式：" >&2
  echo "1) 标准模式" >&2
  echo "2) Stream 模式" >&2
  echo "3) Emby 分离 HTTP 推流" >&2
  echo "4) Emby 分离 HTTPS 推流" >&2
  echo "5) LilyEmby 方案（访问/推流分离）" >&2

  case "$current" in
    normal) choice="1" ;;
    media) choice="2" ;;
    emby_http) choice="3" ;;
    emby_https) choice="4" ;;
    emby_lily) choice="5" ;;
    *) choice="1" ;;
  esac

  read -rp "选择模式 [1-5] (默认 ${choice}): " input_mode
  [[ -n "$input_mode" ]] && choice="$input_mode"

  case "$choice" in
    2) echo "media" ;;
    3) echo "emby_http" ;;
    4) echo "emby_https" ;;
    5) echo "emby_lily" ;;
    *) echo "normal" ;;
  esac
}

ensure_cert_for_domain_interactive() {
  local domain="$1"
  local cert_mode="${2:-}"

  if valid_ipv4_host "$domain"; then
    warn "当前使用的是 IP，证书自动申请通常不适用。"
    return 1
  fi

  if [[ -f "${SSL_DIR}/${domain}/fullchain.pem" && -f "${SSL_DIR}/${domain}/privkey.pem" ]]; then
    return 0
  fi

  warn "检测到域名 ${domain} 尚无证书。"
  if ! ensure_email_interactive; then
    error "邮箱未设置，无法自动申请证书。"
    return 1
  fi

  if [[ -z "$cert_mode" ]]; then
    cert_mode="$(select_cert_mode_interactive)"
  fi

  if ! issue_cert_for_domain "$domain" "$cert_mode"; then
    error "证书申请失败。"
    return 1
  fi

  return 0
}

build_proxy_conf() {
  local domain="$1"
  local listen_port="$2"
  local backend_port="$3"
  local out="$4"

  ensure_websocket_map

  local ipv6_listen
  ipv6_listen="$(nginx_listen_ipv6_line "$listen_port" "")"

  cat > "$out" <<EOF
# managed_by=Nginx-X
# domain=${domain}
# listen_port=${listen_port}
# backend_port=${backend_port}

server {
    listen ${listen_port};
${ipv6_listen}
    server_name ${domain};

    # ACME HTTP-01 验证路径（证书申请/续期）
    location ^~ /.well-known/acme-challenge/ {
        root /usr/share/nginx/html;
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        proxy_pass http://127.0.0.1:${backend_port};
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF
}

build_external_proxy_conf() {
  local domain="$1"
  local listen_port="$2"
  local upstream_url="$3"
  local external_mode="$4"
  local out="$5"
  local https_enabled="${6:-0}"
  local stream_upstream_url="${7:-}"
  local source_site_url="${8:-}"
  local referer_url="${9:-}"

  ensure_websocket_map
  local stream_upstream_urls="${10:-}"
  local main_stream_block=""
  local stream_location_block=""
  local lily_block=""
  local redirect_block=""
  local main_host_block=""
  local main_header_block=""
  local stream_sni_block=""
  local redirect_suffix=""
  local upstream_host https_meta https_cert_block
  local -a stream_urls=()
  local idx stream_url stream_path stream_host_line stream_redirect_block=""
  local stream_lily_block="" base_lily_block=""

  upstream_host="$(url_host "$upstream_url")"

  if [[ -n "$stream_upstream_urls" ]]; then
    stream_urls=()
    stream_urls_to_array "$stream_upstream_urls" stream_urls
  elif [[ -n "$stream_upstream_url" ]]; then
    stream_urls=("$stream_upstream_url")
  fi

  if [[ ${#stream_urls[@]} -gt 0 ]]; then
    stream_upstream_url="${stream_urls[0]}"
    stream_upstream_urls="$(IFS='|'; echo "${stream_urls[*]}")"
  fi

  [[ -z "$source_site_url" ]] && source_site_url="$upstream_url"
  [[ -z "$referer_url" && -n "$source_site_url" ]] && referer_url="$(default_referer_from_url "$source_site_url")"

  https_meta=""
  https_cert_block=""
  if [[ "$https_enabled" == "1" ]]; then
    https_meta="# https_enabled=true"
    https_cert_block=$(cat <<EOF
    ssl_certificate     ${SSL_DIR}/${domain}/fullchain.pem;
    ssl_certificate_key ${SSL_DIR}/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
EOF
)
  fi

  case "$external_mode" in
    media)
      main_stream_block=$(cat <<'BLOCK'
        # Stream 转发优化（Emby/Jellyfin 等）
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_max_temp_file_size 0;
        send_timeout 3600s;
        client_max_body_size 0;
BLOCK
)
      ;;
    emby_http|emby_https|emby_lily)
      if [[ ${#stream_urls[@]} -eq 0 ]]; then
        stream_urls=("$stream_upstream_url")
      fi

      for idx in "${!stream_urls[@]}"; do
        stream_url="${stream_urls[$idx]}"
        stream_path="/s$((idx + 1))/"
        stream_host_line="$(url_host "$stream_url")"
        stream_redirect_block+="        proxy_redirect ${stream_url} https://${domain}${stream_path};"$'\n'

        if [[ "$external_mode" == "emby_lily" ]]; then
          stream_lily_block+="        sub_filter '${stream_url}' 'https://${domain}${stream_path%/}';"$'\n'
        fi

        stream_sni_block=""
        if [[ "$external_mode" != "emby_http" ]]; then
          stream_sni_block=$(cat <<EOF
        proxy_ssl_server_name on;
        proxy_ssl_name ${stream_host_line};
EOF
)
        fi

        stream_location_block+=$'\n'
        stream_location_block+="    location ${stream_path} {"$'\n'
        stream_location_block+="        rewrite ^${stream_path%/}(/.*)\$ \$1 break;"$'\n'
        stream_location_block+="        proxy_pass ${stream_url};"$'\n'
        stream_location_block+="        proxy_http_version 1.1;"$'\n'
        if [[ -n "$stream_sni_block" ]]; then
          stream_location_block+="${stream_sni_block}"$'\n'
        fi
        stream_location_block+="        proxy_set_header Range \$http_range;"$'\n'
        stream_location_block+="        proxy_set_header If-Range \$http_if_range;"$'\n'
        stream_location_block+="        proxy_set_header Referer \"${referer_url}\";"$'\n'
        stream_location_block+="        proxy_set_header Host \$proxy_host;"$'\n'
        stream_location_block+=$'\n'
        stream_location_block+="        proxy_buffering off;"$'\n'
        stream_location_block+="        proxy_connect_timeout 60s;"$'\n'
        stream_location_block+="        proxy_read_timeout 300s;"$'\n'
        stream_location_block+="        proxy_send_timeout 300s;"$'\n'
        stream_location_block+=$'\n'
        stream_location_block+="        proxy_set_header X-Real-IP \"\";"$'\n'
        stream_location_block+="        proxy_set_header X-Forwarded-For \"\";"$'\n'
        stream_location_block+="        proxy_set_header X-Forwarded-Proto \"\";"$'\n'
        stream_location_block+="        proxy_set_header X-Forwarded-Host \"\";"$'\n'
        stream_location_block+="        proxy_set_header Forwarded \"\";"$'\n'
        stream_location_block+="        proxy_set_header Via \"\";"$'\n'
        stream_location_block+=$'\n'
        stream_location_block+="        proxy_hide_header X-Powered-By;"$'\n'
        stream_location_block+="        proxy_hide_header X-Frame-Options;"$'\n'
        stream_location_block+="        proxy_hide_header X-Content-Type-Options;"$'\n'
        stream_location_block+="    }"$'\n'
      done

      redirect_block="${stream_redirect_block%$'\n'}"
      if [[ "$external_mode" == "emby_lily" ]]; then
        redirect_block+=$'\n'
        redirect_block+="        proxy_redirect ${source_site_url} https://${domain};"
        base_lily_block=$(cat <<EOF
        proxy_set_header Accept-Encoding "";
        sub_filter_types application/json text/xml text/plain;
        sub_filter_once off;
        sub_filter '${source_site_url}' 'https://${domain}';
EOF
)
        lily_block="${base_lily_block}"$'\n'"${stream_lily_block}"
      else
        lily_block="${stream_lily_block}"
      fi

      ;;
  esac

  if [[ "$external_mode" =~ ^emby_ ]]; then
    main_host_block=$(cat <<EOF
        proxy_set_header Host ${upstream_host};
        proxy_ssl_name ${upstream_host};
EOF
)
    main_header_block=$(cat <<EOF
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
${redirect_block}
${lily_block}
        proxy_set_header X-Real-IP "";
        proxy_set_header X-Forwarded-For "";
        proxy_set_header X-Forwarded-Proto "";
        proxy_set_header X-Forwarded-Host "";
        proxy_set_header X-Forwarded-Port "";
        proxy_set_header Forwarded "";
        proxy_set_header Via "";

        proxy_hide_header X-Powered-By;
        proxy_hide_header X-Frame-Options;
        proxy_hide_header X-Content-Type-Options;
EOF
)
  else
    # shellcheck disable=SC2016
    main_host_block='        proxy_set_header Host $proxy_host;'
    main_header_block=$(cat <<'EOF'
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;
EOF
)
    if [[ -n "$main_stream_block" ]]; then
      main_header_block="${main_stream_block}

${main_header_block}"
    fi
  fi

  if [[ "$listen_port" == "443" ]]; then
    redirect_suffix=""
  else
    redirect_suffix=":${listen_port}"
  fi

  if [[ "$https_enabled" == "1" ]]; then
    local ipv6_listen_80 ipv6_listen_tls
    ipv6_listen_80="$(nginx_listen_ipv6_line 80 "")"
    ipv6_listen_tls="$(nginx_listen_ipv6_line "$listen_port" "ssl http2")"

    cat > "$out" <<EOF
# managed_by=Nginx-X
# mode=external
# external_mode=${external_mode}
# domain=${domain}
# listen_port=${listen_port}
${https_meta}
# upstream_url=${upstream_url}
# stream_upstream_url=${stream_upstream_url}
# stream_upstream_urls=${stream_upstream_urls}
# source_site_url=${source_site_url}
# referer_url=${referer_url}

server {
    listen 80;
${ipv6_listen_80}
    server_name ${domain};

    location ^~ /.well-known/acme-challenge/ {
        root /usr/share/nginx/html;
        default_type "text/plain";
        try_files \$uri =404;
    }

    return 301 https://\$host${redirect_suffix}\$request_uri;
}

server {
    listen ${listen_port} ssl http2;
${ipv6_listen_tls}
    server_name ${domain};

${https_cert_block}

    location / {
        proxy_pass ${upstream_url};
        proxy_http_version 1.1;
${main_host_block}
        proxy_ssl_server_name on;

${main_header_block}
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
${stream_location_block}
}
EOF
  else
    local ipv6_listen_plain
    ipv6_listen_plain="$(nginx_listen_ipv6_line "$listen_port" "")"

    cat > "$out" <<EOF
# managed_by=Nginx-X
# mode=external
# external_mode=${external_mode}
# domain=${domain}
# listen_port=${listen_port}
# upstream_url=${upstream_url}
# stream_upstream_url=${stream_upstream_url}
# stream_upstream_urls=${stream_upstream_urls}
# source_site_url=${source_site_url}
# referer_url=${referer_url}

server {
    listen ${listen_port};
${ipv6_listen_plain}
    server_name ${domain};

    location ^~ /.well-known/acme-challenge/ {
        root /usr/share/nginx/html;
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        proxy_pass ${upstream_url};
        proxy_http_version 1.1;
${main_host_block}
        proxy_ssl_server_name on;

${main_header_block}
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
${stream_location_block}
}
EOF
  fi
}

# 若配置包含 ssl 监听，则必须同时包含证书指令，避免生成半截 HTTPS 配置
ensure_ssl_directives_present() {
  local conf_file="$1"

  if grep -qE 'listen[[:space:]]+[^;]*[[:space:]]ssl([[:space:]]|;)' "$conf_file" 2>/dev/null; then
    if ! grep -qE '^[[:space:]]*ssl_certificate[[:space:]]+' "$conf_file" 2>/dev/null; then
      error "检测到 HTTPS 监听，但缺少 ssl_certificate：${conf_file}"
      return 1
    fi
    if ! grep -qE '^[[:space:]]*ssl_certificate_key[[:space:]]+' "$conf_file" 2>/dev/null; then
      error "检测到 HTTPS 监听，但缺少 ssl_certificate_key：${conf_file}"
      return 1
    fi
  fi
}

apply_conf_with_rollback() {
  # 参数：临时文件、目标文件
  local tmp_conf="$1"
  local target_conf="$2"
  local backup
  local test_output=""

  backup="${target_conf}.rollback.$(date +%s)"

  if [[ -f "$target_conf" ]]; then
    ${SUDO} cp -a "$target_conf" "$backup"
  fi

  ${SUDO} cp -a "$tmp_conf" "$target_conf"

  if ! ensure_ssl_directives_present "$target_conf"; then
    if [[ -f "$backup" ]]; then
      ${SUDO} cp -a "$backup" "$target_conf"
      ${SUDO} rm -f "$backup"
    else
      ${SUDO} rm -f "$target_conf"
    fi
    return 1
  fi

  if test_output="$(${SUDO} nginx -t 2>&1)"; then
    reload_nginx_safe
    [[ -f "$backup" ]] && ${SUDO} rm -f "$backup"
    return 0
  fi

  # 回滚
  if [[ -f "$backup" ]]; then
    ${SUDO} cp -a "$backup" "$target_conf"
    ${SUDO} rm -f "$backup"
  else
    ${SUDO} rm -f "$target_conf"
  fi
  error "配置测试失败，已自动撤销本次修改。请根据上面的 nginx -t 输出检查具体报错。"
  echo "$test_output"
  return 1
}

add_reverse_proxy() {
  local domain listen_port backend_port target tmp
  local desired_port create_port force_enable_https="0"

  require_nginx_installed || return 1

  read -rp "请输入域名或本机IP（如 example.com / 192.168.1.10）: " domain
  if ! valid_server_name_input "$domain"; then
    error "输入格式不合法。请输入可解析域名，或 IPv4 地址（例如 192.168.1.10）。"
    return 1
  fi

  read -rp "请输入监听端口（如 80/8080）: " listen_port
  if ! valid_port "$listen_port"; then
    error "监听端口不合法。请输入 1-65535 之间的数字。"
    return 1
  fi

  read -rp "请输入后端/容器端口（如 3000）: " backend_port
  if ! valid_port "$backend_port"; then
    error "后端端口不合法。请输入 1-65535 之间的数字。"
    return 1
  fi

  desired_port="$listen_port"
  create_port="$listen_port"

  if is_port_used_os "$listen_port"; then
    warn "监听端口 ${listen_port} 当前已被占用（Nginx 多站点场景通常可复用）。"
    if ! confirm "是否继续写入配置并交由 nginx -t 校验？"; then
      info "已取消内部反代配置。"
      return 0
    fi

    # 443 端口复用时，若当前域名还没有证书，直接写入 listen 443 往往会与现有 ssl 配置冲突。
    # 这里先引导落到 80，后续通过“自动申请证书+启用HTTPS”切到 443。
    if [[ "$listen_port" == "443" ]] && [[ ! -f "${SSL_DIR}/${domain}/fullchain.pem" || ! -f "${SSL_DIR}/${domain}/privkey.pem" ]]; then
      warn "检测到 443 端口复用且当前域名证书不存在，已自动改为先使用 80 端口创建配置。"
      warn "后续可在同流程自动申请证书并启用 HTTPS。"
      create_port="80"
    fi

    # 非 443 的复用端口，如果当前端口已用于 HTTPS 监听，也要避免直接写入纯 HTTP 配置
    if port_has_ssl_listener "$desired_port"; then
      if [[ -f "${SSL_DIR}/${domain}/fullchain.pem" && -f "${SSL_DIR}/${domain}/privkey.pem" ]]; then
        warn "检测到端口 ${desired_port} 已用于 HTTPS，且当前域名已有证书。"
        warn "将先写入临时 HTTP 配置，再自动切换为 ${desired_port} HTTPS。"
        create_port="80"
        force_enable_https="1"
      else
        warn "检测到端口 ${desired_port} 已用于 HTTPS，但当前域名暂无证书。"
        warn "已自动改为先使用 80 端口创建配置，后续申请证书后再切换 HTTPS。"
        create_port="80"
      fi
    fi
  fi

  target="$(conf_target_path "$domain" "$desired_port")"
  tmp="$(mktemp /tmp/nginxx-"${domain}"-XXXXXX)"
  trap 'rm -f "${tmp:-}"' RETURN

  build_proxy_conf "$domain" "$create_port" "$backend_port" "$tmp"
  if apply_conf_with_rollback "$tmp" "$target"; then
    info "反向代理配置已生效：${target}"

    if [[ "$force_enable_https" == "1" ]]; then
      if enable_https_for_conf_file "$domain" "$target" "$desired_port"; then
        info "已完成：同端口 HTTPS 复用配置已自动启用。"
      else
        warn "自动切换 HTTPS 失败。请检查证书文件是否存在，以及 nginx 配置是否通过校验。"
      fi
      rm -f "$tmp"
      return 0
    fi

    if valid_ipv4_host "$domain"; then
      warn "当前使用的是 IP，证书自动申请通常不适用，已跳过证书流程。"
      rm -f "$tmp"
      return 0
    fi

    if [[ -f "${SSL_DIR}/${domain}/fullchain.pem" && -f "${SSL_DIR}/${domain}/privkey.pem" ]]; then
      if confirm "检测到已有证书，是否立即启用证书（HTTPS 强制跳转）？"; then
        if enable_https_for_conf_file "$domain" "$target" "$desired_port"; then
          info "已完成：反向代理 + HTTPS 启用。"
        else
          warn "启用 HTTPS 失败。请检查证书、监听端口占用情况，以及 nginx -t 输出后重试。"
        fi
      fi
    else
      if confirm "是否立即自动申请证书并启用 HTTPS？"; then
        # 在当前界面直接设置/保存邮箱（若未设置）
        if ! ensure_email_interactive; then
          warn "邮箱未设置成功，已跳过自动证书流程。你可稍后在证书管理里设置。"
        else
          local selected_cert_mode
          selected_cert_mode="$(select_cert_mode_interactive)"
          if issue_cert_for_domain "$domain" "$selected_cert_mode"; then
            if enable_https_for_conf_file "$domain" "$target" "$desired_port"; then
              info "已完成：反向代理 + 证书 + HTTPS 启用。"
            else
              warn "证书已申请成功，但启用 HTTPS 失败。请重点检查监听端口占用和 nginx -t 输出。"
            fi
          else
            warn "证书申请失败。请检查域名解析、端口放行或 DNS API 配置。"
          fi
        fi
      fi
    fi
  fi
  rm -f "$tmp"
}

add_external_url_proxy() {
  local domain listen_port upstream_url target tmp external_mode
  local stream_upstream_url="" stream_upstream_urls="" source_site_url="" referer_url=""
  local desired_port create_port force_enable_https="0"

  require_nginx_installed || return 1

  read -rp "请输入域名或本机IP（如 example.com / 192.168.1.10）: " domain
  if ! valid_server_name_input "$domain"; then
    error "输入格式不合法。请输入可解析域名，或 IPv4 地址（例如 192.168.1.10）。"
    return 1
  fi

  read -rp "请输入监听端口（如 80/8080）: " listen_port
  if ! valid_port "$listen_port"; then
    error "监听端口不合法。请输入 1-65535 之间的数字。"
    return 1
  fi

  desired_port="$listen_port"
  create_port="$listen_port"

  read -rp "请输入外部上游 URL（http/https）: " upstream_url
  if ! valid_url "$upstream_url"; then
    error "上游 URL 格式不合法。必须以 http:// 或 https:// 开头，且不含特殊字符（{}\\;）。"
    return 1
  fi

  external_mode="$(select_external_mode normal)"

  if [[ "$external_mode" =~ ^emby_ ]]; then
    read -rp "请输入推流节点 URL（多个可用英文逗号分隔）: " stream_upstream_url
    if ! stream_upstream_urls="$(normalize_url_list "$stream_upstream_url")"; then
      error "推流节点 URL 格式不合法。必须以 http:// 或 https:// 开头，且不含特殊字符。"
      return 1
    fi
    local -a _stream_urls
    IFS='|' read -r -a _stream_urls <<< "$stream_upstream_urls"
    stream_upstream_url="${_stream_urls[0]}"

    read -rp "请输入源站公开 URL（用于重定向/替换，默认与主上游相同）: " source_site_url
    [[ -z "$source_site_url" ]] && source_site_url="$upstream_url"
    if ! valid_url "$source_site_url"; then
      error "源站公开 URL 格式不合法。必须以 http:// 或 https:// 开头，且不含特殊字符。"
      return 1
    fi

    read -rp "请输入 Referer URL（默认 ${source_site_url%/}/web/index.html）: " referer_url
    [[ -z "$referer_url" ]] && referer_url="$(default_referer_from_url "$source_site_url")"
  fi

  if is_port_used_os "$listen_port"; then
    warn "监听端口 ${listen_port} 当前已被占用（Nginx 多站点场景通常可复用）。"
    if ! confirm "是否继续写入配置并交由 nginx -t 校验？"; then
      info "已取消外部反代配置。"
      return 0
    fi

    if [[ "$listen_port" == "443" ]] && [[ ! -f "${SSL_DIR}/${domain}/fullchain.pem" || ! -f "${SSL_DIR}/${domain}/privkey.pem" ]]; then
      warn "检测到 443 端口复用且当前域名证书不存在，已自动改为先使用 80 端口创建配置。"
      warn "后续可在同流程自动申请证书并启用 HTTPS。"
      create_port="80"
    fi

    if port_has_ssl_listener "$desired_port"; then
      if [[ -f "${SSL_DIR}/${domain}/fullchain.pem" && -f "${SSL_DIR}/${domain}/privkey.pem" ]]; then
        warn "检测到端口 ${desired_port} 已用于 HTTPS，且当前域名已有证书。"
        warn "将先写入临时 HTTP 配置，再自动切换为 ${desired_port} HTTPS。"
        create_port="80"
        force_enable_https="1"
      else
        warn "检测到端口 ${desired_port} 已用于 HTTPS，但当前域名暂无证书。"
        warn "已自动改为先使用 80 端口创建配置，后续申请证书后再切换 HTTPS。"
        create_port="80"
      fi
    fi
  fi

  target="$(conf_target_path "$domain" "$desired_port")"
  tmp="$(mktemp /tmp/nginxx-external-"${domain}"-XXXXXX)"
  trap 'rm -f "${tmp:-}"' RETURN

  build_external_proxy_conf "$domain" "$create_port" "$upstream_url" "$external_mode" "$tmp" "0" "$stream_upstream_url" "$source_site_url" "$referer_url" "$stream_upstream_urls"
  if apply_conf_with_rollback "$tmp" "$target"; then
    info "外部反代配置已生效：${target}"

    if [[ "$force_enable_https" == "1" ]]; then
      if enable_https_for_conf_file "$domain" "$target" "$desired_port"; then
        info "已完成：同端口 HTTPS 复用配置已自动启用。"
      else
        warn "自动切换 HTTPS 失败。请检查证书文件是否存在，以及 nginx 配置是否通过校验。"
      fi
      rm -f "$tmp"
      return 0
    fi

    if valid_ipv4_host "$domain"; then
      warn "当前使用的是 IP，证书自动申请通常不适用，已跳过证书流程。"
      rm -f "$tmp"
      return 0
    fi

    if [[ -f "${SSL_DIR}/${domain}/fullchain.pem" && -f "${SSL_DIR}/${domain}/privkey.pem" ]]; then
      if confirm "检测到已有证书，是否立即启用证书（HTTPS 强制跳转）？"; then
        if enable_https_for_conf_file "$domain" "$target" "$desired_port"; then
          info "已完成：外部反代 + HTTPS 启用。"
        else
          warn "启用 HTTPS 失败。请检查证书、监听端口占用情况，以及 nginx -t 输出后重试。"
        fi
      fi
    else
      if confirm "是否立即自动申请证书并启用 HTTPS？"; then
        if ! ensure_email_interactive; then
          warn "邮箱未设置成功，已跳过自动证书流程。你可稍后在证书管理里设置。"
        else
          local selected_cert_mode
          selected_cert_mode="$(select_cert_mode_interactive)"
          if issue_cert_for_domain "$domain" "$selected_cert_mode"; then
            if enable_https_for_conf_file "$domain" "$target" "$desired_port"; then
              info "已完成：外部反代 + 证书 + HTTPS 启用。"
            else
              warn "证书已申请成功，但启用 HTTPS 失败。请重点检查监听端口占用和 nginx -t 输出。"
            fi
          else
            warn "证书申请失败。请检查域名解析、端口放行或 DNS API 配置。"
          fi
        fi
      fi
    fi
  fi

  rm -f "$tmp"
}

# ---------- 功能4：配置列表管理 ----------
list_managed_conf_files() {
  local include_disabled="${1:-0}"

  if [[ "$include_disabled" == "1" ]]; then
    find "$CONF_DIR" -maxdepth 1 -type f \( -name '*.conf' -o -name '*.conf.*' \) \
      ! -name 'nginx_status.conf*' \
      ! -name '00-websocket-map.conf*' \
      ! -name 'acme-challenge-*.conf*' \
      -exec grep -l '^# managed_by=Nginx-X$' {} + 2>/dev/null | sort || true
  else
    find "$CONF_DIR" -maxdepth 1 -type f -name '*.conf' \
      ! -name 'nginx_status.conf*' \
      ! -name '00-websocket-map.conf*' \
      ! -name 'acme-challenge-*.conf*' \
      -exec grep -l '^# managed_by=Nginx-X$' {} + 2>/dev/null | sort || true
  fi
}

list_all_conf_files() {
  list_managed_conf_files 1 | xargs -r -n1 basename
}

print_conf_list() {
  local i=1
  local -a enabled_files disabled_files

  # 二级列表：先显示已启用（.conf），再显示已停用（.bak/其他后缀）
  mapfile -t enabled_files < <(list_managed_conf_files 0 | xargs -r -n1 basename)
  mapfile -t disabled_files < <(list_managed_conf_files 1 | xargs -r -n1 basename | grep -E '\.conf\..+$' || true)

  FILES=("${enabled_files[@]}" "${disabled_files[@]}")

  if [[ ${#FILES[@]} -eq 0 ]]; then
    warn "当前没有可管理的配置文件。你可以先去 [内部反代] 或 [外部反代] 创建一个站点。"
    return 1
  fi

  echo "可管理配置列表："
  for f in "${FILES[@]}"; do
    if [[ "$f" =~ \.conf$ ]]; then
      echo "  ${i}) ${f}  [已启用]"
    else
      echo "  ${i}) ${f}  [已停用]"
    fi
    ((i++))
  done
  return 0
}

enable_conf() {
  local file src dst
  file="${1:-}"
  if [[ -z "$file" ]]; then
    error "未指定配置文件。"
    return 1
  fi
  src="${CONF_DIR}/${file}"

  if [[ "$file" =~ \.conf$ ]]; then
    warn "该配置已是启用状态。"
    return 0
  fi

  dst="${src%%.bak}"
  ${SUDO} mv "$src" "$dst"

  if nginx_test; then
    reload_nginx_safe
    info "已启用：$(basename "$dst")"
  else
    ${SUDO} mv "$dst" "$src"
    error "启用后配置校验失败，已回滚。"
    ${SUDO} nginx -t || true
    return 1
  fi
}

disable_conf() {
  local file src dst
  file="${1:-}"
  if [[ -z "$file" ]]; then
    error "未指定配置文件。"
    return 1
  fi
  src="${CONF_DIR}/${file}"

  if [[ ! "$file" =~ \.conf$ ]]; then
    warn "该配置已是停用状态。"
    return 0
  fi

  dst="${src}.bak"
  ${SUDO} mv "$src" "$dst"

  if nginx_test; then
    reload_nginx_safe
    info "已停用：$(basename "$dst")"
  else
    ${SUDO} mv "$dst" "$src"
    error "停用后配置校验失败，已回滚。"
    ${SUDO} nginx -t || true
    return 1
  fi
}

modify_conf() {
  local file src mode
  file="${1:-}"
  if [[ -z "$file" ]]; then
    error "未指定配置文件。"
    return 1
  fi
  src="${CONF_DIR}/${file}"

  require_template_rebuild_safe "$src" "修改配置" || return 1

  mode="$(conf_meta_get "$src" mode)"
  if [[ "$mode" == "external" ]]; then
    modify_external_conf "$file"
    return $?
  fi

  local current_domain current_listen current_backend
  local new_domain new_listen new_backend tmp new_target

  current_domain="$(extract_domain_from_conf "$src")"
  current_listen="$(conf_meta_get "$src" listen_port)"
  current_backend="$(conf_meta_get "$src" backend_port)"
  [[ -z "$current_listen" ]] && current_listen="80"
  # 元数据缺失时从实际 proxy_pass 提取后端端口
  if [[ -z "$current_backend" ]]; then
    current_backend="$(grep -oP 'proxy_pass\s+https?://127\.0\.0\.1:\K[0-9]+' "$src" 2>/dev/null | head -1)"
  fi
  if [[ -z "$current_backend" ]]; then
    current_backend="$(grep -oP 'proxy_pass\s+https?://localhost:\K[0-9]+' "$src" 2>/dev/null | head -1)"
  fi
  [[ -z "$current_backend" ]] && current_backend="3000"

  read -rp "新的域名（当前 ${current_domain}）: " new_domain
  [[ -z "$new_domain" ]] && new_domain="$current_domain"
  if ! valid_server_name_input "$new_domain"; then
    error "域名/IP 格式不合法。请输入可解析域名，或 IPv4 地址（例如 192.168.1.10）。"
    return 1
  fi

  read -rp "新的监听端口（当前 ${current_listen}）: " new_listen
  [[ -z "$new_listen" ]] && new_listen="$current_listen"
  if ! valid_port "$new_listen"; then
    error "监听端口不合法。请输入 1-65535 之间的数字。"
    return 1
  fi

  read -rp "新的后端端口（当前 ${current_backend}）: " new_backend
  [[ -z "$new_backend" ]] && new_backend="$current_backend"
  if ! valid_port "$new_backend"; then
    error "后端端口不合法。请输入 1-65535 之间的数字。"
    return 1
  fi

  # 监听端口占用检查（允许当前 nginx 使用旧配置的场景较复杂，这里采取严格策略）
  if is_port_used_os "$new_listen"; then
    warn "监听端口 ${new_listen} 当前被占用，可能导致冲突。"
    if ! confirm "仍继续尝试修改？"; then
      info "已取消修改。"
      return 0
    fi
  fi

  tmp="$(mktemp /tmp/nginxx-mod-"${new_domain}"-XXXXXX)"
  trap 'rm -f "${tmp:-}"' RETURN
  build_proxy_conf "$new_domain" "$new_listen" "$new_backend" "$tmp"

  # 修改后默认写入 .conf；也可选择立即停用
  new_target="$(conf_target_path "$new_domain" "$new_listen")"
  if apply_conf_with_rollback "$tmp" "$new_target"; then
    # 若原文件名和新文件名不同，且原文件仍存在则清理
    if [[ "$src" != "$new_target" && -f "$src" ]]; then
      ${SUDO} rm -f "$src"
    fi

    info "配置已修改并生效。"

    if ! confirm "是否立即启用该配置？"; then
      ${SUDO} mv "$new_target" "${new_target}.bak"
      if nginx_test; then
        reload_nginx_safe
        info "配置已保存并停用，可稍后在配置列表中启用。"
      else
        ${SUDO} mv "${new_target}.bak" "$new_target"
        error "停用失败，已恢复启用状态。"
        ${SUDO} nginx -t || true
      fi
      rm -f "$tmp"
      return 0
    fi

    # 统一 HTTPS 启用流程（与 add_reverse_proxy 一致）
    if valid_ipv4_host "$new_domain"; then
      warn "当前使用的是 IP，证书自动申请通常不适用，已跳过证书流程。"
    elif [[ -f "${SSL_DIR}/${new_domain}/fullchain.pem" && -f "${SSL_DIR}/${new_domain}/privkey.pem" ]]; then
      if confirm "检测到已有证书，是否立即启用 HTTPS（强制跳转）？"; then
        if enable_https_for_conf_file "$new_domain" "$new_target" "$new_listen"; then
          info "已完成：配置修改 + HTTPS 启用。"
        else
          warn "启用 HTTPS 失败。请检查证书、监听端口占用情况，以及 nginx -t 输出后重试。"
        fi
      fi
    else
      if confirm "是否立即自动申请证书并启用 HTTPS？"; then
        if ! ensure_email_interactive; then
          warn "邮箱未设置成功，已跳过自动证书流程。"
        else
          local selected_cert_mode
          selected_cert_mode="$(select_cert_mode_interactive)"
          if issue_cert_for_domain "$new_domain" "$selected_cert_mode"; then
            if enable_https_for_conf_file "$new_domain" "$new_target" "$new_listen"; then
              info "已完成：配置修改 + 证书 + HTTPS 启用。"
            else
              warn "证书已申请成功，但启用 HTTPS 失败。请检查监听端口占用和 nginx -t 输出。"
            fi
          else
            warn "证书申请失败。请检查域名解析、端口放行或 DNS API 配置。"
          fi
        fi
      fi
    fi
  fi

  rm -f "$tmp"
}

modify_external_conf() {
  local file src current_domain current_listen current_upstream_url current_mode
  local current_stream_upstream_url current_stream_upstream_urls current_source_site_url current_referer_url
  local new_domain new_listen new_upstream_url new_mode new_stream_upstream_url new_stream_upstream_urls new_source_site_url new_referer_url
  local tmp new_target desired_port create_port force_enable_https="0"
  local was_https_enabled=0 was_disabled=0 domain_changed=0

  file="${1:-}"
  src="${CONF_DIR}/${file}"
  [[ -f "$src" ]] || {
    error "配置文件不存在：${src}"
    return 1
  }

  require_template_rebuild_safe "$src" "修改外部反代配置" || return 1

  current_domain="$(extract_domain_from_conf "$src")"
  current_listen="$(conf_meta_get "$src" listen_port)"
  current_upstream_url="$(conf_meta_get "$src" upstream_url)"
  current_mode="$(conf_meta_get "$src" external_mode)"
  current_stream_upstream_url="$(conf_meta_get "$src" stream_upstream_url)"
  current_stream_upstream_urls="$(conf_meta_get "$src" stream_upstream_urls)"
  current_source_site_url="$(conf_meta_get "$src" source_site_url)"
  current_referer_url="$(conf_meta_get "$src" referer_url)"

  [[ -z "$current_mode" ]] && current_mode="normal"
  [[ -z "$current_listen" ]] && current_listen="80"
  [[ -z "$current_source_site_url" ]] && current_source_site_url="$current_upstream_url"
  [[ -z "$current_referer_url" && -n "$current_source_site_url" ]] && current_referer_url="$(default_referer_from_url "$current_source_site_url")"

  conf_https_enabled "$src" && was_https_enabled=1
  [[ ! "$file" =~ \.conf$ ]] && was_disabled=1

  read -rp "新的域名（当前 ${current_domain}）: " new_domain
  [[ -z "$new_domain" ]] && new_domain="$current_domain"
  if ! valid_server_name_input "$new_domain"; then
    error "域名/IP 格式不合法。请输入可解析域名，或 IPv4 地址（例如 192.168.1.10）。"
    return 1
  fi

  read -rp "新的监听端口（当前 ${current_listen}）: " new_listen
  [[ -z "$new_listen" ]] && new_listen="$current_listen"
  if ! valid_port "$new_listen"; then
    error "监听端口不合法。请输入 1-65535 之间的数字。"
    return 1
  fi

  read -rp "新的主上游 URL（当前 ${current_upstream_url}）: " new_upstream_url
  [[ -z "$new_upstream_url" ]] && new_upstream_url="$current_upstream_url"
  if ! valid_url "$new_upstream_url"; then
    error "主上游 URL 格式不合法。必须以 http:// 或 https:// 开头，且不含特殊字符。"
    return 1
  fi

  note "当前方案：$(external_mode_name "$current_mode")"
  new_mode="$(select_external_mode "$current_mode")"

  new_stream_upstream_url="$current_stream_upstream_url"
  new_stream_upstream_urls="$current_stream_upstream_urls"
  new_source_site_url="$current_source_site_url"
  new_referer_url="$current_referer_url"

  if [[ "$new_mode" =~ ^emby_ ]]; then
    local current_stream_display="${current_stream_upstream_urls:-$current_stream_upstream_url}"
    [[ -z "$current_stream_display" ]] && current_stream_display="未设置"
    read -rp "新的推流节点 URL（多个可用英文逗号分隔，当前 ${current_stream_display}）: " input_stream
    if [[ -n "$input_stream" ]]; then
      if ! new_stream_upstream_urls="$(normalize_url_list "$input_stream")"; then
        error "推流节点 URL 格式不合法。必须以 http:// 或 https:// 开头，且不含特殊字符。"
        return 1
      fi
    elif [[ -n "$new_stream_upstream_urls" ]]; then
      :
    elif [[ -n "$new_stream_upstream_url" ]]; then
      new_stream_upstream_urls="$new_stream_upstream_url"
    else
      error "推流节点 URL 格式不合法。必须以 http:// 或 https:// 开头，且不含特殊字符。"
      return 1
    fi

    local -a _stream_urls
    IFS='|' read -r -a _stream_urls <<< "$new_stream_upstream_urls"
    new_stream_upstream_url="${_stream_urls[0]}"

    read -rp "新的源站公开 URL（当前 ${current_source_site_url:-$new_upstream_url}）: " input_source
    [[ -n "$input_source" ]] && new_source_site_url="$input_source"
    [[ -z "$new_source_site_url" ]] && new_source_site_url="$new_upstream_url"
    if ! valid_url "$new_source_site_url"; then
      error "源站公开 URL 格式不合法。必须以 http:// 或 https:// 开头，且不含特殊字符。"
      return 1
    fi

    read -rp "新的 Referer URL（当前 ${current_referer_url:-$(default_referer_from_url "$new_source_site_url")}) : " input_referer
    [[ -n "$input_referer" ]] && new_referer_url="$input_referer"
    [[ -z "$new_referer_url" ]] && new_referer_url="$(default_referer_from_url "$new_source_site_url")"
  else
    new_stream_upstream_url=""
    new_stream_upstream_urls=""
    new_source_site_url=""
    new_referer_url=""
  fi

  desired_port="$new_listen"
  create_port="$new_listen"
  [[ "$new_domain" != "$current_domain" ]] && domain_changed=1

  if is_port_used_os "$new_listen"; then
    warn "监听端口 ${new_listen} 当前已被占用。"
    if ! confirm "是否继续写入配置并交由 nginx -t 校验？"; then
      info "已取消修改。"
      return 0
    fi

    if [[ "$new_listen" == "443" ]] && [[ ! -f "${SSL_DIR}/${new_domain}/fullchain.pem" || ! -f "${SSL_DIR}/${new_domain}/privkey.pem" ]]; then
      warn "检测到 443 端口复用且新域名暂无证书，已自动改为先使用 80 端口创建配置。"
      create_port="80"
    fi

    if port_has_ssl_listener "$desired_port"; then
      if [[ -f "${SSL_DIR}/${new_domain}/fullchain.pem" && -f "${SSL_DIR}/${new_domain}/privkey.pem" ]]; then
        warn "检测到端口 ${desired_port} 已用于 HTTPS，且新域名已有证书。"
        warn "将先写入临时 HTTP 配置，再自动切换为 ${desired_port} HTTPS。"
        create_port="80"
        force_enable_https="1"
      else
        warn "检测到端口 ${desired_port} 已用于 HTTPS，但新域名暂无证书。"
        warn "已自动改为先使用 80 端口创建配置。"
        create_port="80"
      fi
    fi
  fi

  new_target="$(conf_target_path "$new_domain" "$desired_port")"
  tmp="$(mktemp /tmp/nginxx-external-mod-"${new_domain}"-XXXXXX)"
  trap 'rm -f "${tmp:-}"' RETURN
  build_external_proxy_conf "$new_domain" "$create_port" "$new_upstream_url" "$new_mode" "$tmp" "0" "$new_stream_upstream_url" "$new_source_site_url" "$new_referer_url" "$new_stream_upstream_urls"

  if apply_conf_with_rollback "$tmp" "$new_target"; then
    if [[ "$src" != "$new_target" && -f "$src" ]]; then
      ${SUDO} rm -f "$src"
    fi

    if [[ "$force_enable_https" == "1" || "$was_https_enabled" == "1" ]]; then
      if [[ ! -f "${SSL_DIR}/${new_domain}/fullchain.pem" || ! -f "${SSL_DIR}/${new_domain}/privkey.pem" ]]; then
        if ! ensure_cert_for_domain_interactive "$new_domain"; then
          warn "新域名证书申请未完成，当前保留为 HTTP 配置。"
        elif enable_https_for_conf_file "$new_domain" "$new_target" "$desired_port"; then
          info "已完成：修改配置并重新启用 HTTPS。"
        else
          warn "证书已就绪，但重新启用 HTTPS 失败。请检查监听端口占用和 nginx -t 输出。"
        fi
      elif enable_https_for_conf_file "$new_domain" "$new_target" "$desired_port"; then
        info "已完成：修改配置并重新启用 HTTPS。"
      else
        warn "修改成功，但重新启用 HTTPS 失败。当前配置可能仍是 HTTP，请检查 nginx -t 输出后再试。"
      fi
    elif (( domain_changed == 1 )) && ! valid_ipv4_host "$new_domain" && [[ ! -f "${SSL_DIR}/${new_domain}/fullchain.pem" || ! -f "${SSL_DIR}/${new_domain}/privkey.pem" ]]; then
      if confirm "检测到更换了域名且新域名暂无证书，是否立即申请并启用 HTTPS？"; then
        if ensure_cert_for_domain_interactive "$new_domain" && enable_https_for_conf_file "$new_domain" "$new_target" "$desired_port"; then
          info "已完成：修改配置、新域名证书申请与 HTTPS 启用。"
        else
          warn "新域名证书申请或 HTTPS 启用失败，当前保留 HTTP 配置。"
        fi
      fi
    fi

    if (( was_disabled == 1 )); then
      ${SUDO} mv "$new_target" "${new_target}.bak"
      if nginx_test; then
        reload_nginx_safe
        info "原配置处于停用状态，已保持为停用。"
      else
        ${SUDO} mv "${new_target}.bak" "$new_target"
        error "恢复停用状态失败，已恢复为启用配置。"
        ${SUDO} nginx -t || true
        return 1
      fi
    fi
  fi

  rm -f "$tmp"
}

delete_conf() {
  local file target
  file="${1:-}"
  if [[ -z "$file" ]]; then
    error "未指定配置文件。"
    return 1
  fi
  target="${CONF_DIR}/${file}"

  if ! confirm "确认永久删除 ${file} ?"; then
    info "已取消删除。"
    return 0
  fi

  # 先删，再校验，失败则无法自动恢复（所以先备份）
  local backup
  backup="${target}.delbak.$(date +%s)"
  ${SUDO} cp -a "$target" "$backup"
  ${SUDO} rm -f "$target"

  if nginx_test; then
    reload_nginx_safe
    ${SUDO} rm -f "$backup"
    info "已删除：${file}"
  else
    ${SUDO} cp -a "$backup" "$target"
    ${SUDO} rm -f "$backup"
    error "删除后配置失败，已恢复文件。"
    ${SUDO} nginx -t || true
    return 1
  fi
}

edit_conf_manual() {
  local file target backup
  file="${1:-}"
  if [[ -z "$file" ]]; then
    error "未指定配置文件。"
    return 1
  fi

  target="${CONF_DIR}/${file}"
  if [[ ! -f "$target" ]]; then
    error "配置文件不存在：${target}"
    return 1
  fi

  backup="${target}.editbak.$(date +%s)"
  ${SUDO} cp -a "$target" "$backup"

  if ! run_editor "$target"; then
    ${SUDO} cp -a "$backup" "$target"
    ${SUDO} rm -f "$backup"
    error "编辑器启动失败，已恢复原配置。"
    return 1
  fi

  mark_conf_manual_edited "$target"

  if nginx_test; then
    reload_nginx_safe
    ${SUDO} rm -f "$backup"
    info "配置已编辑并生效：${file}"
  else
    ${SUDO} cp -a "$backup" "$target"
    ${SUDO} rm -f "$backup"
    error "编辑后配置校验失败，已回滚到修改前。"
    ${SUDO} nginx -t || true
    return 1
  fi
}

config_file_action_menu() {
  local file="$1"

  while true; do
    clear
    echo "====== 配置操作：${file} ======"
    echo "1) 启用"
    echo "2) 停用"
    echo "3) 修改"
    echo "4) 编辑"
    echo "5) 删除"
    echo "0) 返回上一级"
    echo "============================"
    read -rp "请选择: " c

    case "$c" in
      1) run_menu_action enable_conf "$file"; pause; return 0 ;;
      2) run_menu_action disable_conf "$file"; pause; return 0 ;;
      3) run_menu_action modify_conf "$file"; pause; return 0 ;;
      4) run_menu_action edit_conf_manual "$file"; pause; return 0 ;;
      5) run_menu_action delete_conf "$file"; pause; return 0 ;;
      0) return 0 ;;
      *) warn "无效输入。请输入 0-5 之间的菜单编号。"; pause ;;
    esac
  done
}

config_manage_menu() {
  require_nginx_installed || {
    pause
    return 0
  }

  while true; do
    clear
    echo "========== 配置列表管理 =========="
    if ! print_conf_list; then
      pause
      return 0
    fi
    echo
    echo "0) 返回上一级"
    echo "==============================="
    read -rp "请选择配置序号: " c

    if [[ "$c" == "0" ]]; then
      return 0
    fi

    if ! [[ "$c" =~ ^[0-9]+$ ]] || (( c < 1 || c > ${#FILES[@]} )); then
      warn "无效序号。请输入列表中存在的配置编号。"
      pause
      continue
    fi

    config_file_action_menu "${FILES[$((c-1))]}"
  done
}

# ---------- 导入已有 nginx 配置 ----------

# 扫描目录，返回未被 Nginx-X 管理的 .conf 文件（去重）
_scan_unmanaged_confs() {
  local -A seen
  # 预建已纳管域名-端口索引（含停用的 .bak 等），用于去重
  local -A managed_index
  local _f _d _p
  for _f in "${CONF_DIR}"/*.conf "${CONF_DIR}"/*.conf.*; do
    [[ -f "$_f" ]] || continue
    grep -q '^# managed_by=Nginx-X$' "$_f" 2>/dev/null || continue
    _d="$(grep -oP '^# domain=\K.+' "$_f" 2>/dev/null | head -1)"
    _p="$(grep -oP '^# listen_port=\K.+' "$_f" 2>/dev/null | head -1)"
    [[ -n "$_d" ]] && managed_index["${_d}|${_p:-80}"]=1
  done

  local dirs=(
    "$CONF_DIR"
    "/etc/nginx/sites-enabled"
    "/etc/nginx/sites-available"
  )
  local dir conf real_path

  for dir in "${dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    for conf in "$dir"/*.conf "$dir"/*; do
      [[ -f "$conf" ]] || continue
      # 只处理看起来像 nginx 配置的文件（含 server 块）
      grep -qE '^[[:space:]]*server[[:space:]]*\{' "$conf" 2>/dev/null || continue
      # 跳过已纳管的
      grep -q '^# managed_by=Nginx-X$' "$conf" 2>/dev/null && continue
      # 跳过 nginx 默认/状态配置
      local base; base="$(basename "$conf")"
      [[ "$base" == default || "$base" == default.conf || "$base" == default.conf.* || "$base" == nginx_status.conf ]] && continue
      # 通过 realpath 去重（sites-enabled 软链接 → sites-available）
      real_path="$(realpath "$conf" 2>/dev/null || echo "$conf")"
      [[ -n "${seen[$real_path]:-}" ]] && continue
      seen["$real_path"]="$conf"
      # 检查是否已有同域名-端口的纳管配置（包括停用的）
      local _cd _cp
      _cd="$(awk '/^[[:space:]]*server[[:space:]]*\{/{s=1} s && /server_name/{gsub(/;/,""); print $2; exit}' "$conf")"
      _cp="$(awk '/^[[:space:]]*server[[:space:]]*\{/{s=1} s && /^[[:space:]]*listen[[:space:]]/{gsub(/;/,""); for(i=2;i<=NF;i++){if($i~/^[0-9]+$/){print $i; exit}}}' "$conf")"
      [[ -z "$_cp" ]] && _cp="80"
      [[ -n "$_cd" && -n "${managed_index["${_cd}|${_cp}"]:-}" ]] && continue
      # 对 sites-available/sites-enabled 的文件，额外检查 conf.d 是否已存在同名纳管配置
      if [[ "$dir" != "$CONF_DIR" ]]; then
        local _candidate="${CONF_DIR}/${_cd}-${_cp}.conf"
        if [[ -f "$_candidate" ]] && grep -q '^# managed_by=Nginx-X$' "$_candidate" 2>/dev/null; then
          continue
        fi
      fi
      echo "$conf"
    done
  done
}

# 从现有 conf 中提取元数据
_extract_conf_meta() {
  local conf="$1"
  local domain listen_port backend_url https_enabled="false" mode=""

  # 提取 server_name（取第一个 server 块里的第一个 token）
  domain="$(awk '/^[[:space:]]*server[[:space:]]*\{/{in_srv=1} in_srv && /server_name/{gsub(/;/,""); print $2; exit}' "$conf")"
  [[ -z "$domain" || "$domain" == "_" || "$domain" == "localhost" ]] && domain=""

  # 提取 listen 端口（优先取带 ssl 的，否则第一个数字）
  listen_port="$(awk '/^[[:space:]]*server[[:space:]]*\{/{in_srv=1} in_srv && /^[[:space:]]*listen[[:space:]]/{gsub(/;/,""); for(i=2;i<=NF;i++){if($i~/^[0-9]+$/){print $i; exit}}}' "$conf")"
  [[ -z "$listen_port" ]] && listen_port="80"

  # 提取 proxy_pass
  backend_url="$(grep -oP 'proxy_pass\s+\K[^;]+' "$conf" | head -1)"

  # 检测 HTTPS
  if grep -qE '^[[:space:]]*ssl_certificate[[:space:]]+' "$conf" 2>/dev/null; then
    https_enabled="true"
  fi

  # 检测是否为外部反代（proxy_pass 不是 127.0.0.1/localhost）
  if [[ -n "$backend_url" ]] && ! echo "$backend_url" | grep -qE '127\.0\.0\.1|localhost'; then
    mode="external"
  fi

  echo "$domain|$listen_port|$backend_url|$https_enabled|$mode"
}

validate_importable_conf() {
  local conf="$1"
  local servers locations

  servers="$(conf_server_block_count "$conf")"
  [[ -z "$servers" ]] && servers=0
  if (( servers != 1 )); then
    warn "跳过 ${conf}：检测到 ${servers} 个 server 块。"
    warn "为避免误删/误改同文件中的其他站点，请先手动拆分为单 server 配置后再导入。"
    return 1
  fi

  locations="$(grep -cE '^[[:space:]]*location[[:space:]]+' "$conf" 2>/dev/null || true)"
  [[ -z "$locations" ]] && locations=0
  if (( locations > 2 )); then
    warn "跳过 ${conf}：检测到多个 location，可能包含自定义业务规则。"
    warn "当前导入会整文件纳管，后续修改/HTTPS 开关可能覆盖自定义规则；请手动拆分或使用 '编辑' 维护。"
    return 1
  fi

  return 0
}

import_single_conf() {
  local conf="$1"
  local meta domain listen_port backend_url https_enabled mode
  local target_name target_path tmp
  local real_conf backup_conf="" target_written=""
  local -a removed_links=()

  meta="$(_extract_conf_meta "$conf")"
  IFS='|' read -r domain listen_port backend_url https_enabled mode <<< "$meta"

  validate_importable_conf "$conf" || return 1

  if [[ -z "$domain" ]]; then
    warn "跳过 ${conf}：无法识别 server_name。"
    return 1
  fi

  # 目标文件名
  target_name="${domain}-${listen_port}.conf"
  target_path="${CONF_DIR}/${target_name}"

  # 构建元数据头
  local meta_header
  meta_header="# managed_by=Nginx-X"
  meta_header+=$'\n'
  meta_header+="# domain=${domain}"
  meta_header+=$'\n'
  meta_header+="# listen_port=${listen_port}"
  meta_header+=$'\n'
  meta_header+="# imported=true"
  if [[ -n "$backend_url" ]]; then
    local backend_port
    backend_port="$(echo "$backend_url" | grep -oP ':\K[0-9]+(?=/?$)' || true)"
    if [[ -n "$backend_port" ]]; then
      meta_header+=$'\n'
      meta_header+="# backend_port=${backend_port}"
    fi
    if [[ "$mode" == "external" ]]; then
      meta_header+=$'\n'
      meta_header+="# mode=external"
      meta_header+=$'\n'
      meta_header+="# upstream_url=${backend_url}"
    fi
  fi
  if [[ "$https_enabled" == "true" ]]; then
    meta_header+=$'\n'
    meta_header+="# https_enabled=true"
  fi
  meta_header+=$'\n'

  # 生成新配置（元数据头 + 原始内容）
  tmp="$(mktemp /tmp/nginxx-import-XXXXXX)"
  {
    echo "$meta_header"
    cat "$conf"
  } > "$tmp"

  real_conf="$(realpath "$conf" 2>/dev/null || echo "$conf")"

  if [[ "$real_conf" == "${CONF_DIR}/"* ]]; then
    # 原文件就在 conf.d 里，直接原地加元数据头
    backup_conf="$(mktemp /tmp/nginxx-import-backup-XXXXXX)"
    ${SUDO} cp -a "$real_conf" "$backup_conf"
    ${SUDO} cp -a "$tmp" "$real_conf"
    target_written="$real_conf"
    # 如果文件名不符合 domain-port.conf 规范，重命名
    if [[ "$(basename "$real_conf")" != "$target_name" && ! -f "$target_path" ]]; then
      ${SUDO} mv "$real_conf" "$target_path"
      target_written="$target_path"
    fi

    if ! nginx_test; then
      [[ -n "$target_written" && "$target_written" != "$real_conf" ]] && ${SUDO} rm -f "$target_written"
      ${SUDO} cp -a "$backup_conf" "$real_conf"
      rm -f "$tmp" "$backup_conf"
      error "导入后配置校验失败，已回滚：${conf}"
      ${SUDO} nginx -t || true
      return 1
    fi
    rm -f "$backup_conf"
  else
    # 来自 sites-available / sites-enabled，复制到 conf.d
    ${SUDO} cp -a "$tmp" "$target_path"
    target_written="$target_path"

    # 移除 sites-enabled 中对应的软链接（避免重复加载）
    local enabled_link
    for enabled_link in /etc/nginx/sites-enabled/*; do
      [[ -L "$enabled_link" ]] || continue
      local link_target
      link_target="$(realpath "$enabled_link" 2>/dev/null || true)"
      if [[ "$link_target" == "$real_conf" ]]; then
        ${SUDO} rm -f "$enabled_link"
        removed_links+=("$enabled_link")
        info "已移除 sites-enabled 软链接：$(basename "$enabled_link")"
      fi
    done

    if ! nginx_test; then
      ${SUDO} rm -f "$target_written"
      local removed_link
      for removed_link in "${removed_links[@]}"; do
        ${SUDO} ln -s "$real_conf" "$removed_link" 2>/dev/null || true
      done
      rm -f "$tmp"
      error "导入后配置校验失败，已回滚：${conf}"
      ${SUDO} nginx -t || true
      return 1
    fi

    # 导入成功后询问是否删除原文件
    if confirm "是否删除原始配置文件 ${real_conf}？（推荐删除，避免重复扫描）"; then
      ${SUDO} rm -f "$real_conf"
      info "已删除原始文件：${real_conf}"
    else
      note "原始文件保留在：${real_conf}"
    fi
  fi

  rm -f "$tmp"
  info "已导入：${domain} (${listen_port}) → ${target_path}"
  return 0
}

import_existing_confs() {
  local -a unmanaged
  mapfile -t unmanaged < <(_scan_unmanaged_confs)

  if [[ ${#unmanaged[@]} -eq 0 ]]; then
    info "未发现需要导入的已有配置。"
    return 0
  fi

  echo ""
  info "发现 ${#unmanaged[@]} 个未纳管的 Nginx 配置："
  echo ""

  local conf meta domain listen_port rest imported=0
  for conf in "${unmanaged[@]}"; do
    meta="$(_extract_conf_meta "$conf")"
    IFS='|' read -r domain listen_port rest <<< "$meta"
    [[ -z "$domain" ]] && domain="(无法识别)"

    echo "  → ${conf}"
    echo "    域名: ${domain}  端口: ${listen_port}"
    if confirm "    是否导入此配置？"; then
      if import_single_conf "$conf"; then
        ((imported++))
      fi
    else
      info "    已跳过。"
    fi
    echo ""
  done

  if [[ $imported -gt 0 ]]; then
    info "共导入 ${imported} 个配置。"
    # 验证整体配置
    if ${SUDO} nginx -t 2>&1; then
      reload_nginx_safe
    else
      warn "导入后 nginx -t 测试未通过，请检查配置。"
    fi
  fi
}

# 安装完成后自动检测并提示导入
auto_import_after_install() {
  local -a unmanaged
  mapfile -t unmanaged < <(_scan_unmanaged_confs)
  [[ ${#unmanaged[@]} -eq 0 ]] && return 0

  echo ""
  info "检测到 ${#unmanaged[@]} 个已有的 Nginx 配置尚未纳入管理。"
  if confirm "是否立即导入到 Nginx-X？"; then
    import_existing_confs
  else
    info "已跳过。你可以稍后在 [配置管理 → 导入已有配置] 中手动导入。"
  fi
}

# ---------- DNS 服务器管理 ----------
dns_setup_menu() {
  while true; do
    clear
    echo "========== 系统 DNS 设置 =========="
    echo "当前 DNS 配置："
    if [[ -f /etc/resolv.conf ]]; then
      grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | while read -r line; do
        echo "  ${line}"
      done
    else
      echo "  (未找到 /etc/resolv.conf)"
    fi
    echo ""
    echo "预设 DNS："
    echo "1) Google      (8.8.8.8 + 8.8.4.4)"
    echo "2) Cloudflare  (1.1.1.1 + 1.0.0.1)"
    echo "3) 阿里 DNS    (223.5.5.5 + 223.6.6.6)"
    echo "4) 腾讯 DNS    (119.29.29.29)"
    echo "5) 自定义输入"
    echo "0) 返回上一级"
    echo "================================"
    read -rp "请选择: " c

    local ns1="" ns2=""

    case "$c" in
      1) ns1="8.8.8.8"; ns2="8.8.4.4" ;;
      2) ns1="1.1.1.1"; ns2="1.0.0.1" ;;
      3) ns1="223.5.5.5"; ns2="223.6.6.6" ;;
      4) ns1="119.29.29.29"; ns2="" ;;
      5)
        read -rp "请输入首选 DNS: " ns1
        [[ -z "$ns1" ]] && { error "DNS 不能为空。"; pause; continue; }
        read -rp "请输入备用 DNS (可留空): " ns2
        ;;
      0) return 0 ;;
      *) warn "无效输入。请输入 0-5 之间的菜单编号。"; pause; continue ;;
    esac

    if [[ -z "$ns1" ]]; then
      continue
    fi

    # 保护现有系统：检测 resolv.conf 是否被系统服务托管（systemd-resolved / resolvconf / NetworkManager 等）。
    # 直接覆盖它的目标会在服务下次重新生成时恢复，也会破坏系统 DNS 管理。
    local managed_by=""
    if [[ -L /etc/resolv.conf ]]; then
      local link_target
      link_target="$(readlink -f /etc/resolv.conf 2>/dev/null || readlink /etc/resolv.conf)"
      case "$link_target" in
        */systemd/resolve/*) managed_by="systemd-resolved" ;;
        */resolvconf/*)      managed_by="resolvconf" ;;
        */NetworkManager/*)  managed_by="NetworkManager" ;;
        *)                   managed_by="symlink -> ${link_target}" ;;
      esac
    elif check_cmd systemctl && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
      managed_by="systemd-resolved (active)"
    elif check_cmd resolvconf; then
      managed_by="resolvconf"
    fi

    if [[ -n "$managed_by" ]]; then
      warn "检测到 /etc/resolv.conf 由 ${managed_by} 接管。"
      warn "直接覆盖会被系统重写，且可能破坏现有 DNS 服务。"
      warn "建议通过对应服务配置修改 DNS（如 systemd-resolved / netplan / NetworkManager）。"
      if ! confirm "确认仍要直接覆写 /etc/resolv.conf？"; then
        info "已取消。"
        pause
        continue
      fi
    fi

    local tmp_resolv
    tmp_resolv="$(mktemp /tmp/nginxx-resolv-XXXXXX)"
    {
      echo "# Generated by Nginx-X"
      echo "nameserver ${ns1}"
      [[ -n "$ns2" ]] && echo "nameserver ${ns2}"
    } > "$tmp_resolv"

    # 如果 resolv.conf 是符号链接，先删除链接再写入普通文件，避免写回链接目标目录。
    ${SUDO} cp -a /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
    if [[ -L /etc/resolv.conf ]]; then
      ${SUDO} rm -f /etc/resolv.conf
    fi
    ${SUDO} cp -a "$tmp_resolv" /etc/resolv.conf
    rm -f "$tmp_resolv"

    info "DNS 已更新为：${ns1}${ns2:+ + ${ns2}}"
    warn "注意：/etc/resolv.conf 可能在系统重启或 DHCP 续租后被覆盖。"
    pause
  done
}

config_entry_menu() {
  while true; do
    clear
    echo "========== 配置管理 =========="
    echo "1) 内部反代"
    echo "2) 外部反代"
    echo "3) 配置列表"
    echo "4) 导入已有配置"
    echo "5) 系统DNS设置"
    echo "0) 返回上一级"
    echo "=============================="
    read -rp "请选择: " c

    case "$c" in
      1) run_menu_action add_reverse_proxy; pause ;;
      2) run_menu_action add_external_url_proxy; pause ;;
      3) config_manage_menu ;;
      4) run_menu_action import_existing_confs; pause ;;
      5) dns_setup_menu ;;
      0) return 0 ;;
      *) warn "无效输入。请输入 0-5 之间的菜单编号。"; pause ;;
    esac
  done
}

# ---------- 功能5：证书管理（acme.sh） ----------

# --- DNS-01 配置 ---
load_dns_conf() {
  ensure_state_dir
  if [[ -f "$DNS_CONF" ]]; then
    # shellcheck disable=SC1090
    . "$DNS_CONF"
  fi
}

save_dns_conf() {
  local provider="$1"
  local key1="$2"
  local key2="$3"
  ensure_state_dir
  # 密钥属于敏感信息，先设置只读权限再写入，避免明文密钥被同机其他用户读到。
  (
    umask 077
    cat > "$DNS_CONF" <<EOF
DNS_PROVIDER="${provider}"
DNS_KEY1="${key1}"
DNS_KEY2="${key2}"
EOF
  )
  chmod 600 "$DNS_CONF" 2>/dev/null || true
  info "DNS API 配置已保存到：${DNS_CONF}（权限 600）。"
  warn "提醒：DNS API 密钥以明文存储于该文件，请自行保护该主机的账户权限。"
}

has_dns_config() {
  load_dns_conf
  [[ -n "${DNS_PROVIDER:-}" && -n "${DNS_KEY1:-}" ]]
}

get_dns_issue_args() {
  load_dns_conf
  case "${DNS_PROVIDER:-}" in
    cf|cloudflare)
      echo "--dns dns_cf"
      ;;
    dp|dnspod)
      echo "--dns dns_dp"
      ;;
    ali|alidns)
      echo "--dns dns_ali"
      ;;
    he|he.net)
      echo "--dns dns_he"
      ;;
    gd|godaddy)
      echo "--dns dns_gd"
      ;;
    hw|huaweicloud)
      echo "--dns dns_huaweicloud"
      ;;
    aws|route53)
      echo "--dns dns_aws"
      ;;
    google|gcp)
      echo "--dns dns_gcloud"
      ;;
    *)
      echo ""
      ;;
  esac
}

setup_dns_api() {
  local choice provider key1 key2
  echo "选择 DNS 服务商："
  echo "1)  Cloudflare      (CF_Token)"
  echo "2)  DNSPod          (DP_Id + DP_Key)"
  echo "3)  阿里云 DNS      (Ali_Key + Ali_Secret)"
  echo "4)  HE.net          (HE_Username + HE_Password)"
  echo "5)  GoDaddy         (GD_Key + GD_Secret)"
  echo "6)  华为云          (HUAWEICLOUD_Username + HUAWEICLOUD_Password)"
  echo "7)  AWS Route53     (AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY)"
  echo "8)  Google Cloud    (GCE_Project + GCE_ServiceAccountEmail)"
  read -rp "请选择 [1-8]: " choice

  case "$choice" in
    1) provider="cf"; read -rp "Cloudflare API Token: " key1 ;;
    2) provider="dp"; read -rp "DNSPod ID: " key1; read -rp "DNSPod Key: " key2 ;;
    3) provider="ali"; read -rp "Aliyun AccessKey ID: " key1; read -rp "Aliyun AccessKey Secret: " key2 ;;
    4) provider="he"; read -rp "HE.net Username: " key1; read -rp "HE.net Password: " key2 ;;
    5) provider="gd"; read -rp "GoDaddy API Key: " key1; read -rp "GoDaddy API Secret: " key2 ;;
    6) provider="hw"; read -rp "华为云 Username: " key1; read -rp "华为云 Password: " key2 ;;
    7) provider="aws"; read -rp "AWS Access Key ID: " key1; read -rp "AWS Secret Access Key: " key2 ;;
    8) provider="google"; read -rp "GCE Project: " key1; read -rp "Service Account Email: " key2 ;;
    *) error "无效选择。"; return 1 ;;
  esac
  [[ -z "$key1" ]] && { error "API Key 不能为空。"; return 1; }

  save_dns_conf "$provider" "$key1" "${key2:-}"

  # Export env vars for acme.sh
  case "$provider" in
    cf) export CF_Token="$key1" ;;
    dp) export DP_Id="$key1"; export DP_Key="$key2" ;;
    ali) export Ali_Key="$key1"; export Ali_Secret="$key2" ;;
    he) export HE_Username="$key1"; export HE_Password="$key2" ;;
    gd) export GD_Key="$key1"; export GD_Secret="$key2" ;;
    hw) export HUAWEICLOUD_Username="$key1"; export HUAWEICLOUD_Password="$key2" ;;
    aws) export AWS_ACCESS_KEY_ID="$key1"; export AWS_SECRET_ACCESS_KEY="$key2" ;;
    google) export GCE_Project="$key1"; export GCE_ServiceAccountEmail="$key2" ;;
  esac

  info "DNS API 配置完成（${provider}）。"
  if confirm "是否现在测试申请证书？"; then
    local test_domain
    read -rp "请输入测试域名: " test_domain
    if valid_domain "$test_domain"; then
      _issue_cert_dns "$test_domain"
    fi
  fi
}

export_dns_env() {
  load_dns_conf
  # DNS_KEY1/DNS_KEY2 are sourced from $DNS_CONF by load_dns_conf; shellcheck can't see the assignment.
  # shellcheck disable=SC2153
  case "${DNS_PROVIDER:-}" in
    cf) export CF_Token="${DNS_KEY1}" ;;
    dp) export DP_Id="${DNS_KEY1}"; export DP_Key="${DNS_KEY2}" ;;
    ali) export Ali_Key="${DNS_KEY1}"; export Ali_Secret="${DNS_KEY2}" ;;
    he) export HE_Username="${DNS_KEY1}"; export HE_Password="${DNS_KEY2}" ;;
    gd) export GD_Key="${DNS_KEY1}"; export GD_Secret="${DNS_KEY2}" ;;
    hw) export HUAWEICLOUD_Username="${DNS_KEY1}"; export HUAWEICLOUD_Password="${DNS_KEY2}" ;;
    aws) export AWS_ACCESS_KEY_ID="${DNS_KEY1}"; export AWS_SECRET_ACCESS_KEY="${DNS_KEY2}" ;;
    google) export GCE_Project="${DNS_KEY1}"; export GCE_ServiceAccountEmail="${DNS_KEY2}" ;;
  esac
}

detect_cert_mode() {
  # 返回 http 或 dns（自动检测最适合的验证方式）
  # NAT 机没有 80 端口时自动返回 dns
  if ss -lnt 2>/dev/null | awk 'NR>1{print $4}' | grep -qE '(^|:)80$'; then
    echo "http"
  elif has_dns_config; then
    echo "dns"
  else
    echo "http"
  fi
}

select_cert_mode_interactive() {
  # 交互式选择证书验证方式，返回 "http" 或 "dns"
  # 注意：此函数被 $(...) 调用，所有用户提示必须输出到 stderr 才能显示
  local choice=""
  >&2 echo "Select cert verification method:"
  >&2 echo "1) HTTP-01  (requires port 80 reachable)"
  >&2 echo "2) DNS-01   (requires DNS API Token, for NAT/no-port80)"

  local default_choice="1"
  if ! ss -lnt 2>/dev/null | awk 'NR>1{print $4}' | grep -qE '(^|:)80$'; then
    >&2 warn "Port 80 not detected, DNS-01 suggested."
    default_choice="2"
  fi

  read -rp "Choose [1-2] (default ${default_choice}): " choice
  [[ -z "$choice" ]] && choice="$default_choice"

  case "$choice" in
    2)
      if ! has_dns_config; then
        >&2 warn "DNS API Token not configured, please set up first."
        if ! setup_dns_api >&2; then
          >&2 error "DNS API setup failed, fallback to HTTP-01."
          echo "http"
          return 0
        fi
      fi
      echo "dns"
      ;;
    *)
      echo "http"
      ;;
  esac
}

_issue_cert_dns() {
  local domain="$1"
  local dns_args issue_output retry_after

  load_email
  if [[ -z "${ACME_EMAIL:-}" ]]; then
    error "未设置邮箱，无法申请证书。"
    return 1
  fi

  if ! has_dns_config; then
    error "未配置 DNS API。请先在证书管理里执行 [3) 配置 DNS API]。"
    return 1
  fi

  dns_args="$(get_dns_issue_args)"
  if [[ -z "$dns_args" ]]; then
    error "不支持的 DNS 服务商配置，请重新设置。"
    return 1
  fi

  ensure_acme_installed || return 1

  note "开始为 ${domain} 申请证书（DNS-01 验证）..."
  export_dns_env
  "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  "$HOME/.acme.sh/acme.sh" --register-account -m "$ACME_EMAIL" >/dev/null 2>&1 || true

  # dns_args holds acme.sh flags like "--dns dns_cf" and must word-split into two args.
  # shellcheck disable=SC2086
  issue_output="$("$HOME/.acme.sh/acme.sh" --issue -d "$domain" $dns_args 2>&1)" || {
    echo "$issue_output"
    if echo "$issue_output" | grep -qi 'rateLimited\|too many certificates'; then
      retry_after="$(echo "$issue_output" | sed -n 's/.*retry after \([^:]*UTC\).*/\1/p' | head -n1)"
      error "证书申请失败：触发 Let's Encrypt 频率限制（429）。"
      [[ -n "$retry_after" ]] && warn "可重试时间（UTC）：$retry_after"
    elif echo "$issue_output" | grep -qi 'verify error\|dns.*fail\|NXDOMAIN\|SERVFAIL'; then
      error "DNS 验证失败。请确认：1) DNS API 密钥正确 2) 域名 DNS 托管在所选服务商 3) 域名已正确解析。"
    else
      error "证书申请失败。请检查 DNS API 配置和网络连接。"
    fi
    return 1
  }

  ${SUDO} mkdir -p "${SSL_DIR}/${domain}"
  "$HOME/.acme.sh/acme.sh" --install-cert -d "$domain" \
    --key-file "${SSL_DIR}/${domain}/privkey.pem" \
    --fullchain-file "${SSL_DIR}/${domain}/fullchain.pem"

  ensure_acme_cron
  info "证书申请并安装成功（DNS-01）。"
}

_issue_cert_http() {
  # 原有的 HTTP-01 逻辑
  local domain="$1"
  local challenge_conf

  ensure_acme_location_for_domain_conf "$domain"
  challenge_conf="$(ensure_http_challenge_server "$domain")"

  if ! reload_nginx_safe; then
    cleanup_http_challenge_server "$challenge_conf"
    error "证书申请前校验失败：Nginx 配置未生效。"
    return 1
  fi

  local pre_rc=0
  if precheck_http01 "$domain"; then
    pre_rc=0
  else
    pre_rc=$?
  fi
  if (( pre_rc != 0 )); then
    if [[ $pre_rc -eq 10 ]]; then
      if ! confirm "自检存在风险，是否仍继续申请证书？"; then
        cleanup_http_challenge_server "$challenge_conf"
        reload_nginx_safe || true
        info "已取消申请。"
        return 1
      fi
      warn "你选择继续申请，将直接尝试签发。"
    else
      if has_dns_config; then
        warn "HTTP-01 自检失败，是否改用 DNS-01 方式申请？"
        if confirm "使用 DNS-01 方式？"; then
          cleanup_http_challenge_server "$challenge_conf"
          reload_nginx_safe || true
          _issue_cert_dns "$domain"
          return $?
        fi
      fi
      if ! confirm "自检失败（建议先修复），是否仍强制继续申请？"; then
        cleanup_http_challenge_server "$challenge_conf"
        reload_nginx_safe || true
        info "已取消申请。"
        return 1
      fi
      warn "你选择强制继续申请。"
    fi
  fi

  ensure_acme_installed || return 1

  note "开始为 ${domain} 申请证书（HTTP 验证）..."
  "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  "$HOME/.acme.sh/acme.sh" --register-account -m "$ACME_EMAIL" >/dev/null 2>&1 || true

  local issue_output retry_after
  issue_output="$("$HOME/.acme.sh/acme.sh" --issue -d "$domain" --webroot /usr/share/nginx/html 2>&1)" || {
    echo "$issue_output"
    cleanup_http_challenge_server "$challenge_conf"
    reload_nginx_safe || true

    if echo "$issue_output" | grep -qi 'rateLimited\|too many certificates'; then
      retry_after="$(echo "$issue_output" | sed -n 's/.*retry after \([^:]*UTC\).*/\1/p' | head -n1)"
      error "证书申请失败：触发 Let's Encrypt 频率限制（429）。"
      [[ -n "$retry_after" ]] && warn "可重试时间（UTC）：$retry_after"
      warn "这是 CA 侧限制，不是你服务器或端口配置问题。"
    else
      error "证书申请失败。请确认域名已解析到本机、80 端口已放行，且没有被 CDN/防火墙拦截。"
      if has_dns_config; then
        warn "你已配置 DNS API，可前往主菜单选择 [3) 配置 DNS API] 后使用 DNS 方式申请。"
      fi
    fi
    return 1
  }

  cleanup_http_challenge_server "$challenge_conf"
  reload_nginx_safe || true

  ${SUDO} mkdir -p "${SSL_DIR}/${domain}"
  "$HOME/.acme.sh/acme.sh" --install-cert -d "$domain" \
    --key-file "${SSL_DIR}/${domain}/privkey.pem" \
    --fullchain-file "${SSL_DIR}/${domain}/fullchain.pem"

  ensure_acme_cron
  info "证书申请并安装成功。"
}

load_email() {
  ensure_state_dir
  if [[ -f "$EMAIL_CONF" ]]; then
    # shellcheck disable=SC1090
    . "$EMAIL_CONF"
  fi
}

save_email() {
  local email="$1"
  ensure_state_dir
  cat > "$EMAIL_CONF" <<EOF
ACME_EMAIL="${email}"
EOF
  info "邮箱已保存到：${EMAIL_CONF}"
}

ensure_acme_installed() {
  local install_script=""

  if [[ -x "$HOME/.acme.sh/acme.sh" ]]; then
    return 0
  fi

  note "未检测到 acme.sh，开始安装..."

  install_script="$(mktemp /tmp/acme-install-XXXXXX)"
  if ! curl -fsSL https://get.acme.sh -o "$install_script"; then
    cleanup_tmp_file "$install_script"
    error "acme.sh 安装脚本下载失败，请稍后重试。"
    return 1
  fi

  if ! sh "$install_script"; then
    cleanup_tmp_file "$install_script"
    error "acme.sh 安装脚本执行失败。"
    return 1
  fi

  cleanup_tmp_file "$install_script"

  if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then
    error "acme.sh 安装失败。"
    return 1
  fi
  info "acme.sh 安装成功。"
}

ensure_acme_cron() {
  local cron_line
  cron_line="0 3 1 */2 * $HOME/.acme.sh/acme.sh --cron --home $HOME/.acme.sh >/dev/null"

  if crontab -l 2>/dev/null | grep -q 'acme.sh --cron'; then
    info "已检测到 acme.sh 自动续期任务（crontab）。"
    return 0
  fi

  # Alpine dcron: try periodic script as fallback
  if check_cmd dcron || [[ -d /etc/periodic ]]; then
    local periodic_script="/etc/periodic/monthly/acme-renew"
    if [[ -f "$periodic_script" ]]; then
      info "已检测到 acme.sh 自动续期任务（dcron periodic）。"
      return 0
    fi
    warn "未检测到 acme.sh 自动续期任务。"
    if confirm "是否一键添加自动续期任务（每月执行）？"; then
      ${SUDO} mkdir -p /etc/periodic/monthly
      ${SUDO} tee "$periodic_script" >/dev/null <<EOF
#!/bin/sh
$HOME/.acme.sh/acme.sh --cron --home $HOME/.acme.sh >/dev/null
EOF
      ${SUDO} chmod +x "$periodic_script"
      info "已添加 acme.sh 自动续期任务（/etc/periodic/monthly/acme-renew）。"
    else
      warn "你选择了不添加自动续期任务，后续需手动续期。"
    fi
    return 0
  fi

  # Standard crontab
  warn "未检测到 acme.sh 自动续期任务。"
  if confirm "是否一键添加自动续期任务（约每60天执行）？"; then
    (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
    info "已开启自动续期任务。"
  else
    warn "你选择了不添加自动续期任务，后续需手动续期。"
  fi
}

has_acme_cron_task() {
  crontab -l 2>/dev/null | grep -q 'acme.sh --cron' || \
    [[ -f /etc/periodic/monthly/acme-renew ]]
}

disable_acme_cron() {
  if crontab -l 2>/dev/null | grep -q 'acme.sh --cron'; then
    crontab -l 2>/dev/null | grep -v 'acme.sh --cron' | crontab - || true
    info "已关闭 crontab 自动续期任务。"
  fi
  if [[ -f /etc/periodic/monthly/acme-renew ]]; then
    ${SUDO} rm -f /etc/periodic/monthly/acme-renew
    info "已关闭 dcron periodic 自动续期任务。"
  fi
  if ! has_acme_cron_task; then
    :
  else
    warn "当前未检测到自动续期任务。"
  fi
}

enable_acme_cron() {
  ensure_acme_cron
}

set_acme_email() {
  local email
  read -rp "请输入证书通知邮箱: " email
  if [[ ! "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    error "邮箱格式不合法。请输入类似 user@example.com 的邮箱地址。"
    return 1
  fi
  save_email "$email"
}

ensure_email_interactive() {
  # 若未设置邮箱，允许在当前界面直接录入并保存
  load_email
  if [[ -n "${ACME_EMAIL:-}" ]]; then
    return 0
  fi

  warn "当前未设置 Acme 邮箱。"
  read -rp "请输入邮箱（将保存到 ${EMAIL_CONF}）: " email
  if [[ ! "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    error "邮箱格式不合法。请输入类似 user@example.com 的邮箱地址。"
    return 1
  fi

  save_email "$email"
  # shellcheck disable=SC2034
  ACME_EMAIL="$email"
}

ensure_acme_location_for_domain_conf() {
  # 为已存在的反代配置补齐 ACME 验证 location，避免申请证书时被反代到后端
  local domain="$1"
  local -a matches
  local conf_file tmp_file

  # Collect tmp files so early-return / errors won't leak /tmp files
  local -a tmp_files=()
  trap 'for f in "${tmp_files[@]}"; do rm -f "$f" 2>/dev/null || true; done' RETURN

  # Primary: match our metadata line "# domain=<domain>"
  mapfile -t matches < <(awk -v d="$domain" 'FNR==1{found=0} $0=="# domain=" d {found=1} ENDFILE{if(found) print FILENAME}' "${CONF_DIR}"/*.conf 2>/dev/null || true)

  # Fallback: match server_name token containing the domain (best-effort, avoids missing metadata)
  if [[ ${#matches[@]} -eq 0 ]]; then
    mapfile -t matches < <(awk -v d="$domain" '
      BEGIN{in_server=0; hasDomain=0}
      /server\s*\{/ {in_server=1; hasDomain=0}
      in_server && index($0, "server_name") {
        # Exact token match: server_name a b c;
        line=$0
        sub(/.*server_name[[:space:]]+/, "", line)
        gsub(/;/, "", line)
        n=split(line, a, /[[:space:]]+/)
        for (i=1; i<=n; i++) {
          if (a[i] == d) {hasDomain=1}
        }
      }
      in_server && /}/ {
        if (hasDomain) {print FILENAME; nextfile}
        in_server=0
      }
    ' "${CONF_DIR}"/*.conf 2>/dev/null || true)
  fi
  [[ ${#matches[@]} -gt 0 ]] || return 0

  for conf_file in "${matches[@]}"; do
    if grep -q '/\.well-known/acme-challenge/' "$conf_file"; then
      continue
    fi

    tmp_file="$(mktemp /tmp/nginxx-acme-loc-"${domain}"-XXXXXX)"
    tmp_files+=("$tmp_file")
    awk '
      BEGIN{inserted=0}
      {
        if (inserted==0 && $0 ~ /^[[:space:]]*location \/ \{/ ) {
          print "    # ACME HTTP-01 验证路径（证书申请/续期）"
          print "    location ^~ /.well-known/acme-challenge/ {"
          print "        root /usr/share/nginx/html;"
          print "        default_type \"text/plain\";"
          print "        try_files $uri =404;"
          print "    }"
          print ""
          inserted=1
        }
        print $0
      }
    ' "$conf_file" > "$tmp_file"

    ${SUDO} cp -a "$tmp_file" "$conf_file"
    rm -f "$tmp_file"
  done
}

ensure_http_challenge_server() {
  # 为“非80端口业务配置”补一个临时 80 验证入口，保证 HTTP-01 可达
  local domain="$1"
  local challenge_conf="${CONF_DIR}/acme-challenge-${domain}.conf"

  # 检测是否已存在“同域名 + 80监听”的配置
  if awk -v d="$domain" '
    BEGIN{in_server=0; has80=0; hasDomain=0}
    /server\s*\{/ {in_server=1; has80=0; hasDomain=0}
    in_server && /listen[[:space:]]+80([[:space:]]|;)/ {has80=1}
    in_server && index($0, "server_name") && index($0, d) {hasDomain=1}
    in_server && /}/ {
      if (has80 && hasDomain) {print "yes"; exit 0}
      in_server=0
    }
  ' "${CONF_DIR}"/*.conf 2>/dev/null | grep -q yes; then
    echo ""
    return 0
  fi

  local tmp_challenge
  tmp_challenge="$(mktemp /tmp/.acme-challenge-"${domain}"-XXXXXX)"
  trap 'rm -f "${tmp_challenge:-}"' RETURN

  cat > "$tmp_challenge" <<EOF
server {
    listen 80;
    server_name ${domain};

    location ^~ /.well-known/acme-challenge/ {
        root /usr/share/nginx/html;
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 404;
    }
}
EOF

  ${SUDO} cp -a "$tmp_challenge" "$challenge_conf"
  rm -f "$tmp_challenge"
  echo "$challenge_conf"
}

cleanup_http_challenge_server() {
  local challenge_conf="$1"
  [[ -z "$challenge_conf" ]] && return 0
  ${SUDO} rm -f "$challenge_conf" 2>/dev/null || true
}

precheck_http01() {
  # 证书申请前自检：DNS、80监听、challenge本地命中、域名回环可达
  # 返回码：0=通过，10=软失败(可继续)，11=硬失败(不建议继续)
  local domain="$1"
  local token file_path local_url domain_url local_body domain_body

  note "开始执行 HTTP-01 申请前自检..."

  # 1) DNS 解析检查
  local dns_out
  dns_out="$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
  if [[ -z "$dns_out" ]]; then
    error "自检失败：域名 ${domain} 未解析到任何 IP。"
    return 11
  fi
  info "DNS解析：${dns_out}"

  # 2) 本机80监听检查
  if ! ss -lnt | awk 'NR>1{print $4}' | grep -qE '(^|:)80$'; then
    error "自检失败：本机未监听 80 端口。"
    return 11
  fi

  # 3) challenge 文件本地命中检查
  token="nginxx-check-$(date +%s)-$RANDOM"
  file_path="/usr/share/nginx/html/.well-known/acme-challenge/${token}"
  ${SUDO} mkdir -p "$(dirname "$file_path")"
  echo "$token" | ${SUDO} tee "$file_path" >/dev/null

  local_url="http://127.0.0.1/.well-known/acme-challenge/${token}"
  local_body="$(curl -fsS --max-time 8 -H "Host: ${domain}" "$local_url" 2>/dev/null || true)"
  if [[ "$local_body" != "$token" ]]; then
    ${SUDO} rm -f "$file_path" 2>/dev/null || true
    error "自检失败：本机 challenge 路径未命中（${local_url}，Host: ${domain}）。"
    return 11
  fi

  # 4) 域名回环可达检查（模拟 CA 通过域名访问 80）
  domain_url="http://${domain}/.well-known/acme-challenge/${token}"
  domain_body="$(curl -fsS --max-time 10 "$domain_url" 2>/dev/null || true)"
  ${SUDO} rm -f "$file_path" 2>/dev/null || true

  if [[ "$domain_body" != "$token" ]]; then
    warn "自检警告：域名 ${domain} 的 80 回源不可达或返回内容不匹配。"
    warn "这可能是网络/回环差异导致的误判。"
    warn "请检查云安全组/防火墙/NAT/CDN 对 80 端口的放行。"
    return 10
  fi

  info "HTTP-01 自检通过。"
  return 0
}

issue_cert() {
  local domain cert_mode
  load_email

  if [[ -z "${ACME_EMAIL:-}" ]]; then
    error "未设置邮箱。请先在证书管理里执行 [1) 设置邮箱]。"
    return 1
  fi

  read -rp "请输入要申请证书的域名: " domain
  if ! valid_domain "$domain"; then
    error "域名格式不合法。请输入可签发证书的域名，例如 example.com。"
    return 1
  fi

  cert_mode="$(select_cert_mode_interactive)"

  if [[ "$cert_mode" == "dns" ]]; then
    _issue_cert_dns "$domain"
  else
    _issue_cert_http "$domain"
  fi
}

issue_cert_for_domain() {
  local domain="$1"
  local cert_mode="${2:-}"
  load_email

  if [[ -z "${ACME_EMAIL:-}" ]]; then
    error "未设置邮箱，无法自动申请证书。请先在证书管理里设置邮箱。"
    return 1
  fi

  if [[ -z "$cert_mode" ]]; then
    cert_mode="$(detect_cert_mode)"
  fi

  if [[ "$cert_mode" == "dns" ]]; then
    if ! has_dns_config; then
      error "DNS-01 需要配置 DNS API Token，请先设置。"
      return 1
    fi
    info "使用 DNS-01 方式为 ${domain} 申请证书..."
    _issue_cert_dns "$domain"
  else
    _issue_cert_http "$domain"
  fi
}

cert_list_action_menu() {
  local domain="$1"
  while true; do
    clear
    echo "====== 证书操作：${domain} ======"
    echo "1) 重新申请"
    echo "2) 启停续期"
    echo "3) 删除证书"
    echo "0) 返回上一级"
    echo "============================="
    read -rp "请选择: " c

    case "$c" in
      1)
        load_email
        if [[ -z "${ACME_EMAIL:-}" ]]; then
          if ! ensure_email_interactive; then
            error "邮箱未设置，无法重新申请。"
            pause
            return 0
          fi
        fi
        run_menu_action issue_cert_for_domain "$domain"
        pause
        return 0
        ;;
      2)
        if has_acme_cron_task; then
          if confirm "当前续期任务已开启，是否关闭？"; then
            disable_acme_cron
          fi
        else
          if confirm "当前续期任务未开启，是否开启？"; then
            enable_acme_cron
          fi
        fi
        pause
        return 0
        ;;
      3)
        local -a refs
        mapfile -t refs < <(cert_referenced_confs "$domain")
        if [[ ${#refs[@]} -gt 0 ]]; then
          warn "证书 ${domain} 仍被以下 Nginx 配置引用，已拒绝删除："
          local ref
          for ref in "${refs[@]}"; do
            warn "  - ${ref}"
          done
          warn "请先停用对应站点 HTTPS 或手动移除证书引用，再删除证书。"
          pause
          return 0
        fi

        if ! confirm "确认删除证书 ${domain} ?"; then
          info "已取消。"
          pause
          return 0
        fi

        local ssl_backup="" acme_backup="" acme_ecc_backup=""
        ssl_backup="$(mktemp -d /tmp/nginxx-cert-"${domain}"-XXXXXX)"
        if [[ -d "${SSL_DIR}/${domain}" ]]; then
          ${SUDO} cp -a "${SSL_DIR}/${domain}" "${ssl_backup}/ssl" 2>/dev/null || true
        fi
        if [[ -d "$HOME/.acme.sh/${domain}" ]]; then
          acme_backup="${ssl_backup}/acme"
          cp -a "$HOME/.acme.sh/${domain}" "$acme_backup" 2>/dev/null || true
        fi
        if [[ -d "$HOME/.acme.sh/${domain}_ecc" ]]; then
          acme_ecc_backup="${ssl_backup}/acme_ecc"
          cp -a "$HOME/.acme.sh/${domain}_ecc" "$acme_ecc_backup" 2>/dev/null || true
        fi

        if [[ -x "$HOME/.acme.sh/acme.sh" ]]; then
          "$HOME/.acme.sh/acme.sh" --remove -d "$domain" >/dev/null 2>&1 || true
        fi
        rm -rf "$HOME/.acme.sh/${domain}" "$HOME/.acme.sh/${domain}_ecc" 2>/dev/null || true
        ${SUDO} rm -rf "${SSL_DIR}/${domain}" 2>/dev/null || true

        if ! nginx_test; then
          warn "删除证书后 nginx -t 失败，正在恢复证书文件。"
          if [[ -d "${ssl_backup}/ssl" ]]; then
            ${SUDO} mkdir -p "$SSL_DIR"
            ${SUDO} cp -a "${ssl_backup}/ssl" "${SSL_DIR}/${domain}"
          fi
          if [[ -n "$acme_backup" && -d "$acme_backup" ]]; then
            mkdir -p "$HOME/.acme.sh"
            cp -a "$acme_backup" "$HOME/.acme.sh/${domain}" 2>/dev/null || true
          fi
          if [[ -n "$acme_ecc_backup" && -d "$acme_ecc_backup" ]]; then
            mkdir -p "$HOME/.acme.sh"
            cp -a "$acme_ecc_backup" "$HOME/.acme.sh/${domain}_ecc" 2>/dev/null || true
          fi
          rm -rf "$ssl_backup" 2>/dev/null || true
          error "证书删除已回滚。请检查 nginx -t 输出后重试。"
          ${SUDO} nginx -t || true
          pause
          return 1
        fi

        rm -rf "$ssl_backup" 2>/dev/null || true
        info "证书已删除：${domain}"
        pause
        return 0
        ;;
      0) return 0 ;;
      *) warn "无效输入。请输入 0-3 之间的菜单编号。"; pause ;;
    esac
  done
}

cert_list_menu() {
  if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then
    warn "未检测到 acme.sh，请先申请证书。"
    pause
    return 0
  fi

  local -a certs
  local domain idx renew_status
  mapfile -t certs < <(
    "$HOME/.acme.sh/acme.sh" --list 2>/dev/null | awk 'NR>1 && NF>0 {print $1}'
  )

  if [[ ${#certs[@]} -eq 0 ]]; then
    warn "当前未发现已签发证书。你可以先去 [2) 申请证书]。"
    return 0
  fi

  while true; do
    clear
    echo "========== 证书列表 =========="
    if has_acme_cron_task; then
      renew_status="已开启"
    else
      renew_status="未开启"
    fi

    for i in "${!certs[@]}"; do
      echo "$((i+1))) ${certs[$i]}  [续期任务: ${renew_status}]"
    done
    echo "0) 返回上一级"
    echo "============================"
    read -rp "请输入证书编号: " idx

    if [[ "$idx" == "0" ]]; then
      return 0
    fi
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#certs[@]} )); then
      warn "无效编号。请输入证书列表中存在的编号。"
      pause
      continue
    fi

    domain="${certs[$((idx-1))]}"
    cert_list_action_menu "$domain"

    # 操作后刷新证书列表
    mapfile -t certs < <(
      "$HOME/.acme.sh/acme.sh" --list 2>/dev/null | awk 'NR>1 && NF>0 {print $1}'
    )
    if [[ ${#certs[@]} -eq 0 ]]; then
      warn "当前已无证书。"
      pause
      return 0
    fi
  done
}

enable_https_for_domain() {
  enable_https_from_config_list
}

extract_domain_from_conf() {
  local conf_file="$1"
  local d
  d="$(grep -E '^# domain=' "$conf_file" 2>/dev/null | head -n1 | sed 's/^# domain=//')"
  if [[ -z "$d" ]]; then
    # 回退：用文件名去掉 -端口.conf
    d="$(basename "$conf_file" | sed -E 's/-[0-9]+\.conf$//; s/\.conf$//')"
  fi
  echo "$d"
}

conf_https_enabled() {
  local conf_file="$1"
  grep -q '^# https_enabled=true' "$conf_file" 2>/dev/null || grep -qE 'listen[[:space:]]+[0-9]+[[:space:]]+ssl' "$conf_file" 2>/dev/null
}

health_probe_url() {
  local url="$1"
  local insecure="${2:-0}"
  local curl_args=(-sS -o /dev/null --connect-timeout 8 --max-time 15 -L -w '%{http_code}|%{remote_ip}|%{url_effective}|%{ssl_verify_result}')
  local out=""

  if [[ "$insecure" == "1" ]]; then
    curl_args=(-k "${curl_args[@]}")
  fi

  out="$(curl "${curl_args[@]}" "$url" 2>/dev/null || true)"
  [[ -z "$out" ]] && out="000|||"
  echo "$out"
}

health_check_conf_file() {
  local conf_file="$1"
  local domain listen_port mode upstream_url stream_upstream_url stream_upstream_urls
  local scheme target_url status_label http_code remote_ip dns_ips tls_days verify_result effective_url
  local upstream_http_code upstream_verify_result upstream_status
  local stream_http_code stream_verify_result stream_status
  local -a stream_urls=()
  local idx prefix
  local status_ok=0

  domain="$(extract_domain_from_conf "$conf_file")"
  listen_port="$(conf_meta_get "$conf_file" listen_port)"
  mode="$(conf_meta_get "$conf_file" mode)"
  upstream_url="$(conf_meta_get "$conf_file" upstream_url)"
  stream_upstream_url="$(conf_meta_get "$conf_file" stream_upstream_url)"
  stream_upstream_urls="$(conf_meta_get "$conf_file" stream_upstream_urls)"
  [[ -z "$listen_port" ]] && listen_port="80"

  if conf_https_enabled "$conf_file"; then
    scheme="https"
  else
    scheme="http"
  fi

  if [[ "$listen_port" == "80" && "$scheme" == "http" ]]; then
    target_url="http://${domain}"
  elif [[ "$listen_port" == "443" && "$scheme" == "https" ]]; then
    target_url="https://${domain}"
  else
    target_url="${scheme}://${domain}:${listen_port}"
  fi

  dns_ips="$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd ',' - || true)"
  [[ -z "$dns_ips" ]] && dns_ips="未解析"

  IFS='|' read -r http_code remote_ip effective_url verify_result <<< "$(health_probe_url "$target_url" 0)"
  [[ -z "$http_code" ]] && http_code="000"

  if [[ "$scheme" == "https" ]]; then
    # shellcheck disable=SC2016
    tls_days="$(timeout 8s bash -c 'echo | openssl s_client -servername "$0" -connect "$0:$1" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null' "$domain" "$listen_port" | sed 's/notAfter=//' | xargs -I{} date -d '{}' +%s 2>/dev/null | awk -v now="$(date +%s)" '{if($1>0) printf "%d", int(($1-now)/86400); else print "-"}' || true)"
    [[ -z "$tls_days" ]] && tls_days="-"
  else
    tls_days="-"
    verify_result="0"
  fi

  if [[ "$http_code" =~ ^[23] ]]; then
    status_label="正常"
    status_ok=0
  elif [[ "$scheme" == "https" && "$verify_result" != "0" ]]; then
    status_label="证书校验失败"
    status_ok=2
  elif [[ "$http_code" =~ ^(401|403|404)$ ]]; then
    status_label="可访问但需确认"
    status_ok=1
  else
    status_label="异常"
    status_ok=2
  fi

  upstream_status="-"
  if [[ -n "$upstream_url" ]]; then
    IFS='|' read -r upstream_http_code _ _ upstream_verify_result <<< "$(health_probe_url "$upstream_url" 0)"
    if [[ "$upstream_http_code" =~ ^[23] ]]; then
      upstream_status="正常"
    elif [[ "$(url_scheme "$upstream_url")" == "https" && "$upstream_verify_result" != "0" ]]; then
      upstream_status="证书校验失败"
      (( status_ok < 1 )) && status_ok=1
    else
      upstream_status="异常(${upstream_http_code})"
      (( status_ok < 1 )) && status_ok=1
    fi
  fi

  if [[ -n "$stream_upstream_urls" ]]; then
    stream_urls_to_array "$stream_upstream_urls" stream_urls
  elif [[ -n "$stream_upstream_url" ]]; then
    stream_urls=("$stream_upstream_url")
  fi

  stream_status="-"
  if [[ ${#stream_urls[@]} -gt 0 ]]; then
    stream_status=""
    for idx in "${!stream_urls[@]}"; do
      stream_upstream_url="${stream_urls[$idx]}"
      IFS='|' read -r stream_http_code _ _ stream_verify_result <<< "$(health_probe_url "$stream_upstream_url" 0)"
      prefix=""
      [[ -n "$stream_status" ]] && prefix=" | "
      if [[ "$stream_http_code" =~ ^[23] ]]; then
        stream_status+="${prefix}正常"
      elif [[ "$(url_scheme "$stream_upstream_url")" == "https" && "$stream_verify_result" != "0" ]]; then
        stream_status+="${prefix}证书校验失败"
        (( status_ok < 1 )) && status_ok=1
      else
        stream_status+="${prefix}异常(${stream_http_code})"
        (( status_ok < 1 )) && status_ok=1
      fi
    done
  fi

  echo "- $(basename "$conf_file")"
  echo "  域名: ${domain}"
  echo "  入口: ${target_url}"
  echo "  协议: ${scheme^^} | HTTP: ${http_code} | 状态: ${status_label}"
  echo "  DNS: ${dns_ips}"
  [[ -n "$remote_ip" ]] && echo "  命中IP: ${remote_ip}"
  [[ -n "$effective_url" && "$effective_url" != "$target_url" ]] && echo "  最终跳转: ${effective_url}"
  if [[ "$scheme" == "https" ]]; then
    echo "  证书剩余天数: ${tls_days}"
    echo "  证书校验: $( [[ "$verify_result" == "0" ]] && echo "通过" || echo "失败(${verify_result})" )"
  fi
  if [[ "$mode" == "external" ]]; then
    echo "  主上游: ${upstream_url}"
    echo "  主上游状态: ${upstream_status}"
    if [[ ${#stream_urls[@]} -gt 0 ]]; then
      if [[ ${#stream_urls[@]} -eq 1 ]]; then
        echo "  推流上游: ${stream_urls[0]}"
      else
        echo "  推流上游: ${stream_urls[*]}"
      fi
      echo "  推流上游状态: ${stream_status}"
    fi
  else
    echo "  后端端口: $(conf_meta_get "$conf_file" backend_port)"
  fi
  echo

  return $status_ok
}

site_health_menu() {
  local -a confs
  local idx conf_file bad=0 total=0

  require_nginx_installed || return 1

  while true; do
    clear
    echo "========== 健康检查 =========="
    echo "1) 检查所有站点"
    echo "2) 检查单个站点"
    echo "0) 返回上一级"
    echo "================================="
    read -rp "请选择: " c

    case "$c" in
      1)
        clear
        mapfile -t confs < <(list_managed_conf_files 0)
        if [[ ${#confs[@]} -eq 0 ]]; then
          warn "当前没有可检查的站点配置。请先创建站点。"
          pause
          continue
        fi
        bad=0
        total=0
        for conf_file in "${confs[@]}"; do
          total=$((total+1))
          if ! health_check_conf_file "$conf_file"; then
            bad=$((bad+1))
          fi
        done
        if (( bad == 0 )); then
          info "检查完成：${total} 个站点全部正常。"
        else
          warn "检查完成：${total} 个站点中有 ${bad} 个异常，请根据上面的 HTTP 状态码、DNS 和证书信息排查。"
          warn "最终效果仍请结合浏览器或客户端实际访问情况人工核查。"
        fi
        pause
        ;;
      2)
        clear
        mapfile -t confs < <(list_managed_conf_files 0)
        if [[ ${#confs[@]} -eq 0 ]]; then
          warn "当前没有可检查的站点配置。请先创建站点。"
          pause
          continue
        fi
        echo "请选择要检查的站点："
        for i in "${!confs[@]}"; do
          echo "  $((i+1))) $(basename "${confs[$i]}")  [域名: $(extract_domain_from_conf "${confs[$i]}")]"
        done
        echo "  0) 返回上一级"
        read -rp "选择序号: " idx
        if [[ "$idx" == "0" ]]; then
          continue
        fi
        if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#confs[@]} )); then
          warn "无效序号。请输入列表中存在的配置编号。"
          pause
          continue
        fi
        clear
        health_check_conf_file "${confs[$((idx-1))]}" || true
        pause
        ;;
      0) return 0 ;;
      *) warn "无效输入。请输入 0-2 之间的菜单编号。"; pause ;;
    esac
  done
}

disable_https_for_conf_file() {
  local domain="$1"
  local conf_file="$2"
  local mode external_mode upstream_url stream_upstream_url source_site_url referer_url
  local stream_upstream_urls
  local listen_port existing_upstream host_header ssl_sni_line stream_mode stream_block tmp

  ensure_websocket_map

  require_template_rebuild_safe "$conf_file" "停用 HTTPS" || return 1

  mode="$(conf_meta_get "$conf_file" mode)"
  if [[ "$mode" == "external" ]]; then
    listen_port="$(conf_meta_get "$conf_file" listen_port)"
    [[ -z "$listen_port" ]] && listen_port="80"
    external_mode="$(conf_meta_get "$conf_file" external_mode)"
    upstream_url="$(conf_meta_get "$conf_file" upstream_url)"
    stream_upstream_url="$(conf_meta_get "$conf_file" stream_upstream_url)"
    stream_upstream_urls="$(conf_meta_get "$conf_file" stream_upstream_urls)"
    source_site_url="$(conf_meta_get "$conf_file" source_site_url)"
    referer_url="$(conf_meta_get "$conf_file" referer_url)"
    [[ -z "$external_mode" ]] && external_mode="normal"

    tmp="$(mktemp /tmp/nginxx-disable-https-"${domain}"-XXXXXX)"
    trap 'rm -f "${tmp:-}"' RETURN
    build_external_proxy_conf "$domain" "$listen_port" "$upstream_url" "$external_mode" "$tmp" "0" "$stream_upstream_url" "$source_site_url" "$referer_url" "$stream_upstream_urls"
    if apply_conf_with_rollback "$tmp" "$conf_file"; then
      info "HTTPS 已停用：$(basename "$conf_file")"
      rm -f "$tmp"
      return 0
    fi

    rm -f "$tmp"
    return 1
  fi

  listen_port="$(conf_meta_get "$conf_file" listen_port)"
  [[ -z "$listen_port" ]] && listen_port="80"

  stream_mode="$(conf_meta_get "$conf_file" stream_mode)"
  stream_block=""
  if [[ "$stream_mode" == "media" ]]; then
    stream_block=$(cat <<'BLOCK'
        # Stream 转发优化（Emby/Jellyfin 等）
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_max_temp_file_size 0;
        send_timeout 3600s;
        client_max_body_size 0;
BLOCK
)
  fi

  existing_upstream="$(grep -Eo 'proxy_pass [^;]+' "$conf_file" | head -n1 | sed 's/^proxy_pass //')"
  [[ -z "$existing_upstream" ]] && existing_upstream="http://127.0.0.1:3000"

  if [[ "$existing_upstream" =~ ^https?://127\.0\.0\.1(:[0-9]+)?(/|$) ]]; then
    # shellcheck disable=SC2016
    host_header='$host'
    ssl_sni_line=''
  else
    # shellcheck disable=SC2016
    host_header='$proxy_host'
    if [[ "$existing_upstream" =~ ^https:// ]]; then
      ssl_sni_line='        proxy_ssl_server_name on;'
    else
      ssl_sni_line=''
    fi
  fi

  tmp="$(mktemp /tmp/nginxx-disable-https-"${domain}"-XXXXXX)"
  trap 'rm -f "${tmp:-}"' RETURN
  cat > "$tmp" <<EOF
# managed_by=Nginx-X
# domain=${domain}
# listen_port=${listen_port}
# stream_mode=${stream_mode:-normal}

server {
    listen ${listen_port};
    server_name ${domain};

    # ACME HTTP-01 验证路径（证书申请/续期）
    location ^~ /.well-known/acme-challenge/ {
        root /usr/share/nginx/html;
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        proxy_pass ${existing_upstream};
        proxy_http_version 1.1;

${stream_block}

${ssl_sni_line}

        proxy_set_header Host ${host_header};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

  if apply_conf_with_rollback "$tmp" "$conf_file"; then
    info "HTTPS 已停用：$(basename "$conf_file")"
    rm -f "$tmp"
    return 0
  fi

  rm -f "$tmp"
  return 1
}

enable_https_from_config_list() {
  local -a confs
  local idx conf_file domain

  mapfile -t confs < <(list_managed_conf_files 0)
  if [[ ${#confs[@]} -eq 0 ]]; then
    warn "未找到可启用 HTTPS 的配置文件。"
    return 1
  fi

  echo "请选择要启用证书的配置："
  for i in "${!confs[@]}"; do
    domain="$(extract_domain_from_conf "${confs[$i]}")"
    echo "  $((i+1))) $(basename "${confs[$i]}")  [域名: ${domain}]"
  done
  echo "  0) 返回上一级"
  read -rp "选择序号: " idx

  if [[ "$idx" == "0" ]]; then
    return 0
  fi
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#confs[@]} )); then
    error "无效序号。请输入列表中存在的配置编号。"
    return 1
  fi

  conf_file="${confs[$((idx-1))]}"
  domain="$(extract_domain_from_conf "$conf_file")"

  note "已选择配置：$(basename "$conf_file")"

  if conf_https_enabled "$conf_file"; then
    warn "当前配置已启用 HTTPS：$(basename "$conf_file")"
    if confirm "是否停用 HTTPS？"; then
      if disable_https_for_conf_file "$domain" "$conf_file"; then
        info "操作完成：HTTPS 已停用。"
      else
        error "操作失败：停用 HTTPS 未成功。请检查 nginx -t 输出。"
      fi
    else
      info "已取消停用 HTTPS。"
    fi
    return 0
  fi

  if ! confirm "当前配置未启用 HTTPS，是否立即启用？"; then
    info "已取消启用 HTTPS。"
    return 0
  fi

  if [[ ! -f "${SSL_DIR}/${domain}/fullchain.pem" || ! -f "${SSL_DIR}/${domain}/privkey.pem" ]]; then
    warn "检测到域名 ${domain} 还没有可用证书，准备自动申请。"

    if ! ensure_email_interactive; then
      error "邮箱未设置，无法自动申请证书。"
      return 1
    fi

    local selected_cert_mode
    selected_cert_mode="$(select_cert_mode_interactive)"
    if ! issue_cert_for_domain "$domain" "$selected_cert_mode"; then
      error "证书申请失败，无法继续启用 HTTPS。请检查域名解析、端口放行或 DNS API 配置。"
      return 1
    fi
  fi

  if enable_https_for_conf_file "$domain" "$conf_file"; then
    info "操作完成：HTTPS 已启用。"
  else
    error "操作失败：HTTPS 启用未成功。"
    return 1
  fi
}

enable_https_for_domain_value() {
  # 参数：域名（若同域名存在多个配置，将提示选择）
  local domain="$1"
  local -a matches
  local idx conf_file

  mapfile -t matches < <(awk -v d="$domain" 'FNR==1{found=0} $0=="# domain=" d {found=1} ENDFILE{if(found) print FILENAME}' "${CONF_DIR}"/*.conf 2>/dev/null || true)

  if [[ ${#matches[@]} -eq 0 ]]; then
    error "未找到该域名对应配置：${domain}"
    return 1
  elif [[ ${#matches[@]} -eq 1 ]]; then
    conf_file="${matches[0]}"
  else
    echo "检测到多个同域名配置，请选择："
    for i in "${!matches[@]}"; do
      echo "  $((i+1))) $(basename "${matches[$i]}")"
    done
    read -rp "选择序号: " idx
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#matches[@]} )); then
    error "无效序号。请输入列表中存在的配置编号。"
      return 1
    fi
    conf_file="${matches[$((idx-1))]}"
  fi

  enable_https_for_conf_file "$domain" "$conf_file"
}

enable_https_for_conf_file() {
  local domain="$1"
  local conf_file="$2"
  local force_port="${3:-}"
  local mode external_mode upstream_url stream_upstream_url stream_upstream_urls source_site_url referer_url
  local tmp listen_port redirect_suffix stream_mode stream_block effective_https_port

  ensure_websocket_map

  if [[ ! -f "$conf_file" ]]; then
    error "配置文件不存在：${conf_file}"
    return 1
  fi

  require_template_rebuild_safe "$conf_file" "启用 HTTPS" || return 1

  if [[ ! -f "${SSL_DIR}/${domain}/fullchain.pem" || ! -f "${SSL_DIR}/${domain}/privkey.pem" ]]; then
    error "未找到证书文件：${SSL_DIR}/${domain}/"
    return 1
  fi

  # 优先读取配置注释中的监听端口，缺失时回退 443
  listen_port="$(conf_meta_get "$conf_file" listen_port)"
  [[ -n "$force_port" ]] && listen_port="$force_port"
  [[ -z "$listen_port" ]] && listen_port="443"

  effective_https_port="$listen_port"
  if [[ "$effective_https_port" == "80" ]]; then
    effective_https_port="443"
  fi

  mode="$(conf_meta_get "$conf_file" mode)"
  if [[ "$mode" == "external" ]]; then
    external_mode="$(conf_meta_get "$conf_file" external_mode)"
    upstream_url="$(conf_meta_get "$conf_file" upstream_url)"
    stream_upstream_url="$(conf_meta_get "$conf_file" stream_upstream_url)"
    stream_upstream_urls="$(conf_meta_get "$conf_file" stream_upstream_urls)"
    source_site_url="$(conf_meta_get "$conf_file" source_site_url)"
    referer_url="$(conf_meta_get "$conf_file" referer_url)"
    [[ -z "$external_mode" ]] && external_mode="normal"

    tmp="$(mktemp /tmp/nginxx-https-"${domain}"-XXXXXX)"
    trap 'rm -f "${tmp:-}"' RETURN
    build_external_proxy_conf "$domain" "$effective_https_port" "$upstream_url" "$external_mode" "$tmp" "1" "$stream_upstream_url" "$source_site_url" "$referer_url" "$stream_upstream_urls"
    if apply_conf_with_rollback "$tmp" "$conf_file"; then
      info "HTTPS 已启用，且已配置 80 -> ${effective_https_port} 强制跳转。"
      rm -f "$tmp"
      return 0
    fi

    rm -f "$tmp"
    return 1
  fi

  if [[ "$effective_https_port" == "443" ]]; then
    redirect_suffix=""
  else
    redirect_suffix=":${effective_https_port}"
  fi

  stream_mode="$(conf_meta_get "$conf_file" stream_mode)"
  stream_block=""
  if [[ "$stream_mode" == "media" ]]; then
    stream_block=$(cat <<'BLOCK'
        # Stream 转发优化（Emby/Jellyfin 等）
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_max_temp_file_size 0;
        send_timeout 3600s;
        client_max_body_size 0;
BLOCK
)
  fi

  tmp="$(mktemp /tmp/nginxx-https-"${domain}"-XXXXXX)"
  trap 'rm -f "${tmp:-}"' RETURN

  # 复用原配置上游：优先读取注释元数据，避免同端口多域名场景误取到错误上游
  local existing_upstream host_header ssl_sni_line backend_port_meta upstream_url_meta
  upstream_url_meta="$(conf_meta_get "$conf_file" upstream_url)"
  backend_port_meta="$(conf_meta_get "$conf_file" backend_port)"

  if [[ -n "$upstream_url_meta" ]]; then
    existing_upstream="$upstream_url_meta"
  elif [[ -n "$backend_port_meta" ]]; then
    existing_upstream="http://127.0.0.1:${backend_port_meta}"
  else
    existing_upstream="$(grep -Eo 'proxy_pass [^;]+' "$conf_file" | head -n1 | sed 's/^proxy_pass //')"
  fi

  [[ -z "$existing_upstream" ]] && existing_upstream="http://127.0.0.1:3000"

  # 外部上游（尤其 https）需要 SNI 与上游 Host，避免 502/握手失败
  if [[ "$existing_upstream" =~ ^https?://127\.0\.0\.1(:[0-9]+)?(/|$) ]]; then
    # shellcheck disable=SC2016
    host_header='$host'
    ssl_sni_line=''
  else
    # shellcheck disable=SC2016
    host_header='$proxy_host'
    if [[ "$existing_upstream" =~ ^https:// ]]; then
      ssl_sni_line='        proxy_ssl_server_name on;'
    else
      ssl_sni_line=''
    fi
  fi

  # 生成 HTTPS 配置：若原配置监听 80，则自动切到标准 443，避免 80 同时承担重定向与 SSL 监听
  local ipv6_listen_80 ipv6_listen_tls
  ipv6_listen_80="$(nginx_listen_ipv6_line 80 "")"
  ipv6_listen_tls="$(nginx_listen_ipv6_line "$effective_https_port" "ssl http2")"

  cat > "$tmp" <<EOF
# managed_by=Nginx-X
# domain=${domain}
# https_enabled=true
# listen_port=${effective_https_port}
# stream_mode=${stream_mode:-normal}

server {
    listen 80;
${ipv6_listen_80}
    server_name ${domain};

    # 保留 ACME 验证路径，避免被 301 跳转影响签发/续期
    location ^~ /.well-known/acme-challenge/ {
        root /usr/share/nginx/html;
        default_type "text/plain";
        try_files \$uri =404;
    }

    return 301 https://\$host${redirect_suffix}\$request_uri;
}

server {
    listen ${effective_https_port} ssl http2;
${ipv6_listen_tls}
    server_name ${domain};

    ssl_certificate     ${SSL_DIR}/${domain}/fullchain.pem;
    ssl_certificate_key ${SSL_DIR}/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    location / {
        proxy_pass ${existing_upstream};
        proxy_http_version 1.1;

${stream_block}

${ssl_sni_line}

        proxy_set_header Host ${host_header};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

  if apply_conf_with_rollback "$tmp" "$conf_file"; then
    info "HTTPS 已启用，且已配置 80 -> ${effective_https_port} 强制跳转。"
    rm -f "$tmp"
    return 0
  fi

  rm -f "$tmp"
  return 1
}

cert_menu() {
  require_nginx_installed || {
    pause
    return 0
  }

  while true; do
    clear
    echo "========== 证书管理（acme.sh） =========="
    echo "1) 设置邮箱"
    echo "2) 申请证书（HTTP-01）"
    echo "3) 配置 DNS API"
    echo "4) 申请证书（DNS-01）"
    echo "5) 证书列表"
    echo "6) 启用证书（HTTPS 强制跳转）"
    echo "0) 返回上一级"
    echo "========================================"
    read -rp "请选择: " c

    case "$c" in
      1) run_menu_action set_acme_email; pause ;;
      2) run_menu_action issue_cert; pause ;;
      3) run_menu_action setup_dns_api; pause ;;
      4) local dns_domain; load_email; if [[ -z "${ACME_EMAIL:-}" ]]; then error "请先设置邮箱。"; pause; else read -rp "请输入域名: " dns_domain; if valid_domain "$dns_domain"; then _issue_cert_dns "$dns_domain"; fi; pause; fi ;;
      5) cert_list_menu ;;
      6) run_menu_action enable_https_for_domain; pause ;;
      0) return 0 ;;
      *) warn "无效输入。请输入 0-6 之间的菜单编号。"; pause ;;
    esac
  done
}

# ---------- 功能5.5：系统信息 ----------
show_system_info() {
  clear
  echo "================================================"
  echo "              系统信息 - ${APP_NAME}"
  echo "================================================"
  echo ""

  echo "--- 操作系统信息 ---"
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release 2>/dev/null
    echo "  发行版   : ${PRETTY_NAME:-$NAME $VERSION}"
  fi
  echo "  内核     : $(uname -r)"
  echo "  架构     : $(uname -m)"
  echo "  运行时间 : $(uptime -p 2>/dev/null || uptime | sed 's/.*up */up /')"
  echo "  系统 DNS  : $(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf 2>/dev/null | sed 's/ $//')"
  echo ""

  echo "--- Nginx 信息 ---"
  if check_cmd nginx; then
    echo "  版本     : $(nginx -v 2>&1 | sed 's/nginx version: nginx\///')"
    if check_cmd systemctl; then
      echo "  状态     : $(systemctl is-active nginx 2>/dev/null || echo '未知')"
    elif check_cmd rc-service; then
      echo "  状态     : $(rc-service nginx status 2>/dev/null | head -1 || echo '未知')"
    fi
    local conf_count=0
    if [[ -d "$CONF_DIR" ]]; then
      conf_count=$(find "$CONF_DIR" -maxdepth 1 \( -name '*.conf' ! -name '*.conf.bak' ! -name 'acme-challenge-*.conf' ! -name 'nginx_status.conf' ! -name 'default.conf' \) 2>/dev/null | wc -l)
    fi
    echo "  已启用配置 : ${conf_count} 个 (目录: ${CONF_DIR})"
  else
    echo "  状态     : 未安装"
  fi
  echo ""

  echo "--- acme.sh 信息 ---"
  load_email
  if [[ -x "$HOME/.acme.sh/acme.sh" ]]; then
    echo "  acme.sh   : 已安装 ($("$HOME"/.acme.sh/acme.sh --version 2>/dev/null | head -1 || echo '版本未知'))"
    if [[ -n "${ACME_EMAIL:-}" ]]; then
      echo "  邮箱     : ${ACME_EMAIL}"
    else
      echo "  邮箱     : 未设置"
    fi
    local cert_count=0
    cert_count=$("$HOME/.acme.sh/acme.sh" --list 2>/dev/null | awk 'NR>1 && NF>0 {c++} END {print c+0}')
    echo "  证书数   : ${cert_count}"
    if has_acme_cron_task; then
      echo "  自动续期 : 已启用"
    else
      echo "  自动续期 : 未启用"
    fi
  else
    echo "  acme.sh   : 未安装"
    if [[ -n "${ACME_EMAIL:-}" ]]; then
      echo "  邮箱     : ${ACME_EMAIL} (已保存，待安装 acme.sh 后生效)"
    else
      echo "  邮箱     : 未设置"
    fi
  fi
  echo ""

  echo "--- DNS API 信息 ---"
  load_dns_conf
  if [[ -n "${DNS_PROVIDER:-}" ]]; then
    echo "  服务商   : ${DNS_PROVIDER}"
    if [[ -n "${DNS_KEY1:-}" ]]; then
      local masked_key="${DNS_KEY1:0:4}****${DNS_KEY1: -4}"
      echo "  Key1     : ${masked_key}"
    fi
    if [[ -n "${DNS_KEY2:-}" ]]; then
      local masked_key2="${DNS_KEY2:0:4}****${DNS_KEY2: -4}"
      echo "  Key2     : ${masked_key2}"
    fi
  else
    echo "  状态     : 未配置"
  fi

  echo ""
  echo "--- ${APP_NAME} 信息 ---"
  echo "  版本     : ${APP_VERSION}"
  echo "  安装路径 : ${SCRIPT_DIR}"
  echo "================================================"
}

# ---------- 功能6：流量统计与状态 ----------
ensure_status_endpoint() {
  local status_conf="${CONF_DIR}/nginx_status.conf"
  if [[ -f "$status_conf" ]]; then
    return 0
  fi

  local tmp_status
  tmp_status="$(mktemp /tmp/nginxx-status-XXXXXX)"
  trap 'rm -f "${tmp_status:-}"' RETURN

  cat > "$tmp_status" <<'EOF'
server {
    listen 127.0.0.1:8088;
    server_name 127.0.0.1;

    location /nginx_status {
        stub_status;
        allow 127.0.0.1;
        deny all;
    }
}
EOF

  apply_conf_with_rollback "$tmp_status" "$status_conf" || {
    rm -f "$tmp_status"
    return 1
  }
  rm -f "$tmp_status"
}

show_nginx_realtime_status() {
  require_nginx_installed || return 1

  ensure_status_endpoint || true

  local prev_requests=0 prev_rx=0 prev_tx=0 initialized=0

  while true; do
    local stat active reading writing waiting accepts handled requests qps
    local cpu mem workers master_pid start_time rx tx rx_rate tx_rate

    stat="$(curl -fsS http://127.0.0.1:8088/nginx_status 2>/dev/null || true)"

    active="N/A"
    reading="N/A"
    writing="N/A"
    waiting="N/A"
    accepts="N/A"
    handled="N/A"
    requests="0"
    qps="0"

    if [[ -n "$stat" ]]; then
      active="$(echo "$stat" | awk '/Active connections/ {print $3}')"
      accepts="$(echo "$stat" | awk 'NR==3 {print $1}')"
      handled="$(echo "$stat" | awk 'NR==3 {print $2}')"
      requests="$(echo "$stat" | awk 'NR==3 {print $3}')"
      reading="$(echo "$stat" | awk 'NR==4 {print $2}')"
      writing="$(echo "$stat" | awk 'NR==4 {print $4}')"
      waiting="$(echo "$stat" | awk 'NR==4 {print $6}')"
    fi

    if [[ $initialized -eq 1 ]]; then
      qps=$((requests - prev_requests))
      (( qps < 0 )) && qps=0
    fi

    cpu="$(ps -C nginx -o %cpu= 2>/dev/null | awk '{s+=$1} END {if(NR==0) print "0.0"; else printf "%.1f", s}')"
    mem="$(ps -C nginx -o %mem= 2>/dev/null | awk '{s+=$1} END {if(NR==0) print "0.0"; else printf "%.1f", s}')"

    workers="$(pgrep -fc 'nginx: worker process' 2>/dev/null || echo 0)"
    master_pid="$(pgrep -xo nginx 2>/dev/null || true)"
    if [[ -n "$master_pid" ]]; then
      start_time="$(ps -p "$master_pid" -o lstart= 2>/dev/null | awk '{$1=$1;print}')"
    else
      start_time="N/A"
    fi

    # Strip leading whitespace so $1 is always the interface name
    rx="$(sed 's/^[[:space:]]*//' /proc/net/dev 2>/dev/null | awk -F'[: ]+' 'NR>2 && $1!="lo" {s+=$2} END{print s+0}')"
    tx="$(sed 's/^[[:space:]]*//' /proc/net/dev 2>/dev/null | awk -F'[: ]+' 'NR>2 && $1!="lo" {s+=$10} END{print s+0}')"

    if [[ $initialized -eq 1 ]]; then
      rx_rate="$(awk -v d=$((rx-prev_rx)) 'BEGIN{if(d<0)d=0; printf "%.1f", d/1024/1024}')"
      tx_rate="$(awk -v d=$((tx-prev_tx)) 'BEGIN{if(d<0)d=0; printf "%.1f", d/1024/1024}')"
    else
      rx_rate="0.0"
      tx_rate="0.0"
      initialized=1
    fi

    prev_requests="$requests"
    prev_rx="$rx"
    prev_tx="$tx"

    clear
    cat <<EOF
==============================
 Nginx 实时状态
==============================

连接状态
Active: ${active}
Reading: ${reading}
Writing: ${writing}
Waiting: ${waiting}

请求统计
Accepts: ${accepts}
Handled: ${handled}
Requests: ${requests}
QPS: ${qps} req/s

系统资源
CPU: ${cpu} %
MEM: ${mem} %

Nginx信息
Worker进程: ${workers}
启动时间: ${start_time}

网络流量
RX: ${rx_rate} MB/s
TX: ${tx_rate} MB/s

==============================
按回车返回（每5秒自动刷新）
EOF

    # 每5秒刷新；检测到任意键输入则退出
    if read -r -s -n 1 -t 5 _key; then
      break
    fi
  done
}

show_traffic_stats() {
  require_nginx_installed || return 1

  local log_file="/var/log/nginx/access.log"
  local host_log_file="/var/log/nginx/access.host.log"
  local prev_rx=0 prev_tx=0 initialized=0

  while true; do
    local rx tx rx_rate tx_rate rx_total_mb tx_total_mb
    # Strip leading whitespace so $1 is always the interface name
    rx="$(sed 's/^[[:space:]]*//' /proc/net/dev 2>/dev/null | awk -F'[: ]+' 'NR>2 && $1!="lo" {s+=$2} END{print s+0}')"
    tx="$(sed 's/^[[:space:]]*//' /proc/net/dev 2>/dev/null | awk -F'[: ]+' 'NR>2 && $1!="lo" {s+=$10} END{print s+0}')"

    if [[ $initialized -eq 1 ]]; then
      rx_rate="$(awk -v d=$((rx-prev_rx)) 'BEGIN{if(d<0)d=0; printf "%.2f", d/1024/1024}')"
      tx_rate="$(awk -v d=$((tx-prev_tx)) 'BEGIN{if(d<0)d=0; printf "%.2f", d/1024/1024}')"
    else
      rx_rate="0.00"
      tx_rate="0.00"
      initialized=1
    fi

    prev_rx="$rx"
    prev_tx="$tx"
    rx_total_mb="$(awk -v b="$rx" 'BEGIN{printf "%.2f", b/1024/1024}')"
    tx_total_mb="$(awk -v b="$tx" 'BEGIN{printf "%.2f", b/1024/1024}')"

    clear
    cat <<EOF
==============================
 流量统计
==============================

总流量（系统网卡）
RX总量: ${rx_total_mb} MB
TX总量: ${tx_total_mb} MB
RX速率: ${rx_rate} MB/s
TX速率: ${tx_rate} MB/s

当前启用配置流量（最近5000日志，优先按 Host 专用日志统计）
EOF

    mapfile -t enabled_confs < <(list_managed_conf_files 0)
    if [[ ${#enabled_confs[@]} -eq 0 ]]; then
      echo "- 无启用配置"
    else
      for conf in "${enabled_confs[@]}"; do
        local domain req_count bytes_sum bytes_mb
        domain="$(extract_domain_from_conf "$conf")"

        if [[ -f "$host_log_file" && -n "$domain" ]]; then
          req_count="$(tail -n 5000 "$host_log_file" 2>/dev/null | awk -v d="$domain" '$1==d {c++} END{print c+0}')"
          bytes_sum="$(tail -n 5000 "$host_log_file" 2>/dev/null | awk -v d="$domain" '$1==d && $2 ~ /^[0-9]+$/ {s+=$2} END{print s+0}')"
        elif [[ -f "$log_file" && -n "$domain" ]]; then
          req_count="$(tail -n 5000 "$log_file" 2>/dev/null | grep -F -c "$domain" || true)"
          bytes_sum="$(tail -n 5000 "$log_file" 2>/dev/null | grep -F "$domain" | awk '{if($10 ~ /^[0-9]+$/) s+=$10} END{print s+0}' || true)"
        else
          req_count="0"
          bytes_sum="0"
        fi

        bytes_mb="$(awk -v b="$bytes_sum" 'BEGIN{printf "%.2f", b/1024/1024}')"
        if [[ -f "$host_log_file" ]]; then
          echo "- $(basename "$conf") | 域名: ${domain} | 请求: ${req_count} | 下行: ${bytes_mb} MB | 来源: host日志"
        else
          echo "- $(basename "$conf") | 域名: ${domain} | 请求: ${req_count} | 下行: ${bytes_mb} MB | 来源: access估算"
        fi
      done
    fi

    cat <<EOF

==============================
按回车返回（每5秒自动刷新）
EOF

    if read -r -s -n 1 -t 5 _key; then
      break
    fi
  done
}

realtime_info_menu() {
  require_nginx_installed || {
    pause
    return 0
  }

  while true; do
    clear
    echo "========== 实时信息 =========="
    echo "1) 实时信息"
    echo "2) 流量统计"
    echo "3) 健康检查"
    echo "0) 返回上一级"
    echo "============================="
    read -rp "请选择: " c

    case "$c" in
      1) show_nginx_realtime_status ;;
      2) show_traffic_stats ;;
      3) site_health_menu ;;
      0) return 0 ;;
      *) warn "无效输入。请输入 0-3 之间的菜单编号。"; pause ;;
    esac
  done
}

# ---------- 功能7：卸载 ----------
uninstall_script_only() {
  note "将执行：卸载 nx 快捷命令、删除脚本目录下运行文件。"
  if ! confirm "确认继续卸载本脚本？"; then
    info "已取消。"
    return 0
  fi

  # 1) 清理快捷启动命令
  if [[ -f /usr/local/bin/nx ]]; then
    ${SUDO} rm -f /usr/local/bin/nx
    info "已移除：/usr/local/bin/nx"
  else
    warn "未发现 /usr/local/bin/nx，跳过。"
  fi

  # 2) 清理脚本目录下运行状态文件
  rm -f "$EMAIL_CONF" 2>/dev/null || true

  # 3) 给出手动删除路径（仅当不在系统通用 bin 目录），避免误导用户去清理 /usr/local/bin
  local dir_to_remove
  dir_to_remove="$(realpath "$SCRIPT_DIR")"
  if [[ -n "$dir_to_remove" && "$dir_to_remove" != "/" ]]; then
    if [[ "$dir_to_remove" == "/usr/local/bin" || "$dir_to_remove" == "/usr/local/bin/"* ]]; then
      :
    else
      warn "脚本目录未自动删除，请按需手动清理：${dir_to_remove}"
    fi
  fi

  info "本脚本卸载完成。"
  exit 0
}

uninstall_nginx_only() {
  local pkg
  pkg="$(detect_pkg_mgr)"

  warn "将彻底卸载 Nginx 并清空相关配置/日志目录。"
  warn "将删除：/etc/nginx /var/log/nginx /var/cache/nginx /usr/share/nginx"
  if ! confirm "确认继续卸载 Nginx？"; then
    info "已取消。"
    return 0
  fi

  if ! confirm "这是高风险操作，是否再次确认卸载 Nginx？"; then
    info "已取消。"
    return 0
  fi

  if check_cmd systemctl; then
    ${SUDO} systemctl stop nginx 2>/dev/null || true
    ${SUDO} systemctl disable nginx 2>/dev/null || true
  elif check_cmd rc-service; then
    ${SUDO} rc-service nginx stop 2>/dev/null || true
    ${SUDO} rc-update del nginx 2>/dev/null || true
  fi

  case "$pkg" in
    apt)
      ${SUDO} apt-get purge -y 'nginx*' || true
      ${SUDO} apt-get autoremove -y || true
      ${SUDO} rm -f /etc/apt/sources.list.d/nginx.list || true
      ;;
    dnf|yum)
      ${SUDO} "$pkg" remove -y 'nginx*' || true
      ${SUDO} rm -f /etc/yum.repos.d/nginx.repo || true
      ;;
    apk)
      ${SUDO} apk del nginx nginx-mod-stream 2>/dev/null || true
      ;;
    opkg)
      ${SUDO} opkg remove nginx 2>/dev/null || true
      ;;
    *)
      warn "未知包管理器，尝试仅清理目录。"
      ;;
  esac

  ${SUDO} rm -rf /etc/nginx /var/log/nginx /var/cache/nginx /usr/share/nginx/html /usr/share/nginx 2>/dev/null || true

  # Double-check if any core dirs still exist (best-effort)
  local -a leftovers=()
  for p in /etc/nginx /var/log/nginx /var/cache/nginx /usr/share/nginx; do
    if [[ -e "$p" ]]; then
      leftovers+=("$p")
    fi
  done
  if [[ ${#leftovers[@]} -gt 0 ]]; then
    warn "已尝试清理 Nginx 目录，但仍检测到残留：${leftovers[*]}（可能被其他程序占用或权限限制）"
  else
    info "Nginx 及其配置已清理完成。"
  fi
}

uninstall_acme_only() {
  warn "将彻底卸载 acme.sh 并清空证书/配置及邮箱信息。"
  warn "将删除：$HOME/.acme.sh ${SSL_DIR} ${EMAIL_CONF}"
  if ! confirm "确认继续卸载 Acme？"; then
    info "已取消。"
    return 0
  fi

  if ! confirm "这是高风险操作，是否再次确认卸载 Acme？"; then
    info "已取消。"
    return 0
  fi

  # 1) 删除 acme.sh 安装目录及证书目录
  rm -rf "$HOME/.acme.sh" 2>/dev/null || true
  ${SUDO} rm -rf "$SSL_DIR" 2>/dev/null || true

  # 2) 删除 crontab 中 acme 自动续期任务
  if crontab -l >/tmp/.nginxx_cron 2>/dev/null; then
    grep -v 'acme.sh --cron' /tmp/.nginxx_cron | crontab - || true
    rm -f /tmp/.nginxx_cron
  fi
  ${SUDO} rm -f /etc/periodic/monthly/acme-renew 2>/dev/null || true

  # 3) 清理邮箱及 DNS API 持久化信息
  rm -f "$EMAIL_CONF" 2>/dev/null || true
  rm -f "$DNS_CONF" 2>/dev/null || true

  info "Acme 及相关配置已清理完成。"
}

uninstall_all() {
  warn "将执行全部卸载：本脚本 + Nginx（含配置清理）。"
  warn "该操作会同时清理 Nginx、证书、脚本入口和相关目录。"
  if ! confirm "确认继续全部卸载？"; then
    info "已取消。"
    return 0
  fi

  if ! confirm "这是最高风险操作，是否再次确认全部卸载？"; then
    info "已取消。"
    return 0
  fi

  uninstall_nginx_only
  uninstall_acme_only
  uninstall_script_only
}

uninstall_menu() {
  while true; do
    clear
    echo "========== 卸载 =========="
    echo "1) 卸载脚本（彻底卸载本脚本并清理）"
    echo "2) 卸载 Nginx（彻底卸载并清空 Nginx 配置）"
    echo "3) 卸载 Acme（彻底卸载并清空 Acme 配置/邮箱信息）"
    echo "4) 全部卸载（脚本 + Nginx + Acme 全清理）"
    echo "0) 返回上一级"
    echo "=========================="
    read -rp "请选择: " c

    case "$c" in
      1) run_menu_action uninstall_script_only; pause ;;
      2) run_menu_action uninstall_nginx_only; pause ;;
      3) run_menu_action uninstall_acme_only; pause ;;
      4) run_menu_action uninstall_all; pause ;;
      0) return 0 ;;
      *) warn "无效输入。请输入 0-4 之间的菜单编号。"; pause ;;
    esac
  done
}

# ---------- 菜单 ----------
banner() {
  clear
  echo "${APP_NAME} v${APP_VERSION}"
  echo "========================================"
}

update_script() {
  # 优先使用当前脚本所在目录（如果它本身是个 git 仓库），
  # 其次 fallback 到传统安装目录 REPO_INSTALL_DIR（/opt/Nginx-X）。
  # 以适配安装到非标准路径 / 开发环境直接运行的场景。
  local work_dir=""
  if [[ -n "${SCRIPT_DIR:-}" && -d "${SCRIPT_DIR}/.git" ]]; then
    work_dir="${SCRIPT_DIR}"
  elif [[ -d "${REPO_INSTALL_DIR}/.git" ]]; then
    work_dir="${REPO_INSTALL_DIR}"
  fi

  note "正在从 ${REPO_URL} (分支: ${REPO_BRANCH}) 更新脚本..."

  if [[ -n "$work_dir" ]]; then
    # 校对 remote，防止已仓库指向旧 fork
    local cur_remote=""
    cur_remote="$(${SUDO} git -C "$work_dir" remote get-url origin 2>/dev/null || echo '')"
    if [[ -n "$cur_remote" && "$cur_remote" != "$REPO_URL" ]]; then
      warn "当前仓库 remote 与内置 REPO_URL 不一致："
      warn "  本地: $cur_remote"
      warn "  预期: $REPO_URL"
      if ! confirm "仍从本地 remote 拉取（保留现有配置）？"; then
        info "已取消更新。"
        return 0
      fi
    fi
    if ! ${SUDO} git -C "$work_dir" pull --ff-only origin "${REPO_BRANCH}"; then
      error "拉取最新代码失败，请检查网络或手动更新。"
      return 1
    fi
  elif [[ -d "${REPO_INSTALL_DIR}" ]]; then
    warn "安装目录存在但不是 Git 仓库，将重新克隆..."
    ${SUDO} rm -rf "${REPO_INSTALL_DIR}"
    if ! ${SUDO} git clone -b "${REPO_BRANCH}" "${REPO_URL}" "${REPO_INSTALL_DIR}"; then
      error "克隆仓库失败，请检查网络。"
      return 1
    fi
    work_dir="${REPO_INSTALL_DIR}"
  else
    if ! ${SUDO} git clone -b "${REPO_BRANCH}" "${REPO_URL}" "${REPO_INSTALL_DIR}"; then
      error "克隆仓库失败，请检查网络。"
      return 1
    fi
    work_dir="${REPO_INSTALL_DIR}"
  fi

  # 推断 nx 可执行文件的安装目标：
  # 1) 若 command -v nx 能找到，使用它的实际路径
  # 2) 否则 fallback 到 /usr/local/bin/nx
  local target_bin=""
  if check_cmd nx; then
    target_bin="$(command -v nx 2>/dev/null || true)"
  fi
  [[ -z "$target_bin" ]] && target_bin="/usr/local/bin/nx"

  ${SUDO} install -m 0755 "${work_dir}/nx.sh" "$target_bin"
  info "脚本已更新到最新版本（${target_bin}）。"
  note "当前运行的仍是旧版本，重新启动 nx 后生效。"
}

main_menu() {
  echo "1) 安装升级Nginx"
  echo "2) 配置管理"
  echo "3) 证书管理"
  echo "4) 实时信息"
  echo "5) 系统信息"
  echo "6) 卸载"
  echo "7) 更新脚本"
  echo "0) 退出"
  echo "========================================"
}

main() {
  ensure_dirs
  ensure_websocket_map

  while true; do
    banner
    main_menu
    read -rp "请选择功能: " choice

    case "$choice" in
      1) run_menu_action install_or_upgrade_nginx; pause ;;
      2) config_entry_menu ;;
      3) cert_menu ;;
      4) realtime_info_menu ;;
      5) run_menu_action show_system_info; pause ;;
      6) uninstall_menu ;;
      7) run_menu_action update_script; pause ;;
      0) info "已退出 ${APP_NAME}。"; exit 0 ;;
      *) warn "无效输入，请输入主菜单中的编号（0-7）。"; pause ;;
    esac
  done
}

main
