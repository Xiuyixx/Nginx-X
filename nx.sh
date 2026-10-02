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
APP_VERSION="3.1.0 (2026-10-02)"
# Alpine 的 nginx 把 server 配置放在 http.d，其他系统用 conf.d
if [[ -f /etc/nginx/http.d ]] || [[ -d /etc/nginx/http.d ]]; then
  CONF_DIR="/etc/nginx/http.d"
else
  CONF_DIR="/etc/nginx/conf.d"
fi
CONF_DIR="${NX_CONF_DIR:-$CONF_DIR}"
SSL_DIR="${SSL_DIR:-/etc/nginx/ssl}"
NGINX_MAIN_CONF="${NGINX_MAIN_CONF:-/etc/nginx/nginx.conf}"
NX_RUNNING_SOURCE="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/nginxx}"
EMAIL_CONF="${STATE_DIR}/email.conf"
# Read by the eagerly sourced certificate module and installed bundle.
# shellcheck disable=SC2034
DNS_CONF="${STATE_DIR}/dns.conf"
DOMAIN_ONLY_STATE="${DOMAIN_ONLY_STATE:-$CONF_DIR/.nx-access-state}"
REPO_URL="https://github.com/Xiuyixx/Nginx-X.git"
REPO_BRANCH="main"
REPO_INSTALL_DIR="${REPO_INSTALL_DIR:-/opt/Nginx-X}"

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
  if ! "$@"; then
    warn "操作未完成，请查看上方错误信息。"
  fi
}

install_managed_file() {
  ${SUDO} install -m 0644 "$1" "$2"
}

# ---------- 基础能力 ----------
check_cmd() {
  # Avoid false positives from bash's command hash cache (set -u friendly).
  local p
  p="$(command -v "$1" 2>/dev/null || true)"
  [[ -n "$p" && -x "$p" ]]
}

# Called only by explicit lifecycle actions / main, never while sourcing modules.
ensure_runtime_dependencies() {
  local cmd pkg
  local -a missing=()
  for cmd in python3 curl openssl awk sed grep tar flock; do
    check_cmd "$cmd" || missing+=("$cmd")
  done
  [[ ${#missing[@]} -gt 0 ]] || return 0
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    if ! check_cmd sudo || ! sudo -v; then
      error "补齐依赖需要 sudo 权限：${missing[*]}"; return 1
    fi
  fi
  pkg="$(detect_pkg_mgr)"
  case "$pkg" in
    apt) ${SUDO} apt-get update && ${SUDO} apt-get install -y python3 curl openssl gawk sed grep tar util-linux ;;
    dnf|yum) ${SUDO} "$pkg" install -y python3 curl openssl gawk sed grep tar util-linux ;;
    apk) ${SUDO} apk add python3 curl openssl gawk sed grep tar util-linux ;;
    opkg) ${SUDO} opkg update && ${SUDO} opkg install python3 curl openssl-util gawk sed grep tar flock ;;
    *) error "请先安装依赖：${missing[*]}"; return 1 ;;
  esac || return 1
  for cmd in "${missing[@]}"; do
    check_cmd "$cmd" || { error "依赖仍不可用：$cmd"; return 1; }
  done
}

installed_script_target() {
  local running
  running="$(readlink -f "$NX_RUNNING_SOURCE")" || return 1
  if [[ -z "${NX_INSTALLED_TARGET:-}" || "$running" != "$NX_INSTALLED_TARGET" ]]; then
    error "当前文件不是已登记的安装入口；请用 install.sh 安装后再更新/卸载。" >&2
    printf '恢复命令（确认仓库路径后执行）：env TARGET_BIN=%q bash %q --no-run\n' "$running" "$REPO_INSTALL_DIR/install.sh" >&2
    return 1
  fi
  printf '%s\n' "$running"
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
      if ! ${SUDO} systemctl reload nginx; then
        error "Nginx 重载失败。"
        return 1
      fi
      info "Nginx 已重载。"
    else
      if ! ${SUDO} systemctl start nginx; then
        error "Nginx 启动失败。"
        return 1
      fi
      info "检测到 Nginx 未运行，已自动启动。"
    fi
  elif check_cmd rc-service; then
    if ${SUDO} rc-service nginx status 2>/dev/null; then
      if ! ${SUDO} rc-service nginx reload 2>/dev/null && ! ${SUDO} rc-service nginx restart; then
        error "Nginx 重载失败。"
        return 1
      fi
      info "Nginx 已重载。"
    else
      if ! ${SUDO} rc-service nginx start; then
        error "Nginx 启动失败。"
        return 1
      fi
      info "检测到 Nginx 未运行，已自动启动。"
    fi
  else
    if ${SUDO} service nginx status >/dev/null 2>&1; then
      if ! ${SUDO} service nginx reload; then
        error "Nginx 重载失败。"
        return 1
      fi
      info "Nginx 已重载。"
    else
      if ! ${SUDO} service nginx start; then
        error "Nginx 启动失败。"
        return 1
      fi
      info "检测到 Nginx 未运行，已自动启动。"
    fi
  fi
}

ensure_dirs() {
  ${SUDO} mkdir -p "$CONF_DIR" || return 1
  ${SUDO} mkdir -p "$SSL_DIR"
}

# 写入 WebSocket upgrade map，避免对普通 HTTP 请求发送固定 Connection: upgrade
ensure_websocket_map() {
  [[ -f "$NGINX_MAIN_CONF" ]] || return 0
  local map_conf="${CONF_DIR}/00-websocket-map.conf"

  # Skip if nginx is not installed yet (no nginx.conf)
  if [[ ! -f "$NGINX_MAIN_CONF" ]]; then
    return 0
  fi

  # Skip if nginx.conf already defines the map (e.g. Alpine default config)
  # shellcheck disable=SC2016  # $http_upgrade is literal nginx variable syntax, matched as-is
  if grep -qF 'map $http_upgrade' "$NGINX_MAIN_CONF" 2>/dev/null; then
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
  ' "$NGINX_MAIN_CONF" 2>/dev/null; then
    need_inject=1
  fi

  # Decide whether disk changes are needed before acquiring a transaction.
  if [[ "$need_inject" == 0 && -f "$map_conf" ]]; then return 0; fi
  if [[ "${NX_IN_TRANSACTION:-0}" != 1 ]]; then
    nx_transaction true
    return $?
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
    ' "$NGINX_MAIN_CONF" > "$tmp_nginx"

    ${SUDO} tee "$NGINX_MAIN_CONF" < "$tmp_nginx" >/dev/null || return 1
    rm -f "$tmp_nginx"
    note "已准备 nginx.conf WebSocket map，等待事务校验。"
    return 0
  fi

  # Standard: CONF_DIR is inside http block, map file is safe
  if [[ ! -f "$map_conf" ]]; then
    local tmp_map
    tmp_map="$(mktemp /tmp/nginxx-map-conf-XXXXXX)"
    cat > "$tmp_map" <<'EOF'
# managed_by=Nginx-X
# WebSocket upgrade map — included by all proxy configs via conf.d
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
    if ! nx_write_conf "$tmp_map" "$map_conf"; then
      rm -f "$tmp_map"
      return 1
    fi
    rm -f "$tmp_map"
    note "已准备 WebSocket map：${map_conf}，等待事务校验。"
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

nginx_latest_version_online() {
  # 使用 Nginx 官网下载页中的 stable 区块获取最新稳定版版本号
  # 说明：部分环境可能无法访问 nginx.org（网络/IPv6/DNS/证书链等）。
  # 该函数失败时应返回空字符串，由上层决定回退策略。
  local latest page

  page="$(curl -fsSL --connect-timeout 4 --max-time 8 \
    -A 'Nginx-X version-check' \
    https://nginx.org/en/download.html 2>/dev/null || true)"

  # fallback: try http if https fails (some environments have TLS issues)
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

  ensure_runtime_dependencies || return 1
  ensure_dirs || return 1

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
      if ! ${SUDO} apt-get install -y python3 curl wget socat cron gpg lsb-release ca-certificates; then
        error "依赖安装失败。请检查网络连接、APT 源状态或稍后重试。"
        return 1
      fi

      note "配置 Nginx 官方 stable 源..."
      if ! curl -fsSL https://nginx.org/keys/nginx_signing.key | ${SUDO} gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg; then
        error "下载或导入 Nginx 官方签名密钥失败。请检查网络连接后重试。"
        return 1
      fi
      # shellcheck disable=SC1091
      echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/$(. /etc/os-release; echo "${ID}") $(lsb_release -cs) nginx" | ${SUDO} tee /etc/apt/sources.list.d/nginx.list >/dev/null || return 1
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
      if ! ${SUDO} "$pkg" install -y python3 curl wget socat cronie; then
        error "依赖安装失败。请检查网络连接、YUM/DNF 源状态或稍后重试。"
        return 1
      fi

      note "配置 Nginx 官方 stable 源..."
      cat <<'REPO' | ${SUDO} tee /etc/yum.repos.d/nginx.repo >/dev/null || return 1
[nginx-stable]
name=nginx stable repo
baseurl=https://nginx.org/packages/centos/$releasever/$basearch/
gpgcheck=1
enabled=1
gpgkey=https://nginx.org/keys/nginx_signing.key
module_hotfixes=true
REPO
      ${SUDO} "$pkg" makecache -y || true
      if ! ${SUDO} "$pkg" install -y nginx; then
        error "Nginx 安装失败。请检查网络连接、软件源状态或稍后重试。"
        return 1
      fi
      ;;
    apk)
      if ! ${SUDO} apk add python3 curl wget socat dcron openssl; then
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
      if ! ${SUDO} opkg install python3 curl wget socat cron nginx openssl-util; then
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
    ${SUDO} systemctl enable --now nginx || return 1
    ${SUDO} systemctl enable --now cron 2>/dev/null || ${SUDO} systemctl enable --now crond 2>/dev/null || true
  elif check_cmd rc-service; then
    ${SUDO} rc-update add nginx default 2>/dev/null || true
    ${SUDO} rc-service nginx start 2>/dev/null || return 1
    ${SUDO} rc-update add dcron default 2>/dev/null || ${SUDO} rc-update add crond default 2>/dev/null || true
    ${SUDO} rc-service dcron start 2>/dev/null || ${SUDO} rc-service crond start 2>/dev/null || true
  fi

  # 安装后自动停用可能引发冲突的默认配置
  disable_default_conf_if_exists || return 1

  # 安装后重新检测 conf 目录（Alpine 装完才有 http.d）
  if [[ -d /etc/nginx/http.d ]]; then
    CONF_DIR="/etc/nginx/http.d"
    ensure_dirs
  fi

  reload_nginx_safe || return 1

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
  if grep -rqsF 'nginx.org' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    using_official_repo="1"
  elif [[ -f /etc/yum.repos.d/nginx.repo ]] || grep -rqsF 'nginx.org' /etc/yum.repos.d/ 2>/dev/null; then
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
      warn "无法获取官方最新版本（nginx.org 访问失败或解析失败：$(curl_error_hint "$probe_rc")），将改为直接通过包管理器检查并尝试升级。"
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
  if ! ${SUDO} cp -a /etc/nginx "$backup_dir"; then
    error "配置备份失败，已取消升级。"
    return 1
  fi

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
    reload_nginx_safe || return 1
    info "Nginx 已平滑升级完成。"
  else
    error "升级后配置校验失败，请检查。备份目录：${backup_dir}"
    ${SUDO} nginx -t || true
    return 1
  fi
}

# ---------- 功能1：安装升级Nginx（合并入口） ----------
install_or_upgrade_nginx() {
  ensure_runtime_dependencies || return 1
  # 未安装时先安装；已安装时走智能升级逻辑
  if ! check_cmd nginx; then
    install_nginx_official || return 1
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
  [[ "$url" == *'$'* ]] && return 1
  return 0
}

is_port_used_os() {
  local p="$1"
  if check_cmd ss; then
    ss -lnt 2>/dev/null | awk -v p=":${p}" 'NR>1 && $4 ~ p "$" {found=1} END {exit !found}'
  elif check_cmd netstat; then
    netstat -lnt 2>/dev/null | awk -v p=":${p}" 'NR>2 && $4 ~ p "$" {found=1} END {exit !found}'
  else
    return 1
  fi
}

# 通用「本机 TCP 监听」检测：ss → netstat → /proc/net/tcp 兜底（BusyBox 兼容）
nginx_port_listening() {
  local p="$1"
  if check_cmd ss; then
    if ss -lnt 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "(^|:)${p}$"; then
      return 0
    fi
  elif check_cmd netstat; then
    if netstat -lnt 2>/dev/null | awk 'NR>2{print $4}' | grep -qE "(^|:)${p}$"; then
      return 0
    fi
  fi
  # 兜底：直接解析 /proc/net/tcp（本地地址列为十六进制，如 00000000:0050）
  local hex
  hex="$(printf '%04X' "$p")"
  grep -qiE ":${hex}[[:space:]]+00000000:0000" /proc/net/tcp 2>/dev/null
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

# Structural query helpers are loaded eagerly from lib/templates.sh.


conf_meta_get() { nx_conf_query meta "$1" "$2"; }
extract_proxy_pass() { nx_conf_query proxy "$1"; }

url_explicit_port() {
  printf '%s\n' "$1" | sed -nE 's#^https?://(\[[^]]+\]|[^/:]+):([0-9]+)(/.*)?$#\2#p'
}

list_confs_by_meta_domain() {
  local domain="$1"
  awk -v d="$domain" '
    FNR == 1 {
      if (NR > 1 && found) print previous_file
      previous_file=FILENAME
      found=0
    }
    $0 == "# domain=" d {found=1}
    END {if (found) print FILENAME}
  ' "${CONF_DIR}"/*.conf 2>/dev/null || true
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
  install_managed_file "$tmp" "$conf_file" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
}

conf_server_block_count() {
  nx_conf_query count "$1"
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

# 若配置包含 ssl 监听，则必须同时包含证书指令，避免生成半截 HTTPS 配置
ensure_ssl_directives_present() {
  # Includes and inherited http-level certificates are resolved by nginx -t
  # in the transaction. Structural parsing handles compact/quoted directives.
  nx_conf_query tls-check "$1" "$NGINX_MAIN_CONF"
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

  nx_assert_new_target "$(conf_target_path "$domain" "$listen_port")" || return 1

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
  tmp="$(mktemp /tmp/nginxx-"${domain}"-XXXXXX)" || return 1
  trap 'rm -f "${tmp:-}"' RETURN

  build_proxy_conf "$domain" "$create_port" "$backend_port" "$tmp" || { rm -f "$tmp"; return 1; }
  if nx_transaction nx_add_conf "$tmp" "$target"; then
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
  else
    rm -f "$tmp"
    return 1
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

  nx_assert_new_target "$(conf_target_path "$domain" "$listen_port")" || return 1

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
  tmp="$(mktemp /tmp/nginxx-external-"${domain}"-XXXXXX)" || return 1
  trap 'rm -f "${tmp:-}"' RETURN

  build_external_proxy_conf "$domain" "$create_port" "$upstream_url" "$external_mode" "$tmp" "0" "$stream_upstream_url" "$source_site_url" "$referer_url" "$stream_upstream_urls" || { rm -f "$tmp"; return 1; }
  if nx_transaction nx_add_conf "$tmp" "$target"; then
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
  else
    rm -f "$tmp"
    return 1
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
      ! -name '00-nx-domain-only.conf*' \
      ! -name 'acme-challenge-*.conf*' \
      -exec grep -l '^# managed_by=Nginx-X$' {} + 2>/dev/null | sort || true
  else
    find "$CONF_DIR" -maxdepth 1 -type f -name '*.conf' \
      ! -name 'nginx_status.conf*' \
      ! -name '00-websocket-map.conf*' \
      ! -name '00-nx-domain-only.conf*' \
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
  local f domain ports tls policy status effective records
  effective="关闭"; domain_only_state_is_enabled && effective="开启"
  local -a paths=()
  for f in "${FILES[@]}"; do paths+=("$CONF_DIR/$f"); done
  records="$(nx_conf_query list "${paths[@]}")" || return 1
  while IFS=$'\t' read -r f domain ports tls policy; do
    f="${f##*/}"
    case "$policy" in
      ''|inherit)
        policy="仅域名访问：${effective}（沿用原设置）" ;;
      strict) policy="仅域名访问：开启" ;;
      open) policy="仅域名访问：关闭" ;;
      *) policy="无效策略" ;;
    esac
    status="已停用"; [[ "$f" == *.conf ]] && status="已启用"
    echo "  ${i}) ${domain:-未知域名} | ${ports} | ${tls} | ${policy} | ${status} | ${f}"
    ((i+=1))
  done <<< "$records"
  return 0
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
  current_listen="$(_extract_conf_meta "$src" | cut -d '|' -f2)"
  current_backend="$(conf_meta_get "$src" backend_port)"
  [[ -z "$current_listen" ]] && current_listen="80"
  # 元数据缺失时从实际 proxy_pass 提取后端端口
  if [[ -z "$current_backend" ]]; then
    current_backend="$(extract_proxy_pass "$src" | sed -nE 's#^https?://127\.0\.0\.1:([0-9]+)(/.*)?$#\1#p')"
  fi
  if [[ -z "$current_backend" ]]; then
    current_backend="$(extract_proxy_pass "$src" | sed -nE 's#^https?://localhost:([0-9]+)(/.*)?$#\1#p')"
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
  build_proxy_conf "$new_domain" "$new_listen" "$new_backend" "$tmp" || return 1
  nx_preserve_modify_tls "$src" "$tmp" "$new_domain" "$new_listen" || return 1
  new_target="$(conf_target_path "$new_domain" "$new_listen")"
  [[ "$src" == *.conf.bak ]] && new_target="${new_target}.bak"
  apply_conf_with_rollback "$tmp" "$new_target" "$src" || return 1
  info "配置已修改，保留原协议与启停状态。"
  rm -f "$tmp"

}

modify_external_conf() {
  local file src current_domain current_listen current_upstream_url current_mode
  local current_stream_upstream_url current_stream_upstream_urls current_source_site_url current_referer_url
  local new_domain new_listen new_upstream_url new_mode new_stream_upstream_url new_stream_upstream_urls new_source_site_url new_referer_url
  local tmp new_target
  local was_disabled=0

  file="${1:-}"
  src="${CONF_DIR}/${file}"
  [[ -f "$src" ]] || {
    error "配置文件不存在：${src}"
    return 1
  }

  require_template_rebuild_safe "$src" "修改外部反代配置" || return 1

  current_domain="$(extract_domain_from_conf "$src")"
  current_listen="$(_extract_conf_meta "$src" | cut -d '|' -f2)"
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

  new_target="$(conf_target_path "$new_domain" "$new_listen")"
  (( was_disabled == 0 )) || new_target="${new_target}.bak"
  tmp="$(mktemp /tmp/nginxx-external-mod-XXXXXX)" || return 1
  trap 'rm -f "${tmp:-}"' RETURN
  build_external_proxy_conf "$new_domain" "$new_listen" "$new_upstream_url" "$new_mode" "$tmp" "0" "$new_stream_upstream_url" "$new_source_site_url" "$new_referer_url" "$new_stream_upstream_urls" || return 1
  nx_preserve_modify_tls "$src" "$tmp" "$new_domain" "$new_listen" || return 1
  apply_conf_with_rollback "$tmp" "$new_target" "$src" || return 1
  info "配置已修改，保留原协议与启停状态。"
  rm -f "$tmp"

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
    echo "6) 仅域名访问"
    echo "7) HTTPS 开关"
    echo "8) 站点健康检查"
    echo "0) 返回上一级"
    echo "============================"
    read -rp "请选择: " c

    case "$c" in
      1) run_menu_action enable_conf "$file"; pause; return 0 ;;
      2) run_menu_action disable_conf "$file"; pause; return 0 ;;
      3) run_menu_action modify_conf "$file"; pause; return 0 ;;
      4) run_menu_action edit_conf_manual "$file"; pause; return 0 ;;
      5) run_menu_action delete_conf "$file"; pause; return 0 ;;
      6) run_menu_action nx_site_access_menu "$CONF_DIR/$file"; pause ;;
      7) run_menu_action nx_site_https_toggle "$CONF_DIR/$file"; pause ;;
      8) run_menu_action health_check_conf_file "$CONF_DIR/$file"; pause ;;
      0) return 0 ;;
      *) warn "无效输入。请输入 0-8 之间的菜单编号。"; pause ;;
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
  local _f key keys
  for _f in "${CONF_DIR}"/*.conf "${CONF_DIR}"/*.conf.*; do
    [[ -f "$_f" ]] || continue
    grep -q '^# managed_by=Nginx-X$' "$_f" 2>/dev/null || continue
    keys="$(nx_conf_query keys "$_f")" || continue
    while IFS= read -r key; do [[ -z "$key" ]] || managed_index["$key"]=1; done <<< "$keys"
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
      [[ "$base" == default || "$base" == default.conf || "$base" == default.conf.* || "$base" == nginx_status.conf || "$base" == 00-nx-domain-only.conf ]] && continue
      # 通过 realpath 去重（sites-enabled 软链接 → sites-available）
      real_path="$(realpath "$conf" 2>/dev/null || echo "$conf")"
      [[ -n "${seen[$real_path]:-}" ]] && continue
      seen["$real_path"]="$conf"
      # 检查是否已有同域名-端口的纳管配置（包括停用的）
      local duplicate=0
      keys="$(nx_conf_query keys "$conf")" || continue
      while IFS= read -r key; do
        if [[ -n "$key" && -n "${managed_index[$key]:-}" ]]; then duplicate=1; fi
      done <<< "$keys"
      (( duplicate == 0 )) || continue
      echo "$conf"
    done
  done
}

# 从现有 conf 中提取元数据
_extract_conf_meta() {
  nx_conf_query summary "$1"
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

  locations="$(nx_conf_query locations "$conf")" || return 1
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
  local real_conf

  meta="$(_extract_conf_meta "$conf")" || return 1
  IFS='|' read -r domain listen_port backend_url https_enabled mode <<< "$meta"

  validate_importable_conf "$conf" || return 1

  if [[ -z "$domain" ]]; then
    warn "跳过 ${conf}：无法识别 server_name。"
    return 1
  fi

  # 目标文件名
  target_name="${domain}-${listen_port}.conf"
  target_path="${CONF_DIR}/${target_name}"
  [[ ! -e "$target_path.bak" ]] || { error "同名停用站点已存在。"; return 1; }

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
    backend_port="$(url_explicit_port "$backend_url")"
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
    if [[ "$real_conf" != "$target_path" && -e "$target_path" ]]; then target_path="$real_conf"; fi
    if ! apply_conf_with_rollback "$tmp" "$target_path" "$real_conf"; then
      rm -f "$tmp"
      return 1
    fi
  else
    [[ ! -e "$target_path" ]] || { rm -f "$tmp"; error "目标配置已存在。"; return 1; }
    local enabled_link link_target
    for enabled_link in /etc/nginx/sites-enabled/*; do
      [[ -L "$enabled_link" ]] || continue
      link_target="$(realpath "$enabled_link" 2>/dev/null || true)"
      if [[ "$link_target" == "$real_conf" ]]; then
        rm -f "$tmp"
        error "该配置通过事务目录外的 sites-enabled 链接启用；请先手动迁移到 ${CONF_DIR} 后导入。"
        return 1
      fi
    done
    if ! apply_conf_with_rollback "$tmp" "$target_path"; then
      reload_nginx_safe >/dev/null 2>&1 || true
      rm -f "$tmp"
      return 1
    fi
    note "原始文件保留在：${real_conf}（未修改外部启用链接）"
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
    meta="$(_extract_conf_meta "$conf")" || return 1
    IFS='|' read -r domain listen_port rest <<< "$meta"
    [[ -z "$domain" ]] && domain="(无法识别)"

    echo "  → ${conf}"
    echo "    域名: ${domain}  端口: ${listen_port}"
    if confirm "    是否导入此配置？"; then
      if import_single_conf "$conf"; then
        ((imported+=1))
      fi
    else
      info "    已跳过。"
    fi
    echo ""
  done

  if [[ $imported -gt 0 ]]; then
    info "共导入 ${imported} 个配置。"

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
valid_dns_address() {
  python3 - "$1" <<'PYDNS'
import ipaddress, sys
try:
    value = sys.argv[1]
    if "%" in value:
        raise ValueError("scope is not supported")
    ipaddress.ip_address(value)
except ValueError:
    sys.exit(1)
PYDNS
}

write_system_dns() {
  local target="$1" ns1="$2" ns2="${3:-}" stage backup
  [[ "$target" == /* && "$target" != */ ]] || return 1
  valid_dns_address "$ns1" || return 1
  [[ -z "$ns2" ]] || valid_dns_address "$ns2" || return 1
  # Stage beside the destination: failed install/rename never unlinks the original.
  stage="$(${SUDO} mktemp "${target}.stage.XXXXXX")" || return 1
  backup="$(${SUDO} mktemp -d "${target}.backup.XXXXXX")" || { ${SUDO} rm -f "$stage"; return 1; }
  if [[ -e "$target" || -L "$target" ]]; then
    if ! ${SUDO} cp -a "$target" "$backup/resolv.conf"; then
      ${SUDO} rm -f "$stage"; ${SUDO} rmdir "$backup"; return 1
    fi
  fi
  local tmp
  tmp="$(mktemp)" || { ${SUDO} rm -f "$stage"; return 1; }
  { printf '# Generated by Nginx-X\nnameserver %s\n' "$ns1"; if [[ -n "$ns2" ]]; then printf 'nameserver %s\n' "$ns2"; fi; } > "$tmp"
  if ! install_managed_file "$tmp" "$stage" || ! ${SUDO} mv -f "$stage" "$target"; then
    rm -f "$tmp"; ${SUDO} rm -f "$stage"
    error "写入失败；原文件/链接未替换，备份：$backup"
    return 1
  fi
  rm -f "$tmp"
  note "原 DNS 文件/链接备份：$backup"
}

dns_setup_menu() {
  local resolv_path="${NX_RESOLV_CONF:-/etc/resolv.conf}"
  while true; do
    clear
    echo "========== 系统 DNS 设置 =========="
    echo "当前 DNS 配置："
    if [[ -f "$resolv_path" ]]; then
      grep -E '^nameserver' "$resolv_path" 2>/dev/null | while read -r line; do
        echo "  ${line}"
      done
    else
      echo "  (未找到 ${resolv_path})"
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
      *) warn "无效输入。请输入 0-8 之间的菜单编号。"; pause; continue ;;
    esac

    if ! valid_dns_address "$ns1" || { [[ -n "$ns2" ]] && ! valid_dns_address "$ns2"; }; then
      error "DNS 必须是有效的 IPv4 或 IPv6 地址。"
      pause
      continue
    fi

    if [[ -z "$ns1" ]]; then
      continue
    fi

    # 保护现有系统：检测 resolv.conf 是否被系统服务托管（systemd-resolved / resolvconf / NetworkManager 等）。
    # 直接覆盖它的目标会在服务下次重新生成时恢复，也会破坏系统 DNS 管理。
    local managed_by=""
    if [[ -L "$resolv_path" ]]; then
      local link_target
      link_target="$(readlink -f "$resolv_path" 2>/dev/null || readlink "$resolv_path")"
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
      warn "检测到 ${resolv_path} 由 ${managed_by} 接管。"
      warn "直接覆盖会被系统重写，且可能破坏现有 DNS 服务。"
      warn "建议通过对应服务配置修改 DNS（如 systemd-resolved / netplan / NetworkManager）。"
      if ! confirm "确认仍要直接覆写 ${resolv_path}？"; then
        info "已取消。"
        pause
        continue
      fi
    fi

    if ! write_system_dns "$resolv_path" "$ns1" "$ns2"; then
      error "DNS 更新失败，原配置已保留。"
      pause
      continue
    fi

    info "DNS 已更新为：${ns1}${ns2:+ + ${ns2}}"
    warn "注意：${resolv_path} 可能在系统重启或 DHCP 续租后被覆盖。"
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
extract_domain_from_conf() {
  local meta
  meta="$(nx_conf_query summary "$1")" || return 1
  printf '%s\n' "${meta%%|*}"
}

conf_https_enabled() {
  local meta tls
  meta="$(nx_conf_query summary "$1")" || return 1
  IFS='|' read -r _ _ _ tls _ <<< "$meta"
  [[ "$tls" == true ]]
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

  mapfile -t matches < <(list_confs_by_meta_domain "$domain")

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

domain_only_conf_path() {
  echo "${CONF_DIR}/00-nx-domain-only.conf"
}

nginx_supports_ssl_reject_handshake() {
  local v
  v="$(nginx_local_version)"
  if [[ -z "$v" ]]; then
    return 1
  fi
  # Distribution builds append a label (for example "1.18.0 (Ubuntu)").
  # Compare the numeric version against the first release with this directive.
  v="${v%% *}"
  ! version_gt "1.19.4" "$v"
}

domain_only_list_exposed_ports() {
  local p line addr hex src
  local -a nginx_ports=()

  # 1) 已管理的站点配置里的监听端口
  while IFS= read -r _ p; do
    [[ -n "$p" ]] && nginx_ports+=("$p")
  done < <(domain_only_collect_ports)

  # 2) nginx 实际生效配置的全部 listen 端口（包含未被本工具接管的配置）
  if check_cmd nginx; then
    while IFS= read -r line; do
      p="$(printf '%s\n' "$line" | sed -nE 's/^[[:space:]]*listen[[:space:]]+(\[[^]]*\]:)?([0-9]+)([[:space:]][^;]*)?;.*$/\2/p')"
      [[ -n "$p" ]] && nginx_ports+=("$p")
    done < <(nginx -T 2>/dev/null | grep -E '^[[:space:]]*listen[[:space:]]' || true)
  fi

  local -A ngx=() seen=()
  local x
  for x in ${nginx_ports[@]+"${nginx_ports[@]}"}; do
    ngx["$x"]=1
  done
  ngx["22"]=1   # SSH 不属于本功能范围（菜单说明已声明不受影响）

  # 3) 收集本机所有 TCP 监听端口（回退链与 nginx_port_listening 一致）
  local -a all_listening=()
  if check_cmd ss; then
    while IFS= read -r lp; do
      case "$lp" in 127.*|'[::1]':*|'::1:'*) continue ;; esac
      p="${lp##*:}"
      [[ "$p" =~ ^[0-9]+$ ]] && all_listening+=("$p")
    done < <(ss -lntH 2>/dev/null | awk 'NR>0 {print $4}')
  elif check_cmd netstat; then
    while IFS= read -r lp; do
      case "$lp" in 127.*|'[::1]':*|'::1:'*) continue ;; esac
      p="${lp##*:}"
      [[ "$p" =~ ^[0-9]+$ ]] && all_listening+=("$p")
    done < <(netstat -lnt 2>/dev/null | awk 'NR>2 {print $4}')
  else
    for src in /proc/net/tcp /proc/net/tcp6; do
      [[ -r "$src" ]] || continue
      while IFS= read -r pair; do
        [[ -z "$pair" ]] && continue
        addr="${pair%%:*}"
        hex="${pair##*:}"
        # 只统计通配地址（0.0.0.0 / ::）；绑定具体回环地址的条目已在下方 case 外过滤
        case "$addr" in
          00000000|00000000000000000000000000000000) ;;
          *) continue ;;
        esac
        [[ "$hex" =~ ^[0-9A-Fa-f]+$ ]] || continue
        p=$(( 16#$hex ))
        all_listening+=("$p")
      done < <(awk 'NR>1 {print $2}' "$src" 2>/dev/null)
    done
  fi

  local -a exposed=()
  for p in ${all_listening[@]+"${all_listening[@]}"}; do
    [[ -n "${ngx[$p]:-}" || -n "${seen[$p]:-}" ]] && continue
    seen["$p"]=1
    exposed+=("$p")
  done
  (( ${#exposed[@]} )) && printf '%s\n' "${exposed[@]}" | sort -n
  return 0
}

# 尽力识别端口对应的进程名（ss -p 需要 root；BusyBox ss 不支持则为空）
domain_only_port_process() {
  local p="$1"
  ss -lntpH 2>/dev/null | awk -v port="$p" '$4 ~ ":"port"$"' | head -n1 \
    | sed -nE 's/.*users:\(\("([^"]+)".*/\1/p'
}

domain_only_warn_exposed_ports() {
  local -a exposed=()
  local x pname
  while IFS= read -r x; do
    [[ -n "$x" ]] && exposed+=("$x")
  done < <(domain_only_list_exposed_ports)
  (( ${#exposed[@]} )) || return 0

  warn "检测到以下端口由 Nginx 之外的服务直接对外监听，仅域名访问无法拦截它们："
  for x in ${exposed[@]+"${exposed[@]}"}; do
    pname="$(domain_only_port_process "$x")"
    if [[ -n "$pname" ]]; then
      warn "  端口 ${x}（${pname}）仍可用 IP:端口 访问"
    else
      warn "  端口 ${x} 仍可用 IP:端口 访问"
    fi
  done
  warn "如需隐藏这些端口，请在对应服务（如 Docker）中改为仅监听 127.0.0.1，或用防火墙限制来源。"
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

# ---------- 功能6：流量统计与状态 ----------
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
  note "将执行：卸载当前已登记的 nx 安装入口。"
  if ! confirm "确认继续卸载本脚本？"; then
    info "已取消。"
    return 0
  fi

  local installed_bin
  installed_bin="$(installed_script_target)" || return 1
  ${SUDO} rm -f "$installed_bin" || return 1
  info "已移除：${installed_bin}"

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
  warn "将卸载 Nginx 软件包；保留配置、证书和日志供恢复。"
  confirm "确认继续卸载 Nginx？" || return "${NX_UNINSTALL_CANCEL_RC:-0}"
  if check_cmd systemctl; then
    ${SUDO} systemctl stop nginx || { error "停止失败，已取消卸载。"; return 1; }
  elif check_cmd rc-service; then
    ${SUDO} rc-service nginx stop || return 1
  else
    ${SUDO} service nginx stop || return 1
  fi
  case "$pkg" in
    apt) ${SUDO} apt-get remove -y nginx || return 1 ;;
    dnf|yum) ${SUDO} "$pkg" remove -y nginx || return 1 ;;
    apk) ${SUDO} apk del nginx || return 1 ;;
    opkg) ${SUDO} opkg remove nginx || return 1 ;;
    *) error "未知包管理器，未清理任何目录。"; return 1 ;;
  esac
  hash -r
  if check_cmd nginx; then
    error "仍检测到 Nginx 可执行文件，请检查其他安装来源；配置已保留。"
    return 1
  fi
  info "Nginx 软件包已卸载，配置、证书及日志已保留。"
}

uninstall_acme_only() {
  uninstall_acme_locked "${1:-online}"
}
uninstall_acme_locked() {
  local owned
  owned="$(nx_acme_owned_domains)" || return 1
  warn "将卸载当前账户 acme.sh、邮箱及 DNS 配置；其他账户证书保留。"
  warn "将删除当前账户证书：${owned:-（无）}"
  if [[ ${1:-online} == offline ]]; then
    warn "Nginx 已移除：离线清理不校验/重载；保留配置中的证书引用不会自动修复，重新安装前须处理。"
  else
    warn "仍引用这些证书的站点需先停用；应用失败会恢复证书和原续期调度。"
  fi
  if ! confirm "确认继续卸载 Acme？"; then
    info "已取消。"
    return "${NX_UNINSTALL_CANCEL_RC:-0}"
  fi

  if ! confirm "这是高风险操作，是否再次确认卸载 Acme？"; then
    info "已取消。"
    return "${NX_UNINSTALL_CANCEL_RC:-0}"
  fi

  # The helper rechecks ownership/references under both locks, snapshots the
  # entire account and original scheduler, and restores them together on error.
  nx_acme_uninstall_account "${1:-online}" || return 1

  info "Acme 及相关配置已清理完成。"
}

uninstall_all() {
  warn "将卸载本脚本、Nginx 软件包和 Acme；Nginx 配置/日志保留。"
  warn "该操作会清理证书和脚本入口。"
  if ! confirm "确认继续全部卸载？"; then
    info "已取消。"
    return 0
  fi

  if ! confirm "这是最高风险操作，是否再次确认全部卸载？"; then
    info "已取消。"
    return 0
  fi

  # Only composite orchestration distinguishes cancellation from completion;
  # standalone menus retain their normal successful-cancel behavior.
  # shellcheck disable=SC2034
  local NX_UNINSTALL_CANCEL_RC=2
  local phase_rc
  if uninstall_nginx_only; then :; else
    phase_rc=$?
    [[ $phase_rc == 2 ]] && return 0
    return "$phase_rc"
  fi
  # Also refuse alternative installations left behind by the package manager.
  if check_cmd nginx; then
    error "Nginx 仍已安装，已停止全部卸载；证书与脚本保留。"
    return 1
  fi
  if uninstall_acme_only offline; then :; else
    phase_rc=$?
    [[ $phase_rc == 2 ]] && return 0
    return "$phase_rc"
  fi
  uninstall_script_only
}

uninstall_menu() {
  while true; do
    clear
    echo "========== 卸载 =========="
    echo "1) 卸载脚本（彻底卸载本脚本并清理）"
    echo "2) 卸载 Nginx（保留配置和日志）"
    echo "3) 卸载 Acme（彻底卸载并清空 Acme 配置/邮箱信息）"
    echo "4) 卸载脚本 + Nginx + Acme（保留 Nginx 配置/日志）"
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
  local work_dir="" target_bin
  target_bin="$(installed_script_target)" || return 1
  local source_repo="${NX_INSTALLED_REPO:-$REPO_INSTALL_DIR}"
  if ! check_cmd git; then
    error "更新需要 git，请先安装 git。"
    return 1
  fi
  if [[ -e "$source_repo/.git" ]]; then
    work_dir="$source_repo"
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
  elif [[ -e "$source_repo" || -L "$source_repo" ]]; then
    error "安装目录存在但不是 Git 仓库，已保留：$source_repo"
    return 1
  else
    if ! ${SUDO} git clone -b "$REPO_BRANCH" "$REPO_URL" "$source_repo"; then
      error "克隆仓库失败。"
      return 1
    fi
    work_dir="$source_repo"
  fi

  # 对比更新前后内容：无变化则提示已最新并返回菜单，不重启
  local bin_md5_before=""
  if [[ -f "$target_bin" ]] && check_cmd md5sum; then
    bin_md5_before="$(md5sum "$target_bin" 2>/dev/null | awk '{print $1}')"
  fi

  ${SUDO} env TARGET_BIN="$target_bin" bash "${work_dir}/install.sh" --no-run || return 1

  local bin_md5_after=""
  if check_cmd md5sum; then
    bin_md5_after="$(md5sum "$target_bin" 2>/dev/null | awk '{print $1}')"
  fi

  if [[ -n "$bin_md5_before" && "$bin_md5_before" == "$bin_md5_after" ]]; then
    info "当前已是最新版本（${target_bin}）。"
    return 0
  fi

  info "脚本已更新到最新版本（${target_bin}）。"

  # 是否自动重启进入新版本（在交互式主菜单中才触发，直接 exec 替换当前进程）
  if [[ "${NX_IN_MENU:-0}" == "1" ]]; then
    note "正在重启 nx 并进入新版本..."
    sleep 1
    exec "$target_bin"
  fi
  note "重新启动 nx 后生效。"
}

main_menu() {
  echo "1) 安装升级Nginx"
  echo "2) 配置管理"
  echo "3) 证书管理"
  echo "4) 实时信息"
  echo "5) 卸载"
  echo "6) 更新脚本"
  echo "0) 退出"
  echo "========================================"
}

main() {
  ensure_runtime_dependencies || return 1
  ensure_dirs
  ensure_websocket_map || return 1
  nx_migrate_certificate_renewal || warn "现有证书续期迁移未完成，请检查后重新启动菜单。"

  while true; do
    banner
    main_menu
    read -rp "请选择功能: " choice

    case "$choice" in
      1) run_menu_action install_or_upgrade_nginx; pause ;;
      2) config_entry_menu ;;
      3) cert_menu ;;
      4) realtime_info_menu ;;
      5) uninstall_menu ;;
      6) NX_IN_MENU=1 run_menu_action update_script; NX_IN_MENU=0; pause ;;
      0) info "已退出 ${APP_NAME}。"; exit 0 ;;
      *) warn "无效输入，请输入主菜单中的编号（0-6）。"; pause ;;
    esac
  done
}

# All modules load before an update can change the repository on disk.
# Pre-module releases copied only nx.sh to the installed executable. Recover
# from that exact legacy update using the matching, already-pulled repository.
# Never source modules of a different revision or download code during recovery.
if [[ ! -r "${NX_LIB_DIR:-${SCRIPT_DIR}/lib}/transactions.sh" ]]; then
  nx_legacy_source="${BASH_SOURCE[0]}"
  if [[ -r "${REPO_INSTALL_DIR}/tools/build-bundle.sh" &&
        -r "${REPO_INSTALL_DIR}/install.sh" &&
        -f "${REPO_INSTALL_DIR}/nx.sh" ]] &&
      cmp -s "$nx_legacy_source" "${REPO_INSTALL_DIR}/nx.sh"; then
    if ${SUDO} env TARGET_BIN="$nx_legacy_source" INSTALL_DIR="$REPO_INSTALL_DIR" \
        bash "${REPO_INSTALL_DIR}/install.sh" --no-run; then
      if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
        exec bash "$nx_legacy_source" "$@"
      else
        # shellcheck disable=SC1090
        source "$nx_legacy_source"
        return $?
      fi
    fi
    error "旧版更新迁移失败，请从仓库重新运行 install.sh。"
    if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then exit 1; else return 1; fi
  fi
fi
NX_LIB_DIR="${NX_LIB_DIR:-${SCRIPT_DIR}/lib}"
for nx_module in templates certificates transactions access https diagnostics; do
  if [[ ! -r "${NX_LIB_DIR}/${nx_module}.sh" ]]; then
    error "缺少模块：${NX_LIB_DIR}/${nx_module}.sh，请重新运行 install.sh。"
    if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then exit 1; else return 1; fi
  fi
  # shellcheck disable=SC1090
  source "${NX_LIB_DIR}/${nx_module}.sh"
done
unset nx_module

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
