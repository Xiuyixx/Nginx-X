#!/usr/bin/env bash
# Read-only probes and monitoring; sourced eagerly and included in installed bundle.
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
    if [[ ! "$address" =~ ^[0-9.]+$ && "$address" != \[*\] ]]; then
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
  echo "  入口: ${target_url}"
  printf '%s\n' "$local_report"
  echo "  公网/CDN 协议: ${scheme^^} | HTTP: ${http_code} | 状态: ${status_label}"
  echo "  DNS: ${dns_ips}"
  [[ -n "$remote_ip" ]] && echo "  命中IP: ${remote_ip}"
  [[ -n "$effective_url" && "$effective_url" != "$target_url" ]] && echo "  最终跳转: ${effective_url}"
  if [[ "$scheme" == "https" ]]; then
    echo "  证书剩余天数: ${tls_days}"
    echo "  公网证书校验: $( [[ "$verify_result" == "0" && "${probe_rc:-0}" == 0 ]] && echo "通过" || echo "未通过/未完成(${verify_result:-N/A})" )"
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
