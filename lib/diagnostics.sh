#!/usr/bin/env bash
# Read-only probes and monitoring; sourced eagerly and included in installed bundle.
# Display-only: never pass the redacted value to a network probe. Fail closed
# on ambiguous URLs, and never echo parser exceptions (which can contain input).
health_display_url() {
  local display
  if display="$(python3 - "$1" 2>/dev/null <<'PYURL'
import re
import sys
from urllib.parse import urlsplit, urlunsplit

try:
    raw = sys.argv[1]
    # urlsplit silently removes some controls; reject them before parsing.
    if any(ord(c) < 33 or 127 <= ord(c) <= 159 for c in raw) or "\\" in raw:
        raise ValueError()
    url = urlsplit(raw)
    if url.scheme.lower() not in ("http", "https") or not url.netloc or not url.hostname:
        raise ValueError()
    # Validate ports and percent escapes without decoding userinfo into output.
    _ = url.port
    if re.search(r"%(?![0-9a-fA-F]{2})", raw):
        raise ValueError()
    authority = url.netloc.rsplit("@", 1)[-1]
    if "@" in url.netloc:
        authority = "[redacted]@" + authority
    # Preserve parameter names/order (including duplicates); redact bare fields
    # too, because they may themselves be bearer tokens. Handle legacy ';'.
    query = "&".join((field.split("=", 1)[0] + "=[redacted]")
                     if "=" in field else "[redacted]"
                     for field in re.split(r"[&;]", url.query)) if url.query else ""
    print(urlunsplit((url.scheme, authority, url.path, query,
                     "[redacted]" if url.fragment else "")))
except Exception:
    print("[URL redacted: invalid]")
PYURL
)"; then
    printf '%s' "$display"
  else
    printf '%s' '[URL redacted: unavailable]'
  fi
}

health_probe_url() {
  local url="$1" resolve="${2:-}" out rc=0
  local -a args=(-sS -o /dev/null --connect-timeout 3 --max-time 8
    -w '%{http_code}|%{remote_ip}|%{url_effective}|%{ssl_verify_result}')
  # Never follow redirects locally: a redirect could escape the selected socket.
  # Never ignore certificate verification, including local probes behind a CDN.
  if [[ -n "$resolve" && "$resolve" != 0 ]]; then
    args+=(--noproxy '*' --resolve "$resolve")
  else
    args+=(-L --max-redirs 5)
  fi
  out="$(curl "${args[@]}" "$url" 2>/dev/null)" || rc=$?
  printf '%s|%s\n' "${out:-000|||}" "$rc"
}

health_probe_label() {
  local code="$1" verify="$2" rc="${3:-0}"
  if [[ "$verify" != 0 && -n "$verify" ]]; then echo '证书校验失败'; return 2; fi
  if [[ "$rc" != 0 ]]; then echo "探测失败(curl ${rc})"; return 2; fi
  case "$code" in
    2*|3*) echo '正常'; return 0 ;;
    401|403|404) echo '可访问但需确认'; return 1 ;;
    *) echo "异常(${code})"; return 2 ;;
  esac
}

# Return only normalized local TCP endpoints, never process arguments. A failed
# tool falls through; /proc requires both address families to avoid false safety.
health_tcp_listeners() {
  local table parsed
  if check_cmd ss && table="$(ss -lnt 2>/dev/null)"; then
    if parsed="$(printf '%s\n' "$table" | awk '
      $1=="State" {valid=1;next}
      $1=="LISTEN" && NF>=5 {valid=1;print $4;next}
      NF {bad=1}
      END {if(!valid || bad)exit 1}')"; then
      printf '%s\n' "$parsed"; return 0
    fi
  fi
  if check_cmd netstat && table="$(netstat -lnt 2>/dev/null)"; then
    if parsed="$(printf '%s\n' "$table" | awk '
      /^Active Internet/ || $1=="Proto" {valid=1;next}
      $1~/^tcp/ && $6=="LISTEN" && NF>=6 {valid=1;print $4;next}
      NF {bad=1}
      END {if(!valid || bad)exit 1}')"; then
      printf '%s\n' "$parsed"; return 0
    fi
  fi
  python3 - 2>/dev/null <<'PYLISTEN'
import ipaddress, pathlib, sys
try:
    endpoints = []
    for filename, width in (("/proc/net/tcp", 4), ("/proc/net/tcp6", 16)):
        for line in pathlib.Path(filename).read_text().splitlines()[1:]:
            fields = line.split()
            if fields[3] != "0A": continue
            host, port = fields[1].split(":")
            raw = bytes.fromhex(host)
            if len(raw) != width: raise ValueError()
            # proc represents each 32-bit word in native byte order.
            raw = b"".join(int.from_bytes(raw[i:i+4], sys.byteorder).to_bytes(4, 'big')
                           for i in range(0, width, 4))
            addr = str(ipaddress.ip_address(raw))
            endpoints.append(("[" + addr + "]" if width == 16 else addr) + ":" + str(int(port, 16)))
    print("\n".join(endpoints))
except Exception:
    sys.exit(1)
PYLISTEN
}

# Inspect only the known internal template backend, not arbitrary external URLs
# or container namespace mappings. Output contains a validated port, no URLs.
health_backend_listener_notice() {
  local file="$1" backend proxy table result
  backend="$(conf_meta_get "$file" backend_port)" || return 0
  [[ "$backend" =~ ^[0-9]{1,5}$ ]] || return 0
  (( 10#$backend > 0 && 10#$backend <= 65535 )) || return 0
  backend="$((10#$backend))"
  proxy="$(extract_proxy_pass "$file")" || return 0
  [[ "$proxy" == "http://127.0.0.1:${backend}" ]] || return 0
  if ! table="$(health_tcp_listeners)"; then
    echo "  后端监听 ${backend}: 未知（无法查询本机 TCP 监听；未判断外网可达性）"
    return 0
  fi
  result="$(printf '%s\n' "$table" | python3 -c '
import ipaddress, sys
port = int(sys.argv[1]); found = False; risky = False
try:
    for line in sys.stdin:
        if not line.strip(): continue
        host, number = line.strip().rsplit(":", 1)
        if int(number) != port: continue
        found = True
        host = host.strip("[]")
        if host == "*": risky = True; continue
        addr = ipaddress.ip_address(host)
        if not (addr.is_loopback or (getattr(addr, "ipv4_mapped", None) and addr.ipv4_mapped.is_loopback)):
            risky = True
    print("risk" if risky else "loopback" if found else "absent")
except Exception:
    print("unknown")
' "$backend" 2>/dev/null)" || result=unknown
  case "$result" in
    risk)
      echo "  后端监听风险 ${backend}: 存在通配/非回环 TCP 监听，可能通过 IP:端口 绕过 Nginx。"
      echo '  仅域名访问不拦截后端直连；防火墙及外网可达性未知。请自行限制后端监听或来源，保留 Nginx 可访问后端。' ;;
    loopback) echo "  后端监听 ${backend}: 仅回环（本机所见；未检查容器映射或防火墙）" ;;
    absent) echo "  后端监听 ${backend}: 未发现（本机所见；外网可达性未知）" ;;
    *) echo "  后端监听 ${backend}: 未知（无法识别监听信息；未判断外网可达性）" ;;
  esac
}

# Bounded read-only socket probes. TLS verification is deliberately separate
# from routing: the normal curl probe above remains certificate-validating.
health_socket_policy() {
  local selected="$1" inventory='' row file global=open known=1
  nx_conf_query health-main "$NGINX_MAIN_CONF" "$CONF_DIR" >/dev/null 2>&1 || known=0
  domain_only_state_is_enabled && global=strict
  if [[ -f "$DOMAIN_ONLY_STATE" ]] && ! grep -qxE 'DOMAIN_ONLY=[01]' "$DOMAIN_ONLY_STATE"; then known=0; fi
  for file in "$CONF_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    # Map-only helpers have no server and contribute no socket inventory.
    if ! row="$(nx_conf_query health-inventory "$file" 2>/dev/null)"; then known=0; continue; fi
    inventory+="$row"$'\n'
  done
  NX_HEALTH_INVENTORY="$inventory" python3 - "$selected" "$global" "$known" <<'PYPOLICY'
import os, sys, json, socket, ssl, ipaddress, time, signal
selected, inherited, known = sys.argv[1:]
rows = [r for line in os.environ['NX_HEALTH_INVENTORY'].splitlines() for r in json.loads(line)]
end = time.monotonic() + 12
budget = 24
def expired(*_):
    print("  本机策略: 未验证（12秒总预算耗尽）", flush=True)
    sys.exit(1)
signal.signal(signal.SIGALRM, expired)
signal.setitimer(signal.ITIMER_REAL, 12)
bad = False
unknown = False
seen = set()
def policy(row):
    if row['uncertain']: return 'unknown'
    if row['reject']: return 'reject'
    p = inherited if row['policy'] in ('', 'inherit') else row['policy']
    return p if p in ('strict', 'open') else 'unknown'
def probe(host, port, tls, sni, header, version):
    global budget
    if budget <= 0 or time.monotonic() >= end: return 'budget'
    budget -= 1
    timeout = min(1.0, max(.05, end-time.monotonic()))
    try:
        conn = socket.create_connection((host, port), timeout=timeout)
    except OSError: return 'connect-failed'
    try:
        with conn:
            if tls:
                ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE
                try: conn = ctx.wrap_socket(conn, server_hostname=sni)
                except ssl.SSLError as exc:
                    return 'tls-reject' if 'ALERT' in str(exc) else 'tls-failed'
            with conn:
                conn.settimeout(timeout)
                request = 'GET / HTTP/' + version + '\r\nConnection: close\r\n'
                if header is not None: request += 'Host: ' + header + '\r\n'
                conn.sendall((request+'\r\n').encode('ascii'))
                data = conn.recv(1024)
                if not data: return 'closed'
                first = data.split(b'\r\n', 1)[0].split()
                return first[1].decode('ascii') if len(first)>1 and first[0].startswith(b'HTTP/') else 'invalid-response'
    except (OSError, UnicodeError): return 'io-failed'
for row in rows:
    if row['file'] != selected or not row['names']: continue
    key = (row['socket'], row['tls'])
    if key in seen: continue
    seen.add(key)
    host, port = row['socket'].rsplit(':', 1)
    host = host.strip('[]')
    host = {'0.0.0.0':'127.0.0.1', '::':'::1'}.get(host, host)
    try: ipaddress.ip_address(host)
    except ValueError: unknown=True; continue
    name = row['names'][0]
    if name == '_': continue
    peers = [r for r in rows if r['socket'] == row['socket']]
    defaults = [r for r in peers if r['default']]
    default = policy(defaults[0]) if len(defaults)==1 else policy(peers[0]) if len(peers)==1 else 'unknown'
    default_reject = default == 'reject'
    own = policy(row)
    # Other address-specific/wildcard sockets may win selection; don't guess.
    if any(r['socket'].rsplit(':',1)[1] == port and r['socket'] != row['socket'] and
           (':' in r['socket'].rsplit(':',1)[0]) == (':' in host) for r in rows): default='unknown'
    trusted = known == '1' and not any(r['uncertain'] for r in peers)
    if sum(r['file'] == selected and r['tls'] == row['tls'] for r in peers) > 1:
        trusted = False  # one sample cannot certify other servers on this socket
    cases = [('合法Host', name, name, '1.1', 'accept' if own in ('strict','open') else 'unknown'),
             ('IP Host', name, ('['+host+']' if ':' in host else host), '1.1', 'reject' if own=='strict' and row['tls'] else ('reject' if default in ('strict','reject') else 'accept' if default=='open' else 'unknown')),
             ('未知Host', name, 'nx-health-unknown.invalid', '1.1', 'reject' if own=='strict' and row['tls'] else ('reject' if default in ('strict','reject') else 'accept' if default=='open' else 'unknown')),
             ('HTTP1.0无Host', name, None, '1.0', 'reject' if own=='strict' and row['tls'] else ('reject' if default in ('strict','reject') else 'accept' if default=='open' else 'unknown'))]
    if row['tls']:
        cases += [('未知SNI/合法Host', 'nx-health-unknown.invalid', name, '1.1', 'reject' if own=='strict' or default_reject else 'accept' if own=='open' and default in ('open','strict') else 'unknown'),
                  ('无SNI/合法Host', None, name, '1.1', 'reject' if own=='strict' or default_reject else 'accept' if own=='open' and default in ('open','strict') else 'unknown')]
    for label, sni, header, version, expected in cases:
        result = probe(host, int(port), row['tls'], sni, header, version)
        if not trusted: expected='unknown'
        rejected = result in ('closed','tls-reject')
        accepted = result.isdigit() and result not in ('400','421')
        if expected == 'unknown' or result in ('400','421','budget'):
            verdict='未验证（策略/协议/预算边界）'; unknown=True
        elif expected == 'reject' and rejected or expected == 'accept' and accepted:
            verdict='策略符合'
        elif result in ('connect-failed','io-failed','tls-failed','invalid-response'):
            verdict='未验证（连通性/握手失败）'; unknown=True
        else: verdict='策略不符（需核对生效配置）'; bad=True
        print('  本机策略 %s %s: %s | %s' % (row['socket'], label, result, verdict))
if not seen:
    print('  本机策略: 未验证（没有可识别 socket）'); unknown=True
print('  策略探测只验证上述本机入口样本；HTTP业务状态和证书校验另列，不证明后端无暴露。')
sys.exit(2 if bad else 1 if unknown else 0)
PYPOLICY
}

health_check_conf_file() {
  local conf_file="$1"
  local domain listen_port mode upstream_url stream_upstream_url stream_upstream_urls
  local scheme target_url status_label http_code remote_ip dns_ips tls_days verify_result effective_url probe_rc
  local upstream_http_code upstream_verify_result upstream_status upstream_rc
  local stream_http_code stream_verify_result stream_status stream_rc
  local -a stream_urls=()
  local idx prefix
  local status_ok=0

  [[ "$conf_file" == *.conf ]] || { info "$(basename "$conf_file")：已停用，未执行网络探测。"; return 0; }
  local actual tls
  actual="$(_extract_conf_meta "$conf_file")" || return 1
  IFS='|' read -r domain listen_port _ tls mode <<< "$actual"
  upstream_url="$(conf_meta_get "$conf_file" upstream_url)"
  stream_upstream_url="$(conf_meta_get "$conf_file" stream_upstream_url)"
  stream_upstream_urls="$(conf_meta_get "$conf_file" stream_upstream_urls)"
  scheme=http; [[ "$tls" == true ]] && scheme=https
  note "入口检查通过公共 DNS 访问（可能经过 CDN），不代表本机直连检查。"

  if [[ "$listen_port" == "80" && "$scheme" == "http" ]]; then
    target_url="http://${domain}"
  elif [[ "$listen_port" == "443" && "$scheme" == "https" ]]; then
    target_url="https://${domain}"
  else
    target_url="${scheme}://${domain}:${listen_port}"
  fi

  dns_ips="$(timeout 3s getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd ',' - || true)"
  [[ -z "$dns_ips" ]] && dns_ips="未解析"

  IFS='|' read -r http_code remote_ip effective_url verify_result probe_rc <<< "$(health_probe_url "$target_url" 0)"
  [[ -z "$http_code" ]] && http_code="000"

  if [[ "$scheme" == "https" ]]; then
    # shellcheck disable=SC2016
    tls_days="$(timeout 8s bash -c 'echo | openssl s_client -servername "$0" -connect "$0:$1" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null' "$domain" "$listen_port" | sed 's/notAfter=//' | xargs -I{} date -d '{}' +%s 2>/dev/null | awk -v now="$(date +%s)" '{if($1>0) printf "%d", int(($1-now)/86400); else print "-"}' || true)"
    [[ -z "$tls_days" ]] && tls_days="-"
  else
    tls_days="-"
    verify_result="0"
  fi

  status_label="$(health_probe_label "$http_code" "$verify_result" "${probe_rc:-0}")" || status_ok=$?

  # Use parsed sockets, including specific bindings and IPv6, instead of
  # assuming all sites are reachable at 127.0.0.1:443.
  local name socket address local_url local_result local_code local_verify local_rc local_label
  local local_report="" keys
  keys="$(nx_conf_query keys "$conf_file")" || return 2
  while IFS='|' read -r name socket; do
    [[ "$name" == "${domain,,}" && "${socket##*:}" == "$listen_port" ]] || continue
    address="${socket%:*}"
    case "$address" in 0.0.0.0) address=127.0.0.1 ;; '[::]') address='[::1]' ;; esac
    # A hostname listener cannot establish a verified local address without
    # checking the running socket table; report uncertainty instead.
    if [[ ! "$address" =~ ^[0-9.]+$ && "$address" != '['*']' ]]; then
      local_report+="  本机直连 ${socket}: N/A（监听地址不是IP）"$'\n'
      status_ok=2
      continue
    fi
    local_url="$target_url"
    local_result="$(health_probe_url "$local_url" "${domain}:${listen_port}:${address}")"
    IFS='|' read -r local_code _ _ local_verify local_rc <<< "$local_result"
    local_label="$(health_probe_label "$local_code" "$local_verify" "${local_rc:-0}")" || status_ok=2
    local_report+="  本机直连 ${socket} | HTTP: ${local_code} | ${local_label}"$'\n'
  done <<< "$keys"
  [[ -n "$local_report" ]] || { local_report='  本机直连: N/A（没有可识别监听）'; status_ok=2; }

  upstream_status="-"
  if [[ -n "$upstream_url" ]]; then
    IFS='|' read -r upstream_http_code _ _ upstream_verify_result upstream_rc <<< "$(health_probe_url "$upstream_url" 0)"
    upstream_status="$(health_probe_label "$upstream_http_code" "$upstream_verify_result" "${upstream_rc:-0}")" || { if (( status_ok < 1 )); then status_ok=1; fi; }

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
      IFS='|' read -r stream_http_code _ _ stream_verify_result stream_rc <<< "$(health_probe_url "$stream_upstream_url" 0)"
      prefix=""
      [[ -n "$stream_status" ]] && prefix=" | "
      local stream_label
      stream_label="$(health_probe_label "$stream_http_code" "$stream_verify_result" "${stream_rc:-0}")" || { if (( status_ok < 1 )); then status_ok=1; fi; }
      stream_status+="${prefix}${stream_label}"

    done
  fi

  echo "- $(basename "$conf_file")"
  echo "  域名: ${domain}"
  echo "  入口: $(health_display_url "$target_url")"
  printf '%s\n' "$local_report"
  health_socket_policy "$conf_file" || status_ok=2
  echo "  公网/CDN 协议: ${scheme^^} | HTTP: ${http_code} | 状态: ${status_label}"
  echo "  DNS: ${dns_ips}"
  [[ -n "$remote_ip" ]] && echo "  命中IP: ${remote_ip}"
  [[ -n "$effective_url" && "$effective_url" != "$target_url" ]] && echo "  最终跳转: $(health_display_url "$effective_url")"
  if [[ "$scheme" == "https" ]]; then
    echo "  证书剩余天数: ${tls_days}"
    echo "  公网证书校验: $( [[ "$verify_result" == "0" && "${probe_rc:-0}" == 0 ]] && echo "通过" || echo "未通过/未完成(${verify_result:-N/A})" )"
  fi
  if [[ "$mode" == "external" ]]; then
    echo "  主上游: $(health_display_url "$upstream_url")"
    echo "  主上游状态: ${upstream_status}"
    if [[ ${#stream_urls[@]} -gt 0 ]]; then
      printf '  推流上游:'
      for stream_upstream_url in "${stream_urls[@]}"; do
        printf ' %s' "$(health_display_url "$stream_upstream_url")"
      done
      printf '\n'
      echo "  推流上游状态: ${stream_status}"
    fi
  else
    echo "  后端端口: $(conf_meta_get "$conf_file" backend_port)"
    health_backend_listener_notice "$conf_file"
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
          info "检查完成：${total} 个站点的已执行检查通过（不代表后端无暴露）。"
        else
          warn "检查完成：${total} 个站点中有 ${bad} 个异常或未验证项，请分别核对连通性、业务响应和策略检查。"
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

# Monitoring never creates/reloads configuration merely by opening the screen.
ensure_status_endpoint() {
  nx_stub_status >/dev/null
}

nx_stub_status() {
  local body
  body="$(curl --noproxy '*' -fsS --connect-timeout 1 --max-time 2 \
    http://127.0.0.1:8088/nginx_status 2>/dev/null)" || return 1
  printf '%s\n' "$body" | awk '
    NR==1 && $0 ~ /^Active connections: [0-9]+[[:space:]]*$/ {a=$3;ok++}
    NR==2 && $0 ~ /^server accepts handled requests[[:space:]]*$/ {ok++}
    NR==3 && NF==3 && $1~/^[0-9]+$/ && $2~/^[0-9]+$/ && $3~/^[0-9]+$/ {ac=$1;h=$2;r=$3;ok++}
    NR==4 && NF==6 && $1=="Reading:" && $3=="Writing:" && $5=="Waiting:" && $2~/^[0-9]+$/ && $4~/^[0-9]+$/ && $6~/^[0-9]+$/ {rd=$2;w=$4;wt=$6;ok++}
    END {if(ok!=4 || NR!=4)exit 1; print a,ac,h,r,rd,w,wt}'
}

sample_clock() {
  # Linux uptime is monotonic, including BusyBox systems.
  awk '{print $1}' /proc/uptime
}

sample_rate() {
  awk -v now="$1" -v prev="$2" -v elapsed="$3" -v scale="${4:-1}" 'BEGIN {d=now-prev; if(d<0)d=0; if(elapsed<=0){print "N/A";exit} printf "%.2f", d/elapsed/scale}'
}

nginx_proc_counters() {
  local st line rest
  local -a fields
  for st in /proc/[0-9]*/stat; do
    IFS= read -r line < "$st" 2>/dev/null || continue
    [[ "$line" == *'(nginx)'* ]] || continue
    rest="${line##*) }"
    read -r -a fields <<< "$rest"
    [[ ${#fields[@]} -ge 22 ]] || continue
    printf '%s %s\n' "$((fields[11]+fields[12]))" "${fields[21]}"
  done | awk '{ticks+=$1;rss+=$2} END {printf "%.0f %.0f\n",ticks,rss}'
}

show_nginx_realtime_status() {
  require_nginx_installed || return 1


  local prev_requests=0 prev_rx=0 prev_tx=0 initialized=0 prev_time=0 prev_ticks=0

  while true; do
    local now elapsed
    now="$(sample_clock)"
    elapsed="$(awk -v n="$now" -v p="$prev_time" 'BEGIN{print n-p}')"
    local stat active reading writing waiting accepts handled requests qps
    local cpu mem workers master_pid start_time rx tx rx_rate tx_rate

    stat="$(nx_stub_status)" || stat=""

    active="N/A"
    reading="N/A"
    writing="N/A"
    waiting="N/A"
    accepts="N/A"
    handled="N/A"
    requests="N/A"
    qps="N/A"

    if [[ -n "$stat" ]]; then
      read -r active accepts handled requests reading writing waiting <<< "$stat"
    fi
    if [[ "$requests" =~ ^[0-9]+$ && "$prev_requests" =~ ^[0-9]+$ && $initialized -eq 1 ]]; then
      qps="$(sample_rate "$requests" "$prev_requests" "$elapsed")"
    fi

    local ticks rss hz page_size mem_total
    read -r ticks rss < <(nginx_proc_counters)
    hz="$(getconf CLK_TCK 2>/dev/null || echo 100)"
    page_size="$(getconf PAGESIZE 2>/dev/null || echo 4096)"
    mem_total="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)"
    cpu="N/A"
    if [[ $initialized -eq 1 ]]; then
      cpu="$(sample_rate "$ticks" "$prev_ticks" "$elapsed" "$(awk -v h="$hz" 'BEGIN{print h/100}')")"
    fi
    prev_ticks="$ticks"
    mem="$(awk -v r="$rss" -v p="$page_size" -v m="$mem_total" 'BEGIN{if(m>0)printf "%.1f",r*p/1024/m*100;else print "N/A"}')"

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
      rx_rate="$(sample_rate "$rx" "$prev_rx" "$elapsed" 1048576)"
      tx_rate="$(sample_rate "$tx" "$prev_tx" "$elapsed" 1048576)"
    else
      rx_rate="N/A"
      tx_rate="N/A"
      initialized=1
    fi

    prev_requests="$requests"
    prev_time="$now"
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
状态端点: $( [[ -n "$stat" ]] && echo "已验证 stub_status" || echo "N/A（端点不可达或内容不符；不会自动占用8088）" )
RX: ${rx_rate} MiB/s
TX: ${tx_rate} MiB/s

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

  local host_log_file="${NX_HOST_LOG:-/var/log/nginx/access.host.log}"
  local prev_rx=0 prev_tx=0 initialized=0 prev_time=0

  while true; do
    local now elapsed
    now="$(sample_clock)"
    elapsed="$(awk -v n="$now" -v p="$prev_time" 'BEGIN{print n-p}')"
    local rx tx rx_rate tx_rate rx_total_mb tx_total_mb
    # Strip leading whitespace so $1 is always the interface name
    rx="$(sed 's/^[[:space:]]*//' /proc/net/dev 2>/dev/null | awk -F'[: ]+' 'NR>2 && $1!="lo" {s+=$2} END{print s+0}')"
    tx="$(sed 's/^[[:space:]]*//' /proc/net/dev 2>/dev/null | awk -F'[: ]+' 'NR>2 && $1!="lo" {s+=$10} END{print s+0}')"

    if [[ $initialized -eq 1 ]]; then
      rx_rate="$(sample_rate "$rx" "$prev_rx" "$elapsed" 1048576)"
      tx_rate="$(sample_rate "$tx" "$prev_tx" "$elapsed" 1048576)"
    else
      rx_rate="N/A"
      tx_rate="N/A"
      initialized=1
    fi

    prev_time="$now"
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
RX速率: ${rx_rate} MiB/s
TX速率: ${tx_rate} MiB/s

当前启用配置流量（最近5000日志，优先按 Host 专用日志统计）
EOF

    mapfile -t enabled_confs < <(list_managed_conf_files 0)
    if [[ ${#enabled_confs[@]} -eq 0 ]]; then
      echo "- 无启用配置"
    else
      nx_traffic_rows "$host_log_file" "${enabled_confs[@]}"

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


# One log aggregation per refresh. keys uses the shared structural parser; no
# separate nginx grammar here. Multiple listeners/aliases map to one site.
nx_traffic_rows() {
  local logfile="$1"; shift
  local conf keys records="" name socket
  # Newer shared parsers can emit all SITE/KEY records in one invocation.
  # The fallback preserves source compatibility with the baseline parser.
  if records="$(nx_conf_query traffic "$@" 2>/dev/null)"; then
    records+=$'\n'
  else
    records=""
  for conf in "$@"; do
    keys="$(nx_conf_query keys "$conf")" || keys=""
    records+="SITE|$(basename "$conf")"$'\n'
    while IFS='|' read -r name socket; do
      [[ -n "$name" && -n "$socket" ]] || continue
      records+="KEY|$(basename "$conf")|${name}|${socket##*:}"$'\n'
    done <<< "$keys"
  done
  fi
  if [[ ! -r "$logfile" ]]; then
    for conf in "$@"; do echo "- $(basename "$conf") | 请求: N/A | 下行: N/A（需要 Host 专用日志）"; done
    return 0
  fi
  # nx1 host bytes server_port scheme server_name; old host bytes supported
  # explicitly as shared totals across ports. Never parse combined as host log.
  { printf '%s' "$records"; printf 'LOG\n'; tail -n 5000 "$logfile"; } | awk -F'|' '
    !logs && $1=="SITE" {sites[$2]=1;next}
    !logs && $1=="KEY" {key[$2 SUBSEP tolower($3) SUBSEP $4]=1; aliases[$2 SUBSEP tolower($3)]=1;known[$2]=1;next}
    $0=="LOG" {logs=1;next}
    logs {
      n=split($0,f,/[[:space:]]+/)
      modern=(n==6 && f[1]=="nx1" && f[3]~/^[0-9]+$/ && f[4]~/^[0-9]+$/ && f[5]~/^https?$/)
      legacy=(n==2 && f[2]~/^[0-9]+$/)
      if(!modern && !legacy){bad++;next}
      valid++;host=tolower(modern?f[2]:f[1]);sub(/\.$/,"",host)
      for(site in sites) {
        matchsite=modern ? ((site SUBSEP host SUBSEP f[4]) in key || (site SUBSEP tolower(f[6]) SUBSEP f[4]) in key) : ((site SUBSEP host) in aliases)
        if(matchsite){count[site]++;bytes[site]+=modern?f[3]:f[2]}
      }
      if(legacy)old=1
    }
    END {
      for(site in sites) {
        if(bad || !valid || !(site in known))printf "- %s | 请求: N/A | 下行: N/A（日志为空或格式不符）\n",site
        else printf "- %s | 请求: %d | 下行: %.2f MiB | %s\n",site,count[site]+0,bytes[site]/1048576,old?"Host日志：别名合计，同域名跨端口共享":"nx1日志：别名/端口合计，HTTP+HTTPS"
      }
    }'
}

# No sourcing state files, dependency setup, migration or acme invocation.
# Even a tampered DNS configuration must never execute or display its values.
system_info_panel() {
  python3 - "${NX_OS_RELEASE:-/etc/os-release}" "$CONF_DIR" "$SSL_DIR" "$DNS_CONF" "$HOME/.acme.sh/acme.sh" <<'PYINFO'
import pathlib, re, shlex, sys
osfile, conf, ssl, dns, acme = map(pathlib.Path, sys.argv[1:])
name = '未知'
try:
    for line in osfile.read_text().splitlines():
        if line.startswith('PRETTY_NAME='):
            fields = shlex.split(line.split('=', 1)[1])
            if len(fields) == 1: name = fields[0]
except (OSError, ValueError): pass
print('系统: ' + ''.join(c for c in name if c.isprintable()))
try: enabled = sum(p.is_file() for p in conf.glob('*.conf'))
except OSError: enabled = '未知'
print('已启用站点配置数: ' + str(enabled))
try: certs = sum(p.is_file() for p in ssl.glob('*/fullchain.pem'))
except OSError: certs = '未知'
print('已部署证书数: ' + str(certs))
print('acme.sh: ' + ('已安装' if acme.is_file() else '未安装'))
provider = '未配置/无法识别'
try:
    # save_dns_conf emits an unquoted fixed provider ID. Do not parse keys.
    values = re.findall(r'^DNS_PROVIDER=([a-z0-9_.-]+)$', dns.read_text(), re.M)
    known = {'cf','dp','ali','he','gd','hw','aws','google','cloudflare','dnspod','alidns','he.net','godaddy','huaweicloud','route53','gcp'}
    if len(values) == 1 and values[0] in known: provider = values[0]
except OSError: pass
print('DNS API 服务商: ' + provider)
print('DNS API 密钥: 完全隐藏（不显示长度或片段）')
PYINFO
  printf '内核/架构: %s / %s\n' "$(uname -r)" "$(uname -m)"
  printf 'Nginx 版本: %s\n' "$(nginx_local_version || true)"
  if pgrep -x nginx >/dev/null 2>&1; then echo 'Nginx 运行状态: 运行中'; else echo 'Nginx 运行状态: 未运行/无法查询'; fi
  # This helper only reads crontabs and owned periodic scripts.
  if nx_panel_has_acme_cron; then echo 'acme 账户级自动续期: 已配置'; else echo 'acme 账户级自动续期: 未检测到/不可读取'; fi
}

# Separate function-local scope also keeps bundle static analysis precise.
nx_panel_has_acme_cron() {
  local SUDO="${SUDO:+sudo -n}"
  has_acme_cron_task
}
