#!/usr/bin/env bash
# Nginx-X certificate issuance and renewal helpers.
load_dns_conf() {
  ensure_state_dir
  if [[ -f "$DNS_CONF" ]]; then
    # shellcheck disable=SC1090
    . "$DNS_CONF"
  fi
  case "${DNS_PROVIDER:-}" in
    cloudflare) DNS_PROVIDER=cf ;; dnspod) DNS_PROVIDER=dp ;;
    alidns) DNS_PROVIDER=ali ;; he.net) DNS_PROVIDER=he ;;
    godaddy) DNS_PROVIDER=gd ;; huaweicloud) DNS_PROVIDER=hw ;;
    route53) DNS_PROVIDER=aws ;; gcp) DNS_PROVIDER=google ;;
  esac
}

save_dns_conf() {
  local provider="$1"
  local key1="$2"
  local key2="$3"
  local tmp parent
  ensure_state_dir || { error "无法准备 DNS API 配置目录。"; return 1; }
  parent="$(dirname "$DNS_CONF")" || return 1
  # Stage beside the destination: failures never truncate existing credentials.
  # Reject directory/symlink targets rather than letting mv follow/nest them.
  [[ ! -L "$DNS_CONF" && ( ! -e "$DNS_CONF" || -f "$DNS_CONF" ) ]] || {
    error "DNS API 配置目标不是普通文件。"; return 1;
  }
  tmp="$(umask 077; mktemp "$parent/.dns.conf.XXXXXX")" || {
    error "无法创建 DNS API 配置临时文件。"; return 1;
  }
  if ! (
    umask 077
    printf 'DNS_PROVIDER=%q\n' "$provider" > "$tmp" || exit 1
    printf 'DNS_KEY1=%q\n' "$key1" >> "$tmp" || exit 1
    printf 'DNS_KEY2=%q\n' "$key2" >> "$tmp" || exit 1
  ) || ! chmod 600 "$tmp" || ! mv -fT -- "$tmp" "$DNS_CONF"; then
    rm -f -- "$tmp"
    error "DNS API 配置保存失败，原配置未更改。"
    return 1
  fi
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

  save_dns_conf "$provider" "$key1" "${key2:-}" || return 1

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
  valid_domain "$domain" || return 1
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

  nx_deploy_certificate "$domain" || return 1
  ensure_acme_cron || return 1
  info "证书申请并安装成功（DNS-01）。"
}

_issue_cert_http() {
  # 原有的 HTTP-01 逻辑
  local domain="$1"
  valid_domain "$domain" || return 1
  local challenge_conf="" NX_ACME_PENDING="$domain"

  # Prerequisites must fail before publishing any challenge helper/marker.
  ensure_acme_installed || return 1
  nx_acme_prepare_webroot || return 1
  nx_transaction nx_acme_prepare_routes "$domain" || return 1

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

  # Keep the challenge endpoint: acme.sh persists this webroot for renewals.
  nx_deploy_certificate "$domain" || return 1
  ensure_acme_cron || return 1
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
  ( umask 077
    printf 'ACME_EMAIL=%q\n' "$email" > "$EMAIL_CONF"
  )
  chmod 600 "$EMAIL_CONF"
  info "邮箱已保存到：${EMAIL_CONF}"
}

ensure_acme_installed() {
  local install_script=""

  if [[ -x "$HOME/.acme.sh/acme.sh" ]]; then
    nx_acme_check_account_identity || return 1
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

nx_deploy_certificate() {
  local domain="$1"
  valid_domain "$domain" || return 1
  nx_acme_check_account_identity || return 1
  nx_acme_prepare_dispatch || return 1
  # The dispatcher owns one lock across account staging, manifest registration,
  # validation and publication. No unlock gap lets cron observe a partial pair.
  ${SUDO} "$NX_ACME_DISPATCH" install "$domain"
}

# Lock flags are inherited by nested calls, not persisted in the caller.
# shellcheck disable=SC2030
ensure_acme_cron() (
  local scheduler_fd
  exec {scheduler_fd}<"$SSL_DIR" || return 1
  flock -x "$scheduler_fd" || return 1
  NX_ACME_SCHEDULER_HELD=1
  nx_acme_privileged_paths
  ${SUDO} test -x "$NX_ACME_DISPATCH" || { error "请先完成证书部署。"; return 1; }
  nx_acme_privileged_cron enable || return 1
  # Retire only this account's legacy jobs after the protected job exists.
  NX_ACME_USER_CRON_ONLY=1 disable_acme_cron
)

# Parse shell words rather than matching substrings: acme.sh quotes its path,
# sometimes as "/home/user/.acme.sh"/acme.sh. Never match another account.
nx_acme_cron_filter() {
  python3 -c '
import sys, shlex, re
home, mode = sys.argv[1:]
found = False
for line in sys.stdin.read().splitlines():
    m = re.match(r"^(?:\s*@(?:monthly|yearly|annually|weekly|daily|hourly)|(?:\s*\S+){5})\s+(.+)$", line)
    owned = False
    if m and not line.lstrip().startswith("#"):
        try:
            words = shlex.split(m[1])
            command = 0
            while command < len(words) and re.match(r"^[A-Za-z_][A-Za-z_0-9]*=", words[command]):
                command += 1
            owned = command < len(words) and words[command] == home + "/acme.sh" and "--cron" in words[command+1:]
            if any(word in (";", "&&", "||", "|", "&") for word in words):
                owned = False
            if "--home" in words:
                i = words.index("--home")
                owned = owned and i+1 < len(words) and words[i+1] == home
        except ValueError:
            pass
    if owned:
        if mode == "probe":
            found = True
        elif mode == "daily" and not found:
            print("0 3 * * * " + m[1]); found = True
    elif mode != "probe":
        print(line)
if mode == "probe":
    sys.exit(0 if found else 1)
if mode == "daily" and not found:
    print("0 3 * * * " + shlex.quote(home + "/acme.sh") + " --cron --home " + shlex.quote(home) + " >/dev/null")
' "$HOME/.acme.sh" "$1"
}

nx_acme_periodic_owned() {
  [[ -f "$1" ]] || return 1
  # Only the one-command legacy script belongs to us; never remove a mixed
  # administrator script merely because one line invokes this acme account.
  local body
  body="$(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$1")" || return 1
  [[ -n "$body" && "$body" != *$'\n'* ]] || return 1
  printf '0 3 * * * %s\n' "$body" | nx_acme_cron_filter probe
}

has_acme_cron_task() {
  nx_acme_privileged_paths
  if ${SUDO} crontab -l 2>/dev/null | grep -Fxq "0 3 * * * $NX_ACME_DISPATCH cron"; then return 0; fi
  local script
  if nx_acme_account_crontab -l 2>/dev/null | nx_acme_cron_filter probe; then return 0; fi
  for script in "${NX_PERIODIC_DIR:-/etc/periodic}"/{daily,monthly}/acme-renew; do
    nx_acme_periodic_owned "$script" && return 0
  done
  return 1
}

# shellcheck disable=SC2030,SC2031
disable_acme_cron() (
  local scheduler_fd
  exec {scheduler_fd}<"$SSL_DIR" || return 1
  [[ ${NX_ACME_SCHEDULER_HELD:-0} == 1 || ${NX_ACME_LOCK_HELD:-0} == 1 ]] || flock -x "$scheduler_fd" || return 1
  NX_ACME_SCHEDULER_HELD=1
  if [[ ${NX_ACME_USER_CRON_ONLY:-0} != 1 ]]; then
    nx_acme_privileged_cron remove || return 1
  fi
  local current script
  current=""
  if command -v crontab >/dev/null 2>&1; then
    current="$(nx_acme_read_crontab nx_acme_account_crontab)" || return 1
  fi
  if command -v crontab >/dev/null 2>&1; then
    printf '%s\n' "$current" | nx_acme_cron_filter remove | nx_acme_account_crontab - || return 1
  fi
  for script in "${NX_PERIODIC_DIR:-/etc/periodic}"/{daily,monthly}/acme-renew; do
    if nx_acme_periodic_owned "$script"; then
      ${SUDO} rm -f "$script" || return 1
    fi
  done
)

# Upgrade installed certificates belonging to this acme account without issuing
# certificates or enabling a deliberately disabled renewal schedule.
nx_migrate_certificate_renewal() {
  [[ -x "$HOME/.acme.sh/acme.sh" ]] || return 0
  nx_acme_check_account_identity || return 1
  local conf domain marker
  for conf in "$HOME/.acme.sh"/*/*.conf; do
    [[ -f "$conf" && ! -L "$conf" ]] || continue
    domain="$(basename "$conf" .conf)"
    valid_domain "$domain" || continue
    [[ -s "$SSL_DIR/$domain/fullchain.pem" && -s "$SSL_DIR/$domain/privkey.pem" ]] || continue
    if python3 - "$conf" <<'PYWEBROOTMIGRATE'
import sys,shlex
for line in open(sys.argv[1]):
    if line.startswith('Le_Webroot='):
        try:
            if shlex.split(line.rstrip().split('=',1)[1])==['/usr/share/nginx/html']: sys.exit(0)
        except ValueError: pass
sys.exit(1)
PYWEBROOTMIGRATE
    then
      nx_acme_prepare_webroot || return 1
      if [[ ! -f "$CONF_DIR/.nx-acme-$domain.state" ]]; then
        nx_transaction nx_acme_prepare_routes "$domain" || return 1
      fi
    fi
    # Read data without sourcing acme account files. Only migrate certificates
    # already deployed to this manager’s exact destinations.
    marker="$(python3 - "$conf" "$SSL_DIR/$domain" <<'PYMIGRATE'
import sys, shlex
values = {}
for line in open(sys.argv[1]):
    if "=" not in line: continue
    key, value = line.rstrip("\n").split("=",1)
    try:
        parts = shlex.split(value)
        if len(parts) == 1: values[key] = parts[0]
    except ValueError: pass
if values.get("Le_RealKeyPath") == sys.argv[2]+"/privkey.pem" and values.get("Le_RealFullChainPath") == sys.argv[2]+"/fullchain.pem":
    print("migrate")
PYMIGRATE
)" || return 1
    [[ "$marker" == migrate ]] || continue
    nx_deploy_certificate "$domain" || return 1
  done
  if has_acme_cron_task; then ensure_acme_cron || return 1; fi
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
  local domain="$1" conf_file tmp_file match
  for conf_file in "$CONF_DIR"/*.conf; do
    [[ -f "$conf_file" ]] || continue
    # First filter exact names, avoiding parsing unrelated custom configurations.
    grep -Eq "(^|[[:space:]])${domain//./\\.}([[:space:];]|$)" "$conf_file" || continue
    match="$(nx_https_transform challenge-probe "$conf_file" "$domain" "$SSL_DIR" "")" || return 1
    [[ "$match" == yes ]] || continue
    tmp_file="$(mktemp)" || return 1
    if ! nx_https_transform challenge "$conf_file" "$domain" "$SSL_DIR" "" > "$tmp_file"; then
      rm -f "$tmp_file"; return 1
    fi
    if ! cmp -s "$tmp_file" "$conf_file"; then
      apply_conf_with_rollback "$tmp_file" "$conf_file" || { rm -f "$tmp_file"; return 1; }
    fi
    rm -f "$tmp_file"
  done
}

ensure_http_challenge_server() {
  # Persistent HTTP-01 endpoint for issuance and every later webroot renewal.
  local domain="$1"
  local challenge_conf="${CONF_DIR}/acme-challenge-${domain}.conf"

  # This marker is covered by the same directory snapshot as helper/site files.
  local marker="$CONF_DIR/.nx-acme-$domain.state"
  ${SUDO} touch "$marker" || return 1

  # Exact server_name tokens and structured address-aware listen parsing.
  local existing match
  for existing in "$CONF_DIR"/*.conf; do
    [[ -f "$existing" ]] || continue
    grep -Eq "(^|[[:space:]])${domain//./\\.}([[:space:];]|$)" "$existing" || continue
    match="$(nx_https_transform challenge-probe "$existing" "$domain" "$SSL_DIR" "")" || return 1
    if [[ "$match" == yes ]]; then
      echo ""
      return 0
    fi
  done

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

  if ! apply_conf_with_rollback "$tmp_challenge" "$challenge_conf" >&2; then
    rm -f "$tmp_challenge"
    return 1
  fi
  rm -f "$tmp_challenge"
  echo "$challenge_conf"
}

cleanup_http_challenge_server() {
  local challenge_conf="$1"
  if [[ -z "$challenge_conf" ]]; then
    NX_ACME_PENDING='' nx_transaction nx_acme_sync_routes
    return $?
  fi
  nx_transaction nx_remove_conf "$challenge_conf"
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

  # 2) 本机80监听检查（ss/netstat//proc 兜底，BusyBox 兼容）
  if ! nginx_port_listening 80; then
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
    echo "2) 启停当前 ACME 账户全部证书的续期"
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
          if confirm "当前 ACME 账户全部证书的续期已开启，是否全部关闭？"; then
            disable_acme_cron
          fi
        else
          if confirm "当前 ACME 账户全部证书的续期未开启，是否全部开启？"; then
            enable_acme_cron
          fi
        fi
        pause
        return 0
        ;;
      3)
        # Match the locked deletion check: active includes and structured TLS
        # directives, not comments or unreferenced disabled/backup files.
        if ! nx_acme_assert_unreferenced "$domain"; then
          warn "证书 ${domain} 的活动引用检查未通过，已拒绝删除。"
          warn "请先停用对应站点 HTTPS 或手动移除证书引用，再删除证书。"
          pause
          return 1
        fi

        if ! confirm "确认删除证书 ${domain} ?"; then
          info "已取消。"
          pause
          return 0
        fi

        nx_delete_certificate "$domain" || return 1
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
      echo "$((i+1))) ${certs[$i]}  [账户级续期: ${renew_status}]"
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


# Called after the mutation, inside the configuration transaction, before access
# rules/test/reload. A retained certificate keeps its port-80 route even when its
# application is disabled or removed. Renderers always include their redirect;
# this reconciler removes the now redundant helper atomically.
nx_acme_sync_routes() {
  local marker domain helper file match found tmp
  # Adopt legacy helpers only after checking their complete generated body.
  for helper in "$CONF_DIR"/acme-challenge-*.conf; do
    [[ -f "$helper" ]] || continue
    domain="${helper##*/acme-challenge-}"; domain="${domain%.conf}"
    valid_domain "$domain" || continue
    [[ -s "$SSL_DIR/$domain/fullchain.pem" ]] || continue
    nx_acme_helper_owned "$helper" "$domain" || return 1
    marker="$CONF_DIR/.nx-acme-$domain.state"
    [[ -f "$marker" ]] || ${SUDO} touch "$marker" || return 1
  done
  for marker in "$CONF_DIR"/.nx-acme-*.state; do
    [[ -f "$marker" && ! -L "$marker" ]] || continue
    domain="${marker##*/.nx-acme-}"; domain="${domain%.state}"
    valid_domain "$domain" || return 1
    helper="$CONF_DIR/acme-challenge-$domain.conf"
    if [[ -e "$helper" ]]; then
      nx_acme_helper_owned "$helper" "$domain" || { error "ACME helper 内容不受管：$helper"; return 1; }
    fi
    if [[ ! -s "$SSL_DIR/$domain/fullchain.pem" && "${NX_ACME_PENDING:-}" != "$domain" ]]; then
      ${SUDO} rm -f "$helper" "$marker" || return 1
      continue
    fi
    found=0
    for file in "$CONF_DIR"/*.conf; do
      [[ -f "$file" && "$file" != "$helper" ]] || continue
      # Maps, status servers and unrelated custom servers need no challenge
      # transformation. Inspect names first; only matching port-80 sites enter
      # the stricter preservation parser.
      match="$(nx_conf_query keys "$file")" || return 1
      if ! awk -F'|' -v domain="$domain" '$1==domain && $2 ~ /:80$/ {found=1} END {exit !found}' <<< "$match"; then continue; fi
      match="$(nx_https_transform challenge-probe "$file" "$domain" "$SSL_DIR" '')" || return 1
      if [[ "$match" == yes ]]; then
        tmp="$(mktemp)" || return 1
        nx_https_transform challenge "$file" "$domain" "$SSL_DIR" '' > "$tmp" || { rm -f "$tmp"; return 1; }
        if ! cmp -s "$tmp" "$file"; then
          if [[ -L "$file" ]] || ! nx_assert_single_link "$file"; then rm -f "$tmp"; return 1; fi
          ${SUDO} tee "$file" < "$tmp" >/dev/null || { rm -f "$tmp"; return 1; }
        fi
        rm -f "$tmp"
        found=1
      fi
    done
    if (( found )); then
      ${SUDO} rm -f "$helper" || return 1
    elif [[ ! -f "$helper" ]]; then
      tmp="$(mktemp)" || return 1
      nx_acme_render_helper "$domain" > "$tmp"
      install_managed_file "$tmp" "$helper" || { rm -f "$tmp"; return 1; }
      rm -f "$tmp"
    fi
  done
}

nx_acme_render_helper() {
  cat <<EOFHELPER
# nx_helper=acme-http01
server {
    listen 80;
    server_name $1;
    location ^~ /.well-known/acme-challenge/ {
        root /usr/share/nginx/html;
        default_type "text/plain";
        try_files \$uri =404;
    }
    location / { return 404; }
}
EOFHELPER
}

nx_acme_helper_owned() {
  [[ -f "$1" && ! -L "$1" ]] || return 1
  python3 - "$1" "$2" <<'PYHELPER'
import re,sys
text=open(sys.argv[1]).read()
text=re.sub(r'(?ms)^\s*# nx-access-begin\n.*?^\s*# nx-access-end\n','',text)
text=re.sub(r' default_server # nx-access-default\n','',text)
text=re.sub(r'(?m)#.*$','',text)
expected='server { listen 80; server_name '+sys.argv[2]+'; location ^~ /.well-known/acme-challenge/ { root /usr/share/nginx/html; default_type "text/plain"; try_files $uri =404; } location / { return 404; } }'
sys.exit(0 if re.sub(r'\s+',' ',text).strip()==expected else 1)
PYHELPER
}

# The privileged scheduler keeps ACME and hooks in their original account.
# Native root accounts must pass the same ownership checks on every execution.
# Only this generated, root-owned dispatcher and manifest run privileged.
nx_acme_privileged_paths() {
  NX_ACME_DISPATCH="/usr/local/libexec/nginxx-acme-$(id -u)"
  NX_ACME_MANIFEST="/var/lib/nginxx/acme-$(id -u).domains"
}

nx_acme_prepare_dispatch() {
  nx_acme_privileged_paths
  local tmp user
  user="$(id -un)" || return 1
  tmp="$(mktemp)" || return 1
  {
    printf '#!/bin/bash\nset -euo pipefail\nPATH=/usr/sbin:/usr/bin:/sbin:/bin\nexport PATH\n'
    printf 'account=%q\naccount_home=%q\nssl=%q\nmanifest=%q\n' "$user" "$HOME" "$SSL_DIR" "$NX_ACME_MANIFEST"
    cat <<'DISPATCH'
[[ $EUID == 0 ]] || exit 1
as_account() (
  # Hooks/daemons must not inherit the dispatcher lock descriptor.
  if [[ -n ${deploy_fd:-} ]]; then exec {deploy_fd}<&-; fi
  su -s /bin/sh "$account" -c "$1"
)
quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
# Validate before opening the lock inode; a substituted FIFO must not block.
python3 - "$ssl" <<'PYLOCKTRUST'
import os,stat,sys
path=sys.argv[1]
while True:
    s=os.lstat(path)
    if not stat.S_ISDIR(s.st_mode) or s.st_uid or s.st_mode&0o022:
        sys.exit('unsafe deployment lock directory: '+path)
    if path=='/': break
    path=os.path.dirname(path)
PYLOCKTRUST
# Lock order is deployment directory, then the configuration transaction.
# Cron, interactive deployment and deletion all use this same inode.
exec {deploy_fd}<"$ssl"
flock -x "$deploy_fd"
python3 - "$account" "$account_home" <<'PYROOTACCOUNT'
import os,pwd,stat,sys
if pwd.getpwnam(sys.argv[1]).pw_uid==0:
    home=sys.argv[2]; paths=[]; parent=home
    while True:
        paths.append(parent)
        if parent=='/': break
        parent=os.path.dirname(parent)
    for base,dirs,files in os.walk(home+'/.acme.sh',followlinks=False):
        paths.append(base); paths.extend(os.path.join(base,n) for n in dirs+files)
    for path in paths:
        s=os.lstat(path)
        if s.st_uid or s.st_mode&0o022 or (not stat.S_ISDIR(s.st_mode) and (not stat.S_ISREG(s.st_mode) or s.st_nlink!=1)):
            sys.exit('unsafe root ACME account: '+path)
PYROOTACCOUNT
# Interactive deployment is a rollback-capable transaction under deploy_fd.
# Account-owned staging is copied/restored as that account, never as root.
install_backup=''
manifest_backup=''
manifest_existed=0
install_committed=0
install_account_dir=''
restore_install() {
  local rc=$?
  trap - EXIT HUP INT TERM
  if [[ -n "$install_backup" ]]; then
    if (( ! install_committed )); then
      if ! as_account "rm -rf -- $(quote "$install_stage") && if test -e $(quote "$install_backup/original") || test -L $(quote "$install_backup/original"); then mv -- $(quote "$install_backup/original") $(quote "$install_stage"); fi"; then
        echo "account stage rollback failed; backup retained: $install_backup" >&2
        exit 1
      fi
      if [[ -n "$install_account_dir" ]]; then
        as_account "rm -rf -- $(quote "$install_account_dir") && if test -e $(quote "$install_backup/account") || test -L $(quote "$install_backup/account"); then mv -- $(quote "$install_backup/account") $(quote "$install_account_dir"); fi" || { echo "ACME domain state backup retained: $install_backup" >&2; exit 1; }
      fi
      if (( manifest_existed )); then
        mv -fT -- "$manifest_backup" "$manifest" || { echo "manifest backup retained: $manifest_backup" >&2; exit 1; }
      else
        rm -f -- "$manifest" || exit 1
      fi
    fi
    as_account "rm -rf -- $(quote "$install_backup")" || exit 1
    rm -f -- "$manifest_backup" || exit 1
  fi
  exit "$rc"
}
if [[ ${1:-} == install ]]; then
  domain=${2:-}
  [[ "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ && "$domain" != *..* ]] || exit 1
  install_stage="$account_home/.acme.sh/nginxx-deploy/$domain"
  # Check ownership conflicts before any staging write.
  python3 - "$manifest" "$domain" <<'PYINSTALLCHECK'
import glob,os,stat,sys
manifest,domain=sys.argv[1:]
for path in glob.glob(os.path.dirname(manifest)+'/acme-*.domains'):
    s=os.lstat(path)
    if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1 or s.st_uid or s.st_mode&0o022: sys.exit('unsafe manifest')
    if path!=manifest and domain in open(path).read().splitlines(): sys.exit('domain belongs to another account')
PYINSTALLCHECK
  manifest_backup=$(mktemp "$(dirname "$manifest")/.install-manifest-XXXXXX")
  if [[ -e "$manifest" ]]; then cp -a -- "$manifest" "$manifest_backup"; manifest_existed=1; fi
  install_backup=$(as_account "umask 077; mkdir -p $(quote "$account_home/.acme.sh/nginxx-deploy") && mktemp -d $(quote "$account_home/.acme.sh/nginxx-deploy/.rollback-XXXXXX")") || { rm -f -- "$manifest_backup"; exit 1; }
  # Finish the snapshot before arming rollback; failure here has not changed stage.
  if ! as_account "if test -e $(quote "$install_stage") || test -L $(quote "$install_stage"); then cp -a -- $(quote "$install_stage") $(quote "$install_backup/original"); fi"; then
    as_account "rm -rf -- $(quote "$install_backup")"; rm -f -- "$manifest_backup"; exit 1
  fi
  install_account_dir="$account_home/.acme.sh/$domain"
  [[ ! -d "$account_home/.acme.sh/${domain}_ecc" ]] || install_account_dir="$account_home/.acme.sh/${domain}_ecc"
  if ! as_account "if test -e $(quote "$install_account_dir") || test -L $(quote "$install_account_dir"); then cp -a -- $(quote "$install_account_dir") $(quote "$install_backup/account"); fi"; then
    as_account "rm -rf -- $(quote "$install_backup")"; rm -f -- "$manifest_backup"; exit 1
  fi
  trap restore_install EXIT
  trap 'exit 1' HUP INT TERM
  as_account "umask 077; mkdir -p $(quote "$install_stage") && HOME=$(quote "$account_home") $(quote "$account_home/.acme.sh/acme.sh") --install-cert -d $(quote "$domain") $([[ ! -d "$account_home/.acme.sh/${domain}_ecc" ]] || printf -- '--ecc') --key-file $(quote "$install_stage/privkey.pem") --fullchain-file $(quote "$install_stage/fullchain.pem") --reloadcmd ':'"
  python3 - "$manifest" "$domain" <<'PYINSTALLREGISTER'
import os,sys,tempfile
path,domain=sys.argv[1:]
lines=open(path).read().splitlines() if os.path.exists(path) else []
if domain not in lines: lines.append(domain)
fd,tmp=tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd,'w') as out: out.write(''.join(x+'\n' for x in lines))
os.replace(tmp,path)
PYINSTALLREGISTER
fi
if [[ ${1:-} == cron ]]; then
  (exec {deploy_fd}<&-; as_account "HOME=$(quote "$account_home") $(quote "$account_home/.acme.sh/acme.sh") --cron --home $(quote "$account_home/.acme.sh")") || exit $?
fi
python3 - "$ssl" "$manifest" "$account" "$account_home" <<'PYPUBLISH'
import os,sys,stat,tempfile,subprocess,shutil,glob,re,signal
ssl,manifest,account,home=sys.argv[1:]
def trusted(path, directory=False):
    st=os.lstat(path)
    if st.st_uid or st.st_mode & 0o022 or (not stat.S_ISDIR(st.st_mode) and (not stat.S_ISREG(st.st_mode) or st.st_nlink!=1)):
        raise RuntimeError('unsafe privileged destination: '+path)
    if directory:
        if not stat.S_ISDIR(st.st_mode): raise RuntimeError('not a directory: '+path)
    elif not stat.S_ISREG(st.st_mode) or st.st_nlink!=1:
        raise RuntimeError('not a single-link regular file: '+path)
    parent=os.path.dirname(path)
    if path!='/': trusted(parent,True)
def run(args,**kwargs):
    return subprocess.run(args,check=True,close_fds=True,**kwargs)
def reload():
    run(['nginx','-t'])
    if shutil.which('systemctl') and os.path.isdir('/run/systemd/system'):
        run(['systemctl','reload','nginx'])
    elif shutil.which('rc-service'): run(['rc-service','nginx','reload'])
    elif os.access('/etc/init.d/nginx',os.X_OK): run(['/etc/init.d/nginx','reload'])
    else: run(['nginx','-s','reload'])
def output(args): return subprocess.check_output(args,stderr=subprocess.DEVNULL,close_fds=True)
trusted(ssl,True); trusted(manifest)
domains=open(manifest).read().splitlines()
plans=[]; published=[]
def interrupted(signum,frame): raise RuntimeError('deployment interrupted')
for sig in (signal.SIGTERM,signal.SIGINT,signal.SIGHUP): signal.signal(sig,interrupted)
try:
    for domain in domains:
        if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9.-]*',domain) or '..' in domain:
            raise RuntimeError('invalid domain')
        for other in glob.glob(os.path.dirname(manifest)+'/acme-*.domains'):
            trusted(other)
            if other!=manifest and domain in open(other).read().splitlines():
                raise RuntimeError('domain belongs to another ACME account: '+domain)
        dest=ssl+'/'+domain
        if not os.path.lexists(dest): os.mkdir(dest,0o755)
        trusted(dest,True)
        stage=tempfile.mkdtemp(prefix='.deploy-',dir=dest)
        plans.append(stage)
        for name in ('privkey.pem','fullchain.pem'):
            target=dest+'/'+name
            if os.path.lexists(target): trusted(target)
            # Opening and reading happens with the account's privileges. A
            # regular-file check prevents FIFOs/devices from blocking cron.
            reader="import os,stat,sys; f=os.open(sys.argv[1],os.O_RDONLY|os.O_NONBLOCK|os.O_NOFOLLOW); s=os.fstat(f); assert stat.S_ISREG(s.st_mode) and s.st_nlink==1; sys.stdout.buffer.write(os.read(f,4194305))"
            import shlex
            cmd=shlex.join(['python3','-c',reader,home+'/.acme.sh/nginxx-deploy/'+domain+'/'+name])
            with open(stage+'/'+name,'wb') as out: run(['su','-s','/bin/sh',account,'-c',cmd],stdout=out)
            if not 0<os.path.getsize(stage+'/'+name)<=4194304: raise RuntimeError('invalid certificate size')
            os.chmod(stage+'/'+name,0o600 if name=='privkey.pem' else 0o644)
            if os.path.exists(target):
                shutil.copy2(target,stage+'/'+name+'.old')
                st=os.stat(target); os.chown(stage+'/'+name+'.old',st.st_uid,st.st_gid)
        key=output(['openssl','pkey','-in',stage+'/privkey.pem','-pubout','-outform','DER'])
        public=output(['openssl','x509','-in',stage+'/fullchain.pem','-pubkey','-noout'])
        pub=run(['openssl','pkey','-pubin','-outform','DER'],input=public,stdout=subprocess.PIPE).stdout
        if key!=pub: raise RuntimeError('certificate/private key mismatch')
        run(['openssl','x509','-in',stage+'/fullchain.pem','-noout','-checkhost',domain],stdout=subprocess.DEVNULL)
        # checkhost prints a mismatch with success on some OpenSSL versions.
        import ssl as tls
        cert=tls._ssl._test_decode_cert(stage+'/fullchain.pem')
        names=[value for kind,value in cert.get('subjectAltName',()) if kind=='DNS']
        if not names:
            names=[value for rdns in cert.get('subject',()) for kind,value in rdns if kind=='commonName']
        def matches(name):
            name=name.lower(); host=domain.lower()
            return name==host or (name.startswith('*.') and host.count('.')==name.count('.') and host.endswith(name[1:]))
        if not any(matches(name) for name in names): raise RuntimeError('certificate does not cover domain')
        run(['openssl','crl2pkcs7','-nocrl','-certfile',stage+'/fullchain.pem'],stdout=subprocess.DEVNULL)
    for stage in plans:
        dest=os.path.dirname(stage)
        trusted(dest,True)
        for name in ('privkey.pem','fullchain.pem'):
            target=dest+'/'+name
            if os.path.lexists(target): trusted(target)
            # os.replace refuses directory targets instead of nesting files.
            os.replace(stage+'/'+name,target)
            published.append((stage,name,target))
    reload()
except BaseException:
    failed=False
    for stage,name,target in reversed(published):
        try:
            old=stage+'/'+name+'.old'
            if os.path.exists(old): os.replace(old,target)
            else: os.unlink(target)
        except OSError as exc:
            failed=True; print('rollback failed; backup retained: '+stage+': '+str(exc),file=sys.stderr)
    if published:
        try: reload()
        except Exception: print('old files restored; nginx reload failed',file=sys.stderr)
    if not failed:
        for stage in plans: shutil.rmtree(stage)
    raise
else:
    for stage in plans: shutil.rmtree(stage)
PYPUBLISH
install_committed=1
DISPATCH
  } > "$tmp"
  if ! ${SUDO} python3 - /usr/local/libexec /var/lib/nginxx "$SSL_DIR" <<'PYMKTRUST'
import os,sys,stat
def prepare(path):
    if path!='/': prepare(os.path.dirname(path))
    if not os.path.lexists(path): os.mkdir(path,0o755)
    st=os.lstat(path)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid or st.st_mode&0o022:
        sys.exit('unsafe privileged ACME directory: '+path)
for path in sys.argv[1:]: prepare(os.path.abspath(path))
PYMKTRUST
  then rm -f "$tmp"; return 1; fi
  # Every privileged destination ancestor must resist the ACME account's writes.
  if ! ${SUDO} python3 - /usr/local/libexec /var/lib/nginxx "$SSL_DIR" <<'PYTRUST'
import os,sys,stat
for path in sys.argv[1:]:
    path=os.path.abspath(path)
    while True:
        st=os.lstat(path)
        if stat.S_ISLNK(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o022:
            sys.exit('unsafe privileged ACME destination: '+path)
        if path=='/': break
        path=os.path.dirname(path)
PYTRUST
  then rm -f "$tmp"; return 1; fi
  if ! ${SUDO} python3 - "$NX_ACME_DISPATCH" <<'PYDISPATCHTARGET'
import os,stat,sys
path=sys.argv[1]
if os.path.lexists(path):
    s=os.lstat(path)
    if not stat.S_ISREG(s.st_mode) or s.st_nlink!=1 or s.st_uid or s.st_mode&0o022:
        sys.exit('unsafe dispatcher target')
PYDISPATCHTARGET
  then rm -f "$tmp"; return 1; fi
  # Never truncate a dispatcher another cron/install process is executing.
  local dispatch_stage
  dispatch_stage="$(${SUDO} mktemp "${NX_ACME_DISPATCH}.stage.XXXXXX")" || { rm -f "$tmp"; return 1; }
  if ! ${SUDO} install -o root -g root -m 0700 "$tmp" "$dispatch_stage" ||
     ! ${SUDO} mv -fT -- "$dispatch_stage" "$NX_ACME_DISPATCH"; then
    ${SUDO} rm -f -- "$dispatch_stage"
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}

# shellcheck disable=SC2031
nx_acme_privileged_cron() (
  local scheduler_fd
  exec {scheduler_fd}<"$SSL_DIR" || return 1
  [[ ${NX_ACME_SCHEDULER_HELD:-0} == 1 || ${NX_ACME_LOCK_HELD:-0} == 1 ]] || flock -x "$scheduler_fd" || return 1
  local mode="$1" current updated
  nx_acme_privileged_paths
  command -v crontab >/dev/null 2>&1 || { error "ACME 续期需要 crontab。"; return 1; }
  local -a scheduler=(crontab)
  [[ -z "$SUDO" ]] || scheduler=("$SUDO" crontab)
  current="$(nx_acme_read_crontab "${scheduler[@]}")" || return 1
  updated="$(printf '%s\n' "$current" | python3 -c '
import sys,shlex
path,mode=sys.argv[1:]
for line in sys.stdin.read().splitlines():
    words=line.split(None,5)
    try: owned=len(words)==6 and shlex.split(words[5])==[path,"cron"]
    except ValueError: owned=False
    if not owned: print(line)
if mode=="enable": print("0 3 * * * "+shlex.quote(path)+" cron")
' "$NX_ACME_DISPATCH" "$mode")" || return 1
  printf '%s\n' "$updated" | ${SUDO} crontab -
)

nx_acme_prepare_webroot() {
  [[ $EUID -ne 0 ]] || return 0
  local path=/usr/share/nginx/html/.well-known/acme-challenge uid
  uid="$(id -u)"
  ${SUDO} mkdir -p "$path" || return 1
  # Only the token directory is delegated, never the site root. Do not seize
  # another account's challenge directory or follow administrator symlinks.
  ${SUDO} python3 - "$path" "$uid" <<'PYWEBROOT'
import os,sys,stat
path,uid=sys.argv[1],int(sys.argv[2]); st=os.lstat(path)
if not stat.S_ISDIR(st.st_mode) or st.st_uid not in (0,uid):
    sys.exit('HTTP-01 webroot belongs to another account; use DNS-01')
parent=os.path.dirname(path)
while parent!='/':
    p=os.lstat(parent)
    if not stat.S_ISDIR(p.st_mode) or p.st_uid!=0 or p.st_mode & 0o022:
        sys.exit('unsafe HTTP-01 webroot parent')
    parent=os.path.dirname(parent)
if st.st_uid==0:
    if os.listdir(path): sys.exit('root HTTP-01 webroot is in use; use DNS-01')
    os.chown(path,uid,-1)
os.chmod(path,0o755)
PYWEBROOT
}

nx_acme_prepare_routes() {
  local domain="$1"
  valid_domain "$domain" || return 1
  ${SUDO} touch "$CONF_DIR/.nx-acme-$domain.state" || return 1
  nx_acme_sync_routes
}

# Manifest mutations serialize with publication on the SSL directory inode.
# Called within the lock-owning uninstall subshell when present.
# shellcheck disable=SC2031
nx_acme_manifest_change() {
  nx_acme_privileged_paths
  ${SUDO} python3 - "$SSL_DIR" "$NX_ACME_MANIFEST" "$1" "$2" "${NX_ACME_LOCK_HELD:-0}" <<'PYMANIFEST'
import os,sys,stat,glob,fcntl,tempfile
ssl,manifest,domain,action,held=sys.argv[1:]
fd=os.open(ssl,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
if held!='1': fcntl.flock(fd,fcntl.LOCK_EX)
parent=os.path.dirname(manifest)
# Legacy root deployments have no manifest to update.
if action=='remove' and not os.path.lexists(manifest): sys.exit(0)
for path in (ssl,parent):
    while True:
        st=os.lstat(path)
        if not stat.S_ISDIR(st.st_mode) or st.st_uid or st.st_mode&0o022: sys.exit('unsafe manifest destination')
        if path=='/': break
        path=os.path.dirname(path)
for other in glob.glob(parent+'/acme-*.domains'):
    st=os.lstat(other)
    if not stat.S_ISREG(st.st_mode) or st.st_nlink!=1 or st.st_uid or st.st_mode&0o022: sys.exit('unsafe manifest')
    if other!=manifest and domain in open(other).read().splitlines(): sys.exit('domain belongs to another account')
lines=open(manifest).read().splitlines() if os.path.exists(manifest) else []
if action=='add' and domain not in lines: lines.append(domain)
if action=='remove': lines=[x for x in lines if x!=domain]
fd,tmp=tempfile.mkstemp(dir=parent)
with os.fdopen(fd,'w') as out: out.write(''.join(x+'\n' for x in lines))
os.replace(tmp,manifest)
PYMANIFEST
}
nx_acme_register_domain() { nx_acme_manifest_change "$1" add; }
nx_acme_forget_deployment() {
  nx_acme_manifest_change "$1" remove
}

# Root and ordinary deletion refuse another account's explicitly owned domain.
nx_acme_assert_domain_owner() {
  nx_acme_privileged_paths
  ${SUDO} python3 - "$NX_ACME_MANIFEST" "$1" <<'PYOWNER'
import glob,sys,os
manifest,domain=sys.argv[1:]
for other in glob.glob(os.path.dirname(manifest)+'/acme-*.domains'):
    if other!=manifest and domain in open(other).read().splitlines():
        sys.exit('domain belongs to another ACME account: '+domain)
PYOWNER
}

nx_acme_check_account_identity() {
  [[ $EUID -eq 0 ]] || return 0
  python3 - "$HOME" <<'PYIDENTITY'
import os,sys,stat
home=sys.argv[1]
paths=[home,home+'/.acme.sh']
parent=os.path.dirname(home)
while parent!='/':
    paths.append(parent); parent=os.path.dirname(parent)
paths.append('/')
for base,dirs,files in os.walk(home+'/.acme.sh',followlinks=False):
    paths.extend(os.path.join(base,n) for n in dirs+files)
for path in paths:
    st=os.lstat(path)
    if st.st_uid!=0 or st.st_mode & 0o022 or (not stat.S_ISDIR(st.st_mode) and (not stat.S_ISREG(st.st_mode) or st.st_nlink!=1)):
        sys.exit('Refusing privileged execution of a non-root ACME account: '+path)
PYIDENTITY
}

nx_acme_account_crontab() {
  if [[ $EUID -ne 0 ]]; then
    ${SUDO} crontab -u "$(id -un)" "$@"
  else
    crontab "$@"
  fi
}

# Back up all account/deployed material before the first destructive action.
# Config/helper removal is transactional; restore certificate material as well
# if removal, validation, or reload fails.
# Dynamic lock locals are inherited from the uninstall caller, never read after it.
# shellcheck disable=SC2031
nx_delete_certificate() (
  local certificate_lock_fd certificate_conf_fd
  exec {certificate_lock_fd}<"$SSL_DIR" || return 1
  [[ ${NX_ACME_LOCK_HELD:-0} == 1 ]] || flock -x "$certificate_lock_fd" || return 1
  exec {certificate_conf_fd}<"$CONF_DIR" || return 1
  flock -x "$certificate_conf_fd" || return 1
  nx_transaction_paths_safe || return 1
  # The service subprocess must not retain the outer deployment lock.
  local original_reload
  original_reload="$(declare -f reload_nginx_safe)" || return 1
  eval "${original_reload/reload_nginx_safe/nx_certificate_reload_original}"
  reload_nginx_safe() (
    exec {certificate_lock_fd}<&-
    exec {certificate_conf_fd}<&-
    if [[ -n ${uninstall_fd:-} ]]; then exec {uninstall_fd}<&-; fi
    nx_certificate_reload_original
  )
  nx_delete_certificate_locked "$@"
)
nx_delete_certificate_locked() {
  local domain="$1" backup path rc=0
  valid_domain "$domain" || return 1
  nx_acme_assert_domain_owner "$domain" || return 1
  nx_acme_assert_unreferenced "$domain" || return 1
  [[ ! -x "$HOME/.acme.sh/acme.sh" ]] || nx_acme_check_account_identity || return 1
  backup="$(mktemp -d /tmp/nginxx-cert-delete-XXXXXX)" || return 1
  local i failed
  local -a paths=("$SSL_DIR/$domain" "$HOME/.acme.sh/$domain" "$HOME/.acme.sh/${domain}_ecc"
    "$HOME/.acme.sh/nginxx-deploy/$domain" "$HOME/.acme.sh/account.conf" "$NX_ACME_MANIFEST")
  for i in "${!paths[@]}"; do
    path="${paths[$i]}"
    if [[ -e "$path" || -L "$path" ]]; then
      ${SUDO} cp -a -- "$path" "$backup/$i" || { ${SUDO} rm -rf "$backup"; return 1; }
    fi
  done
  ${SUDO} cp -a "$CONF_DIR" "$backup/conf" || { ${SUDO} rm -rf "$backup"; return 1; }
  nx_certificate_restore() {
    failed=0
    for i in "${!paths[@]}"; do
      path="${paths[$i]}"
      ${SUDO} rm -rf -- "$path" || failed=1
      if [[ -e "$backup/$i" || -L "$backup/$i" ]]; then
        ${SUDO} cp -a -- "$backup/$i" "$path" || failed=1
      fi
    done
    # Keep the configuration directory inode: its flock is still held.
    ${SUDO} find "$CONF_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || failed=1
    ${SUDO} cp -a "$backup/conf/." "$CONF_DIR/" || failed=1
    if [[ ${NX_ACME_UNINSTALL_MODE:-online} != offline ]]; then
      reload_nginx_safe || failed=1
    fi
    if (( failed )); then
      error "证书恢复失败；备份保留：$backup"
    else
      ${SUDO} rm -rf "$backup"
      error "证书删除失败，已恢复证书材料。"
    fi
    return 1
  }
  trap 'trap "" HUP INT TERM; nx_certificate_restore; exit 1' HUP INT TERM
  if [[ -x "$HOME/.acme.sh/acme.sh" ]]; then
    local -a ecc=()
    [[ ! -d "$HOME/.acme.sh/${domain}_ecc" ]] || ecc=(--ecc)
    "$HOME/.acme.sh/acme.sh" --remove -d "$domain" "${ecc[@]}" || rc=1
  fi
  if (( ! rc )); then
    rm -rf "$HOME/.acme.sh/$domain" "$HOME/.acme.sh/${domain}_ecc" "$HOME/.acme.sh/nginxx-deploy/$domain" || rc=1
    ${SUDO} rm -rf "$SSL_DIR/$domain" || rc=1
  fi
  if (( ! rc )); then nx_certificate_apply_removal || rc=1; fi
  if (( ! rc )); then NX_ACME_LOCK_HELD=1 nx_acme_forget_deployment "$domain" || rc=1; fi
  # No further mutations after commit; signals must not restore a deleted backup.
  trap '' HUP INT TERM
  if (( rc )); then nx_certificate_restore; return 1; fi
  ${SUDO} rm -rf "$backup"
}

# A missing table is normal; permission/I/O errors must never be mistaken for
# an empty table followed by destructive replacement.
nx_acme_read_crontab() {
  local diagnostic output rc
  diagnostic="$(mktemp)" || return 1
  if output="$("$@" -l 2> "$diagnostic")"; then
    rm -f "$diagnostic"
    printf '%s\n' "$output"
    return 0
  else
    rc=$?
  fi
  if [[ $rc == 1 ]] && { [[ ! -s "$diagnostic" ]] || grep -Eqi 'no crontab|No such file or directory' "$diagnostic"; }; then
    rm -f "$diagnostic"
    return 0
  fi
  cat "$diagnostic" >&2
  rm -f "$diagnostic"
  return "$rc"
}

# Call inside the transaction BEFORE moving/removing/replacing an active site.
# Covers legacy certificates even when their ACME account is not the current
# caller's account. Read only public deployed certificate presence; do not move
# or source anyone else's ACME account or credentials.
nx_acme_retain_conf_route() {
  local file="$1" rows name socket
  [[ -f "$file" && "$file" == *.conf ]] || return 0
  rows="$(nx_conf_query keys "$file")" || return 1
  while IFS='|' read -r name socket; do
    [[ "$socket" == *:80 && -s "$SSL_DIR/$name/fullchain.pem" ]] || continue
    valid_domain "$name" || continue
    ${SUDO} touch "$CONF_DIR/.nx-acme-$name.state" || return 1
  done <<< "$rows"
}

# Explicit manifests are authoritative. Legacy accounts own only domains with
# their own ACME account directory; never infer ownership from the shared SSL tree.
nx_acme_owned_domains() {
  nx_acme_privileged_paths
  if ${SUDO} test -f "$NX_ACME_MANIFEST"; then
    ${SUDO} cat "$NX_ACME_MANIFEST"
  else
    local path domain
    for path in "$HOME/.acme.sh"/*; do
      [[ -d "$path" && ! -L "$path" ]] || continue
      domain="${path##*/}"; domain="${domain%_ecc}"
      valid_domain "$domain" || continue
      [[ -f "$path/$domain.conf" ]] || continue
      nx_acme_assert_domain_owner "$domain" || return 1
      printf '%s\n' "$domain"
    done
  fi
}

# Inspect active includes (including custom paths), not server_name: aliases can
# share another site's key. Offline is explicit and only for a removed nginx.
nx_acme_assert_unreferenced() {
  [[ ${NX_ACME_UNINSTALL_MODE:-online} != offline ]] || return 0
  ${SUDO} python3 - "$NGINX_MAIN_CONF" "$CONF_DIR" "$SSL_DIR/$1" "$HOME/.acme.sh/$1" "$HOME/.acme.sh/${1}_ecc" <<'PYREF'
import glob,os,shlex,sys
main,conf,*roots=sys.argv[1:]
roots=[os.path.realpath(p) for p in roots]
seen=set()
def scan(path):
    path=os.path.realpath(path)
    if path in seen: return
    seen.add(path)
    with open(path) as f:
        lex=shlex.shlex(f, posix=True, punctuation_chars=';{}')
        lex.whitespace_split=True
        tokens=list(lex)
    directive=[]
    for token in tokens:
        if token and all(c in ';{}' for c in token):
            if directive:
                key,*args=directive
                if key=='include':
                    if len(args)!=1 or '$' in args[0]: raise ValueError('ambiguous include')
                    pattern=args[0] if os.path.isabs(args[0]) else os.path.join(os.path.dirname(main),args[0])
                    matches=glob.glob(pattern)
                    if not matches and not glob.has_magic(pattern): raise ValueError('missing include: '+pattern)
                    for child in matches: scan(child)
                elif key in ('ssl_certificate','ssl_certificate_key','ssl_trusted_certificate'):
                    for value in args:
                        if '$' in value: raise ValueError('dynamic certificate reference')
                        value=os.path.realpath(value if os.path.isabs(value) else os.path.join(os.path.dirname(main),value))
                        if any(value==r or value.startswith(r+os.sep) for r in roots):
                            raise ValueError('active certificate reference in '+path)
            directive=[]
        else: directive.append(token)
try:
    if os.path.isfile(main): scan(main)
    for path in glob.glob(conf+'/*.conf'): scan(path)
except (OSError,ValueError) as e:
    sys.exit(str(e))
PYREF
}

nx_certificate_apply_removal() {
  # Both callers own the directory lock and rollback snapshot. Route transforms
  # strip generated guards/default flags: restore them even for offline cleanup,
  # without recursively entering nx_transaction (and deadlocking its flock).
  nx_acme_sync_routes || return 1
  nx_access_sync_files || return 1
  if [[ ${NX_ACME_UNINSTALL_MODE:-online} != offline ]]; then
    # Certificate bytes changed even if configuration bytes are identical.
    reload_nginx_safe || return 1
  fi
}

# Noninteractive account transaction. Caller owns confirmations, not rollback.
# Usage: nx_acme_uninstall_account [online|offline]. Offline is reserved for a
# successfully removed nginx package and does not test/start/reload nginx.
# shellcheck disable=SC2030,SC2031
nx_acme_uninstall_account() (
  local NX_ACME_UNINSTALL_MODE="${1:-online}" NX_ACME_LOCK_HELD=1 uninstall_fd conf_fd
  [[ $NX_ACME_UNINSTALL_MODE == online || $NX_ACME_UNINSTALL_MODE == offline ]] || return 1
  [[ -d "$SSL_DIR" && ! -L "$SSL_DIR" && -d "$CONF_DIR" && ! -L "$CONF_DIR" ]] || return 1
  exec {uninstall_fd}<"$SSL_DIR" || return 1
  flock -x "$uninstall_fd" || return 1
  exec {conf_fd}<"$CONF_DIR" || return 1
  flock -x "$conf_fd" || return 1
  nx_transaction_paths_safe || return 1
  local owned domain backup path i rc=0 original_reload
  owned="$(nx_acme_owned_domains)" || return 1
  while IFS= read -r domain; do
    [[ -n "$domain" ]] || continue
    valid_domain "$domain" && nx_acme_assert_domain_owner "$domain" && nx_acme_assert_unreferenced "$domain" || return 1
  done <<< "$owned"
  [[ ! -x "$HOME/.acme.sh/acme.sh" ]] || nx_acme_check_account_identity || return 1
  nx_acme_privileged_paths
  backup="$(mktemp -d /tmp/nginxx-acme-uninstall-XXXXXX)" || return 1
  local -a paths=("$HOME/.acme.sh" "$EMAIL_CONF" "$DNS_CONF" "$NX_ACME_DISPATCH" "$NX_ACME_MANIFEST" "$CONF_DIR")
  while IFS= read -r domain; do
    [[ -z "$domain" ]] || paths+=("$SSL_DIR/$domain")
  done <<< "$owned"
  for path in "${NX_PERIODIC_DIR:-/etc/periodic}"/{daily,monthly}/acme-renew; do
    if nx_acme_periodic_owned "$path"; then paths+=("$path"); fi
  done
  for i in "${!paths[@]}"; do
    path="${paths[$i]}"
    if [[ -e "$path" || -L "$path" ]]; then
      ${SUDO} cp -a -- "$path" "$backup/$i" || { ${SUDO} rm -rf "$backup"; return 1; }
    fi
  done
  local -a root_cron=(crontab)
  [[ -z "$SUDO" ]] || root_cron=("$SUDO" crontab)
  if ! nx_acme_read_crontab "${root_cron[@]}" > "$backup/root-cron" ||
     ! nx_acme_read_crontab nx_acme_account_crontab > "$backup/account-cron"; then
    ${SUDO} rm -rf "$backup"; return 1
  fi
  original_reload="$(declare -f reload_nginx_safe)" || { ${SUDO} rm -rf "$backup"; return 1; }
  eval "${original_reload/reload_nginx_safe/nx_uninstall_reload_original}"
  reload_nginx_safe() (
    exec {uninstall_fd}<&-
    exec {conf_fd}<&-
    [[ $NX_ACME_UNINSTALL_MODE == offline ]] || nx_uninstall_reload_original
  )
  nx_uninstall_restore() {
    local failed=0
    for i in "${!paths[@]}"; do
      path="${paths[$i]}"
      if [[ "$path" == "$CONF_DIR" ]]; then
        # Preserve the locked directory inode.
        ${SUDO} find "$CONF_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || failed=1
        ${SUDO} cp -a "$backup/$i/." "$CONF_DIR/" || failed=1
      else
        ${SUDO} rm -rf -- "$path" || failed=1
        if [[ -e "$backup/$i" || -L "$backup/$i" ]]; then
          ${SUDO} cp -a -- "$backup/$i" "$path" || failed=1
        fi
      fi
    done
    "${root_cron[@]}" - < "$backup/root-cron" || failed=1
    nx_acme_account_crontab - < "$backup/account-cron" || failed=1
    if [[ -n "$owned" ]]; then reload_nginx_safe || failed=1; fi
    if (( failed )); then error "ACME 卸载恢复未完成；备份保留：$backup"
    else ${SUDO} rm -rf "$backup"; fi
    return 1
  }
  trap 'trap "" HUP INT TERM; nx_uninstall_restore; exit 1' HUP INT TERM
  disable_acme_cron || rc=1
  while IFS= read -r domain; do
    [[ -n "$domain" ]] || continue
    (( ! rc )) || break
    if [[ -x "$HOME/.acme.sh/acme.sh" ]]; then
      local -a ecc=()
      [[ ! -d "$HOME/.acme.sh/${domain}_ecc" ]] || ecc=(--ecc)
      "$HOME/.acme.sh/acme.sh" --remove -d "$domain" "${ecc[@]}" || { rc=1; break; }
    fi
    ${SUDO} rm -rf -- "$SSL_DIR/$domain" || rc=1
  done <<< "$owned"
  if (( ! rc )); then
    ${SUDO} rm -f -- "$NX_ACME_DISPATCH" "$NX_ACME_MANIFEST" || rc=1
    rm -rf -- "$HOME/.acme.sh" || rc=1
    rm -f -- "$EMAIL_CONF" "$DNS_CONF" || rc=1
  fi
  # Empty accounts have no certificate bytes/routes to reconcile; this also
  # permits cleanup of an unused ACME install on a host without nginx.
  if (( ! rc )) && [[ -n "$owned" ]]; then
    nx_certificate_apply_removal || rc=1
  fi
  trap '' HUP INT TERM
  if (( rc )); then nx_uninstall_restore; return 1; fi
  ${SUDO} rm -rf "$backup"
)
