#!/usr/bin/env bash
# Sourced after nx.sh's legacy helpers. Mutations run inside nx_transaction.
# Policy metadata: access_policy=inherit|strict|open; access_default=<socket>[,...].
# Socket identity is an IP literal plus port (wildcard IPv4 is 0.0.0.0:PORT).

# Shared policy is data, never shell code. Personal email/DNS credentials stay
# in STATE_DIR. On first use preserve any deployed legacy strict policy even
# when the first administrator has no personal legacy state.
domain_only_state_is_enabled() {
  if [[ -f "$DOMAIN_ONLY_STATE" ]]; then
    grep -qx 'DOMAIN_ONLY=1' "$DOMAIN_ONLY_STATE"
    return
  fi
  [[ -f "$STATE_DIR/domain-only.conf" ]] && grep -qx 'DOMAIN_ONLY=1' "$STATE_DIR/domain-only.conf" && return 0
  local file
  while IFS= read -r file; do
    if grep -q '^ *# nx-access-begin$' "$file" &&
       ! grep -qE '^# access_policy=(strict|open)$' "$file"; then return 0; fi
  done < <(list_managed_conf_files 1)
  # Legacy catchalls predate explicit per-site policy metadata.
  if [[ -f "$(domain_only_conf_path)" ]] &&
     ! grep -q '^# nx-access-catchall=1$' "$(domain_only_conf_path)"; then return 0; fi
  return 1
}

nx_access_migrate_state() {
  [[ ! -L "$DOMAIN_ONLY_STATE" ]] || { nx_access_error '策略状态不能是符号链接'; return 1; }
  if [[ -e "$DOMAIN_ONLY_STATE" ]]; then
    [[ "$(cat "$DOMAIN_ONLY_STATE")" == 'DOMAIN_ONLY=0' || "$(cat "$DOMAIN_ONLY_STATE")" == 'DOMAIN_ONLY=1' ]] || {
      nx_access_error '共享策略状态无效'; return 1;
    }
    return 0
  fi
  local enabled=0
  domain_only_state_is_enabled && enabled=1
  nx_access_global_files "$enabled"
}

nx_access_error() { error "访问策略：$*" >&2; return 1; }

# A small lexical parser preserves every byte outside our marked insertions.
# It understands comments, quoted strings, escapes and nested blocks. Ambiguous
# includes/listeners/names are rejected instead of guessing or rebuilding a site.
# scan output: server-index|socket|ssl|default|names
nx_access_parse() {
  local file="$1" mode="${2:-scan}" strict="${3:-0}" defaults="${4:-}"
  local clean rc=0 owned=0
  if [[ "${5:-}" == prepared ]]; then
    clean="$file"
  else
    clean="$(mktemp)" || return 1
    owned=1
    nx_conf_query strip-access "$file" > "$clean" || { rm -f "$clean"; return 1; }
  fi
  awk -v mode="$mode" -v strict="$strict" -v defaults="$defaults" '
  function fail(s) { print "access policy: " FILENAME ": " s > "/dev/stderr"; bad=1; exit 1 }
  function ipv6(s, halves,l,r,nl,nr,i,out,a,b,parts,best,start,len,bestlen) {
    n=split(s,halves,"::"); if(n>2) fail("invalid IPv6")
    nl=split(halves[1],a,":"); if(halves[1]=="") nl=0
    nr=0; if(n==2 && halves[2]!="") nr=split(halves[2],b,":")
    if((n==1 && nl!=8) || (n==2 && nl+nr>=8)) fail("invalid IPv6")
    out=""; for(i=1;i<=8;i++) {
      if(i<=nl) l=a[i]; else if(i>8-nr) l=b[i-(8-nr)]; else l="0"
      if(length(l)>4 || l !~ /^[0-9a-fA-F]+$/) fail("invalid IPv6")
      l=tolower(l); sub(/^0+/,"",l); if(l=="") l="0"
      out=out (i==1?"":":") l
    }
    split(out,parts,":"); best=0; bestlen=0; start=0; len=0
    for(i=1;i<=9;i++) {
      if(i<=8 && parts[i]=="0") {if(!len) start=i; len++}
      else {if(len>bestlen) {best=start; bestlen=len}; len=0}
    }
    if(bestlen<2) return out
    out=""; for(i=1;i<best;i++) out=out (i==1?"":":") parts[i]
    out=out "::"; for(i=best+bestlen;i<=8;i++) out=out (i==best+bestlen?"":":") parts[i]
    return out
  }
  function socket(s, p,a,n,i,host) {
    if(s ~ /^[0-9]+$/) s="0.0.0.0:" s
    sub(/^\*:/,"0.0.0.0:",s)
    if(s !~ /^([0-9]+\.)+[0-9]+:[0-9]+$/ && s !~ /^\[[0-9a-fA-F:]+\]:[0-9]+$/) fail("unsupported listen address " s)
    p=s; sub(/^.*:/,"",p); if(p+0<1 || p+0>65535) fail("invalid listen port")
    if(s !~ /^\[/) { a=s; sub(/:[0-9]+$/,"",a); n=split(a,t,"."); if(n!=4) fail("invalid IPv4 address"); for(i=1;i<=4;i++) if(t[i]+0>255) fail("invalid IPv4 address") }
    if(s ~ /^\[/) {host=s; sub(/^\[/,"",host); sub(/\]:[0-9]+$/,"",host); return "[" ipv6(host) "]:" (p+0)}
    return substr(s,1,length(s)-length(p)) (p+0)
  }
  function directive(end,    x,n,a,i,s,ssl,def,k) {
    x=token; gsub(/^[ \t\r\n]+|[ \t\r\n]+$/,"",x); token=""
    if(end=="{") {
      depth++; if(x=="server" && depth==1) {srv++; active=srv; start[srv]=pos; count[srv]=0}
      else if(depth==1 && mode=="transform") fail("non-server top-level block")
      return
    }
    if(end=="}") { if(active && depth==1) {finish[active]=pos; active=0}; depth--; if(depth<0) fail("unbalanced braces"); return }
    if(!active || depth!=1) { if(mode=="transform" && depth==0 && x!="") fail("top-level directive cannot be safely inspected"); return }
    n=split(x,a,/[ \t\r\n]+/)
    if(a[1]=="include" && mode!="relaxed") fail("server-level include cannot be safely inspected")
    if(a[1]=="listen") {
      if(n<2) fail("empty listen")
      s=socket(a[2]); ssl=0; def=0
      for(i=3;i<=n;i++) {if(a[i]=="ssl") ssl=1; if(a[i]=="default_server" || a[i]=="default") def=1; if(a[i]=="quic" || a[i]=="udp" || a[i]=="ipv6only=off") fail("unsupported listener option " a[i])}
      k=++listeners; owner[k]=active; sock[k]=s; tls[k]=ssl; existing[k]=def; count[active]++; if(ssl) secure[active]=1
      # Insert only our flag at the semicolon; never remove user default flags.
      if(index("," defaults ",","," s ",")) {if(def) fail("requested default already has an unmanaged default flag"); insertion[pos]=" default_server # nx-access-default\n"; selected[s]++}
    }
    if(a[1]=="server_name") {
      if(names[active]!="") fail("multiple server_name directives")
      for(i=2;i<=n;i++) {
        # Simple quoted DNS tokens have the same identity as bare names.
        # Escapes/concatenated quotes remain unsupported, never guessed.
        if(a[i] ~ /\\/) fail("escaped server_name is unsupported")
        if(substr(a[i],1,1)=="\047" || substr(a[i],1,1)=="\042") {
          q=substr(a[i],1,1)
          if(length(a[i])<2 || substr(a[i],length(a[i]),1)!=q) fail("complex quoted server_name is unsupported")
          a[i]=substr(a[i],2,length(a[i])-2)
        }
        if(a[i] ~ /[\047\042]/) fail("complex quoted server_name is unsupported")
        if(strict && a[i] ~ /^[0-9.]+$/) fail("strict policy requires DNS names, not IP addresses")
        if(strict && a[i] !~ /^[a-zA-Z0-9_-]+(\.[a-zA-Z0-9_-]+)*\.?$/) fail("strict policy requires literal DNS server_name aliases")
        names[active]=names[active] (i==2?"":" ") tolower(a[i])
      }
    }
  }
  {text=text $0 "\n"}
  END {
    if(bad) exit 1
    canonical_defaults=""; nd=split(defaults,dparts,","); for(di=1;di<=nd;di++) if(dparts[di]!="") canonical_defaults=canonical_defaults (canonical_defaults==""?"":",") socket(dparts[di]); defaults=canonical_defaults
    depth=0; quote=""; comment=0; escape=0; token=""
    for(pos=1;pos<=length(text);pos++) {
      c=substr(text,pos,1)
      if(comment) {if(c=="\n") {comment=0; token=token " "}; continue}
      if(escape) {token=token c; escape=0; continue}
      if(c=="\\") {token=token c; escape=1; continue}
      if(quote!="") {token=token c; if(c==quote) quote=""; continue}
      if(c=="\047" || c=="\042") {quote=c; token=token c; continue}
      if(c=="#") {comment=1; continue}
      if(c=="$" && substr(text,pos+1,1)=="{") {
        closevar=index(substr(text,pos+2),"}"); if(!closevar) fail("unterminated variable")
        token=token substr(text,pos,closevar+2); pos+=closevar+1; continue
      }
      if(c=="{" || c=="}" || c==";") directive(c); else token=token c
    }
    if(depth || quote!="" || escape) fail("incomplete configuration")
    if(!srv && mode=="transform") fail("no server block")
    for(i=1;i<=srv;i++) {
      if(!count[i]) fail("implicit listen is not supported")
      if(strict && names[i]=="") fail("strict policy requires server_name")
    }
    n=split(defaults,ds,","); for(i=1;i<=n;i++) if(ds[i]!="" && selected[ds[i]]!=1) fail("default socket must identify exactly one server: " ds[i])
    if(mode=="scan" || mode=="relaxed") {for(i=1;i<=listeners;i++) print owner[i] "|" sock[i] "|" tls[i] "|" existing[i] "|" names[owner[i]]; exit}
    if(strict) for(i=1;i<=srv;i++) {
      n=split(names[i],ns," "); pattern=""; for(j=1;j<=n;j++) {sub(/\.$/,"",ns[j]); gsub(/\./,"\\.",ns[j]); pattern=pattern (j==1?"":"|") ns[j]}
      # $http_host proves Host was actually supplied; $host alone falls back to server_name.
      guard="\n    # nx-access-begin\n    if ($http_host !~* \"^(" pattern ")\\.?(:[0-9]+)?$\") { return 444; }\n"
      guard=guard "    if ($host !~* \"^(" pattern ")$\") { return 444; }\n"
      if(secure[i]) {
        # Canonicalize each accepted SNI alias to its literal lowercase name.
        # Unlike regex backreferences this remains case-insensitive for SNI.
        guard=guard "    set $nx_access_sni \"\";\n"
        for(j=1;j<=n;j++) {
          canonical=ns[j]; gsub(/\\\./,".",canonical)
          guard=guard "    if ($ssl_server_name ~* \"^" ns[j] "\\.?$\") { set $nx_access_sni " canonical "; }\n"
        }
        # Plain HTTP on a mixed listener has no SNI. Only TLS requests must
        # match SNI; assigning Host for HTTP preserves the independent guards.
        guard=guard "    if ($scheme = http) { set $nx_access_sni $host; }\n"
        guard=guard "    if ($nx_access_sni != $host) { return 444; }\n"
      }
      guard=guard "    # nx-access-end\n"
      insertion[start[i]+1]=guard insertion[start[i]+1]
    }
    for(pos=1;pos<=length(text);pos++) printf "%s%s", insertion[pos], substr(text,pos,1)
  }' "$clean" || rc=$?
  if (( owned )); then rm -f "$clean"; fi
  return "$rc"
}

nx_access_site_policy() {
  local p
  p="$(conf_meta_get "$1" access_policy)" || return 1
  case "$p" in ''|inherit) if domain_only_state_is_enabled; then echo strict; else echo open; fi;; strict|open) echo "$p";; *) nx_access_error "无效 access_policy: $p";; esac
}

nx_access_metadata() {
  local file="$1" key="$2" value="$3" tmp
  [[ -f "$file" && ! -L "$file" ]] || return 1
  nx_assert_single_link "$file" || return 1
  tmp="$(mktemp)" || return 1
  if nx_conf_query metadata-set "$file" "$key" "$value" > "$tmp"; then
    ${SUDO:-} tee "$file" < "$tmp" >/dev/null || { rm -f "$tmp"; return 1; }
  else rm -f "$tmp"; return 1; fi
  rm -f "$tmp"
}

# A successful setter must address a site that the derived-policy pass owns.
# This also rejects real helpers/unmanaged files instead of metadata-only success.
nx_access_assert_managed_site() {
  local file
  while IFS= read -r file; do
    [[ "$file" == "$1" ]] && return 0
  done < <(list_managed_conf_files 1)
  nx_access_error "目标未纳入受管站点同步：$1"
}

nx_access_set_policy_files() {
  case "$2" in inherit|strict|open) ;; *) return 1;; esac
  nx_conf_path_allowed "$1" || return 1
  nx_access_assert_managed_site "$1" || return 1
  nx_access_metadata "$1" access_policy "$2"
}
nx_access_set_policy() { nx_transaction nx_access_set_policy_files "$@"; }
nx_access_set_default_files() {
  [[ "$2" != *$'\n'* && "$2" != *$'\r'* ]] || return 1
  nx_conf_path_allowed "$1" || return 1
  nx_access_assert_managed_site "$1" || return 1
  nx_access_metadata "$1" access_default "$2"
}
nx_access_set_default() { nx_transaction nx_access_set_default_files "$@"; }

# Collect transformed files before publishing any of them. The caller transaction
# provides rollback for publication errors and nginx validation/reload failures.
nx_access_sync_files() {
  local stage file policy defaults name rows socket ssl def _server _names line
  local -A required=() tls=() plain=() occupied=() managed=()
  local -a files=() metadata=()
  local index=0 inherited=open
  stage="$(mktemp -d)" || return 1
  mapfile -t files < <(list_managed_conf_files 0)
  domain_only_state_is_enabled && inherited=strict
  if ((${#files[@]})); then
    nx_conf_query policy-batch "${files[0]}" "$stage" "${files[@]:1}" || { rm -rf "$stage"; return 1; }
  fi
  for file in "${files[@]}"; do
    [[ ! -L "$file" ]] || { rm -rf "$stage"; nx_access_error "不修改符号链接 $file"; return 1; }
    nx_assert_single_link "$file" || { rm -rf "$stage"; return 1; }
    name="$(basename "$file")"; managed["$file"]=1
    mapfile -t metadata < "$stage/$index.meta"
    policy="${metadata[0]}"; defaults="${metadata[1]}"
    case "$policy" in
      ''|inherit) policy="$inherited" ;;
      strict|open) ;;
      *) rm -rf "$stage"; nx_access_error "无效 access_policy: $policy"; return 1 ;;
    esac
    if ! nx_access_parse "$stage/$index.clean" transform "$([[ "$policy" == strict ]] && echo 1 || echo 0)" "$defaults" prepared > "$stage/$name"; then rm -rf "$stage"; return 1; fi
    # Scan the generated default flags (strip marker comment, not flag).
    sed 's/ # nx-access-default//' "$stage/$name" > "$stage/scan" || { rm -rf "$stage"; return 1; }
    rows="$(nx_access_parse "$stage/scan" scan 0 '' prepared)" || { rm -rf "$stage"; return 1; }
    while IFS='|' read -r _server socket ssl def _names; do
      [[ -n "$socket" ]] || continue
      [[ "$policy" == strict ]] && required["$socket"]=1
      if [[ "$ssl" == 1 ]]; then tls["$socket"]=1; else plain["$socket"]=1; fi
      if [[ "$def" == 1 ]]; then
        if [[ -n "${occupied[$socket]:-}" ]]; then rm -rf "$stage"; nx_access_error "重复 default_server: $socket"; return 1; fi
        occupied["$socket"]="$file"
      fi
    done <<< "$rows"
    index=$((index+1))
  done
  # Existing default servers, including unmanaged sites, own exactly their socket.
  for file in "$CONF_DIR"/*.conf; do
    [[ -f "$file" && "$file" != "$(domain_only_conf_path)" && -z "${managed[$file]:-}" ]] || continue
    # Non-server helper files (maps etc.) have no listen directives.
    if ! grep -qE '(^|[;{}[:space:]])listen[[:space:]]' "$file"; then continue; fi
    # With no strict sockets or explicit defaults, unrelated includes cannot
    # affect this operation. Otherwise inspect conservatively and fail closed.
    if ((${#required[@]} == 0 && ${#occupied[@]} == 0)); then continue; fi
    rows="$(nx_access_parse "$file")" || { rm -rf "$stage"; return 1; }
    while IFS='|' read -r _server socket ssl def _names; do
      [[ -n "$socket" ]] || continue
      if [[ "$ssl" == 1 ]]; then tls["$socket"]=1; else plain["$socket"]=1; fi
      if [[ "$def" == 1 ]]; then
        if [[ -n "${occupied[$socket]:-}" ]]; then rm -rf "$stage"; nx_access_error "与现有 default_server 冲突: $socket"; return 1; fi
        occupied["$socket"]="$file"
      fi
    done <<< "$rows"
  done
  printf '# managed_by=Nginx-X\n# nx-access-catchall=1\n' > "$stage/catchall"
  local -a sorted_sockets=()
  if ((${#required[@]})); then mapfile -t sorted_sockets < <(printf '%s\n' "${!required[@]}" | LC_ALL=C sort); fi
  for socket in "${sorted_sockets[@]}"; do
    [[ -z "${occupied[$socket]:-}" ]] || continue
    {
      echo 'server {'
      line="$socket"; [[ "$line" == 0.0.0.0:* ]] && line="${line#*:}"
      if [[ -n "${tls[$socket]:-}" ]]; then
        echo "    listen $line ssl default_server;"
        if [[ -z "${plain[$socket]:-}" ]] && nginx_supports_ssl_reject_handshake; then
          echo '    ssl_reject_handshake on;'
        else
          # Certificate must live inside CONF_DIR so the transaction owns it.
          echo "    ssl_certificate \"$CONF_DIR/.nx-access-cert.pem\";"
          echo "    ssl_certificate_key \"$CONF_DIR/.nx-access-key.pem\";"
          : > "$stage/need-cert"
        fi
      else echo "    listen $line default_server;"; fi
      echo '    server_name _;'
      echo '    return 444;'
      echo '}'
    } >> "$stage/catchall"
  done
  if [[ -f "$stage/need-cert" && ( ! -f "$CONF_DIR/.nx-access-cert.pem" || ! -f "$CONF_DIR/.nx-access-key.pem" ) ]]; then
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=nx-access -keyout "$stage/key" -out "$stage/cert" >/dev/null 2>&1; then rm -rf "$stage"; return 1; fi
    if ! ${SUDO:-} install -m 600 "$stage/key" "$CONF_DIR/.nx-access-key.pem" || ! ${SUDO:-} install -m 644 "$stage/cert" "$CONF_DIR/.nx-access-cert.pem"; then rm -rf "$stage"; return 1; fi
  fi
  for file in "${files[@]}"; do
    # Preserve mode and ownership of existing site files.
    if ! cmp -s "$file" "$stage/$(basename "$file")"; then
      ${SUDO:-} tee "$file" < "$stage/$(basename "$file")" >/dev/null || { rm -rf "$stage"; return 1; }
    fi
  done
  if grep -q '^server {' "$stage/catchall"; then
    ${SUDO:-} install -m 644 "$stage/catchall" "$(domain_only_conf_path)" || { rm -rf "$stage"; return 1; }
  else ${SUDO:-} rm -f "$(domain_only_conf_path)" || { rm -rf "$stage"; return 1; }; fi
  rm -rf "$stage"
}

nx_access_global_files() {
  [[ "$1" == 0 || "$1" == 1 ]] || return 1
  [[ ! -L "$DOMAIN_ONLY_STATE" ]] || return 1
  nx_assert_single_link "$DOMAIN_ONLY_STATE" || return 1
  local tmp
  tmp="$(mktemp)" || return 1
  printf 'DOMAIN_ONLY=%s\n' "$1" > "$tmp" || { rm -f "$tmp"; return 1; }
  if ! ${SUDO:-} mkdir -p "$(dirname "$DOMAIN_ONLY_STATE")" ||
     ! ${SUDO:-} install -m 644 "$tmp" "$DOMAIN_ONLY_STATE"; then
    rm -f "$tmp"; return 1
  fi
  rm -f "$tmp"
}
domain_only_enable() {
  nx_transaction nx_access_global_files 1 || return 1
  info '全局继承策略已设为严格域名校验（Host；TLS 同时校验 SNI）。'
  nx_access_scope_notice
  domain_only_warn_exposed_ports
}
domain_only_disable() { nx_transaction nx_access_global_files 0; }
nx_access_noop() { :; }
domain_only_sync() { nx_transaction nx_access_noop; }
domain_only_rebuild_if_enabled() { domain_only_sync; }
# apply_conf_with_rollback already syncs within its transaction.
domain_only_after_apply() { :; }

nx_access_scope_notice() {
  echo '仅约束 Nginx 入口，不拦截后端服务的直连端口；不是鉴权，也不会隐藏公网 IP。'
}

nx_site_access_menu() {
  local file="$1" c policy
  [[ -f "$file" ]] || file="$CONF_DIR/$file"
  policy="$(nx_access_site_policy "$file")" || return 1
  echo "站点: $(basename "$file")"
  if [[ "$policy" == strict ]]; then echo '仅域名访问：已开启'; else echo '仅域名访问：已关闭'; fi
  echo '1) 开启仅域名访问'
  echo '2) 关闭仅域名访问'
  echo '3) 管理本站默认访问入口'
  echo "后端直连保护：$(nx_backend_status "$file")"
  echo '4) 显式启用后端直连保护'
  echo '5) 显式关闭本站后端保护引用'
  echo '0) 返回'
  echo '开启后 Nginx 入口只接受本站域名；关闭不会自动将 IP 请求分配给本站。'
  nx_access_scope_notice
  read -rp '请选择: ' c || return 1
  case "$c" in
    1) nx_access_set_policy "$file" strict || return 1
       info '本站 Nginx 入口已开启严格域名校验。'
       nx_access_scope_notice ;;
    2) nx_access_set_policy "$file" open ;;
    3) nx_default_site_menu "$file" ;;
    4) nx_backend_enable "$file" ;;
    5) nx_backend_disable "$file" ;;
    0) return 0 ;;
    *) warn '无效输入。'; return 1 ;;
  esac
}

nx_default_site_menu() {
  local file="$1" i choice rows socket defaults
  local -a sockets=()
  [[ -f "$file" && "$file" == *.conf ]] || { error '请先启用本站配置。'; return 1; }
  rows="$(nx_access_parse "$file")" || return 1
  mapfile -t sockets < <(cut -d '|' -f2 <<< "$rows" | sort -u)
  defaults="$(conf_meta_get "$file" access_default)" || return 1
  echo "本站默认入口：${defaults:-未设置}"
  for i in "${!sockets[@]}"; do echo "$((i+1))) ${sockets[$i]}"; done
  echo 'c) 清除本站默认入口设置'
  echo '0) 返回'
  echo '选择监听地址后，本站接收该地址的 IP / 未匹配域名请求；开启仅域名访问时仍会拒绝这些请求。'
  echo '同一监听地址只能有一个默认站点；更换时请先在原站点清除设置。'
  read -rp '选择监听地址: ' choice || return 1
  case "$choice" in
    0) return 0 ;;
    c|C) nx_access_set_default "$file" ''; return ;;
  esac
  [[ "$choice" =~ ^[1-9][0-9]*$ ]] && ((choice<=${#sockets[@]})) || return 1
  socket="${sockets[$((choice-1))]}"
  if [[ ",$defaults," != *",$socket,"* ]]; then defaults="${defaults:+$defaults,}$socket"; fi
  nx_access_set_default "$file" "$defaults"
}

# Compatibility for the diagnostics page: ports only, parsed from exact sockets.
domain_only_collect_ports() {
  local file rows socket ssl
  while IFS= read -r file; do
    rows="$(nx_access_parse "$file")" || return 1
    while IFS='|' read -r _ socket ssl _ _; do
      [[ -n "$socket" ]] || continue
      if [[ "$ssl" == 1 ]]; then printf 'ssl %s\n' "${socket##*:}"; else printf 'plain %s\n' "${socket##*:}"; fi
    done <<< "$rows"
  done < <(list_managed_conf_files 0)
}
