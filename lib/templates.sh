#!/usr/bin/env bash
# Nginx-X configuration templates; sourced by nx.sh.
build_proxy_conf() {
  local domain="$1"
  local listen_port="$2"
  local backend_port="$3"
  local out="$4"


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

  local frontend_scheme="http" domain_port_suffix=""
  [[ "$https_enabled" == "1" ]] && frontend_scheme="https"
  if [[ "$frontend_scheme:$listen_port" != "http:80" && "$frontend_scheme:$listen_port" != "https:443" ]]; then
    domain_port_suffix=":${listen_port}"
  fi

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

  # Validate every interpolated URL at the builder boundary, including Referer.
  local candidate
  for candidate in "$upstream_url" "$source_site_url" "$referer_url" "${stream_urls[@]}"; do
    if ! nx_template_valid_url "$candidate"; then
      error "无效或不安全的代理 URL / Referer。" >&2
      return 1
    fi
  done

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
        stream_redirect_block+="        proxy_redirect ${stream_url} ${frontend_scheme}://${domain}${domain_port_suffix}${stream_path};"$'\n'

        if [[ "$external_mode" == "emby_lily" ]]; then
          stream_lily_block+="        sub_filter '${stream_url}' '${frontend_scheme}://${domain}${domain_port_suffix}${stream_path%/}';"$'\n'
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
        redirect_block+="        proxy_redirect ${source_site_url} ${frontend_scheme}://${domain}${domain_port_suffix};"
        base_lily_block=$(cat <<EOF
        proxy_set_header Accept-Encoding "";
        sub_filter_types application/json text/xml text/plain;
        sub_filter_once off;
        sub_filter '${source_site_url}' '${frontend_scheme}://${domain}${domain_port_suffix}';
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
# nx_frontend_rewrites=true

server {
    listen 80;
${ipv6_listen_80}
    server_name ${domain};

    location ^~ /.well-known/acme-challenge/ {
        root /usr/share/nginx/html;
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / { return 301 https://\$host${redirect_suffix}\$request_uri; }
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
# nx_frontend_rewrites=true

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

# URLs are emitted into both quoted and unquoted Nginx arguments.
nx_template_valid_url() {
  local value="$1"
  valid_url "$value" && [[ "$value" != *'"'* && "$value" != *'#'* ]] || return 1
  [[ "$value" =~ ^https?://[^/?#:]+(:[0-9]+)?([/?].*)?$ || "$value" =~ ^https?://\[[0-9a-fA-F:]+\](:[0-9]+)?([/?].*)?$ ]]
}

# Shared structural queries and offset-preserving metadata/access edits.
nx_conf_query() {
  python3 - "$@" <<'PYCONF'
import sys, re, ipaddress, os
operation, filename, *params = sys.argv[1:]
def fail(message): raise ValueError(message)
def socket(value, inspect=False):
    if value.isdigit(): value = '0.0.0.0:' + value
    host, number = value.rsplit(':', 1)
    host = host.strip('[]')
    try:
        host = '0.0.0.0' if host == '*' else str(ipaddress.ip_address(host))
    except ValueError:
        if not inspect or not re.fullmatch(r'[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*\.?', host):
            fail('unsupported exact listen address: ' + value)
        host = host.lower().rstrip('.')
    if not number.isdigit() or not 1 <= int(number) <= 65535: fail('invalid port')
    return ('[' + host + ']' if ':' in host else host) + ':' + str(int(number))
def inspect(filename, query=operation):
    try:
        text = open(filename, encoding='utf-8', newline='').read()
        tokens = []
        metadata = {}
        comments = []
        depth = 0
        i = 0
        while i < len(text):
            if text[i].isspace():
                i += 1
                continue
            if text[i] == '#':
                end = text.find('\n', i)
                end = len(text) if end < 0 else end + 1
                line_start = text.rfind('\n', 0, i) + 1
                comments.append((line_start, i, end, depth))
                # Setters append metadata after server blocks. Only standalone
                # top-level comments count, never strings or comments in a block.
                if depth == 0 and not text[line_start:i].strip():
                    match = re.fullmatch(r'# ([A-Za-z_][A-Za-z_0-9]*)=([^\r\n]*)(?:\r?\n)?', text[i:end])
                    if match:
                        metadata.setdefault(match[1], []).append((line_start, end, match[2]))
                i = end
                continue
            start = i
            if text[i] in '{};':
                if text[i] == '{':
                    depth += 1
                elif text[i] == '}':
                    depth -= 1
                i += 1
            else:
                quote = None
                while i < len(text):
                    c = text[i]
                    if c == '\\':
                        i += 2
                        continue
                    if quote:
                        if c == quote:
                            quote = None
                        i += 1
                        continue
                    if c in '\"\'':
                        quote = c
                        i += 1
                        continue
                    if text.startswith('${', i):
                        end = text.find('}', i + 2)
                        if end < 0:
                            fail('unterminated variable')
                        i = end + 1
                        continue
                    if c.isspace() or c in '{};#':
                        break
                    i += 1
                if quote or i > len(text):
                    fail('unterminated quote/escape')
            tokens.append((text[start:i], start, i))

        cursor = 0
        def parse(nested=False):
            nonlocal cursor
            nodes = []
            while cursor < len(tokens):
                if tokens[cursor][0] == '}':
                    if not nested:
                        fail('unexpected closing brace')
                    closing = tokens[cursor][2]
                    cursor += 1
                    return nodes, closing
                args = []
                start = tokens[cursor][1]
                while cursor < len(tokens) and tokens[cursor][0] not in '{};':
                    args.append(tokens[cursor][0])
                    cursor += 1
                if not args or cursor >= len(tokens):
                    fail('incomplete directive')
                delimiter, opening, end = tokens[cursor]
                cursor += 1
                children = None
                if delimiter == '{':
                    children, end = parse(True)
                elif delimiter != ';':
                    fail('missing semicolon')
                nodes.append(dict(args=args, start=start, end=end, opening=opening, children=children))
            if nested:
                fail('unclosed block')
            return nodes, len(text)

        nodes, _ = parse()
        if query in ('metadata-set', 'metadata-drop', 'strip-access'):
            edits = []
            if query == 'strip-access':
                begin = None
                for line, start, end, level in comments:
                    marker = text[start:end].rstrip('\r\n')
                    standalone = not text[line:start].strip()
                    if standalone and level == 1 and marker == '# nx-access-begin':
                        if begin is not None: fail('nested access marker')
                        begin = line - 1 if line and text[line-1] == '\n' else line
                    elif standalone and level == 1 and marker == '# nx-access-end':
                        if begin is None: fail('orphan access marker')
                        edits.append((begin, end, ''))
                        begin = None
                    elif marker == '# nx-access-default' and level == 1:
                        prefix = text[line:start]
                        if prefix.endswith(' default_server '):
                            edits.append((start-len(' default_server '), end, ''))
                if begin is not None: fail('unterminated access marker')
            else:
                keys = params if query == 'metadata-drop' else params[:1]
                for key in keys:
                    if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', key): fail('invalid metadata key')
                    edits.extend((start, end, '') for start, end, _ in metadata.get(key, []))
                if query == 'metadata-set':
                    if len(params) != 2 or any(c in params[1] for c in '\r\n'): fail('invalid metadata value')
                    edits.append((len(text), len(text), ('\n' if text and not text.endswith('\n') else '') + '# ' + params[0] + '=' + params[1] + '\n'))
            for start, end, value in sorted(edits, reverse=True):
                text = text[:start] + value + text[end:]
            sys.stdout.write(text)
            return
        if query == "tree": return nodes
        def walk(nodes):
            for n in nodes:
                yield n
                yield from walk(n['children'] or [])
        servers = [n for n in nodes if n['args'] == ['server'] and n['children'] is not None]
        def directives(n, key): return [x for x in n['children'] if x['args'][0] == key]
        def unquote(s): return s[1:-1] if len(s)>1 and s[0] == s[-1] and s[0] in '\"\'' else s
        rows = []
        # Metadata and structural queries do not need resolvable listen sockets.
        # Inspection retains hostnames; defaults/security operations require IPs.
        if query in ('keys', 'summary', 'list', 'traffic'):
            for idx, srv in enumerate(servers):
                names = [unquote(x) for n in directives(srv, 'server_name') for x in n['args'][1:]]
                for n in directives(srv, 'listen'):
                    args = [unquote(x) for x in n['args'][1:]]
                    rows.append((idx, socket(args[0], inspect=True), 'ssl' in args[1:], names))
        if query == 'tls-check':
            inherited = []
            if params and os.path.isfile(params[0]):
                main = inspect(params[0], 'tree')
                inherited = [child for n in main if n['args'] == ['http'] for child in (n['children'] or [])]
            for srv in servers:
                if not any('ssl' in n['args'][2:] for n in directives(srv, 'listen')): continue
                scope = srv['children'] + inherited
                # Includes can supply certificates; nginx -t resolves them.
                if any(n['args'][0] == 'include' or n['args'] == ['ssl_reject_handshake', 'on'] for n in scope): continue
                for key in ('ssl_certificate', 'ssl_certificate_key'):
                    if not any(n['args'][0] == key and len(n['args']) == 2 for n in scope): fail('TLS server missing ' + key)
        elif query == 'list':
            row = next((r for r in rows if r[2]), rows[0] if rows else None)
            names = row[3] if row else []
            values = metadata.get('access_policy', [])
            policy = values[0][2] if len(values)==1 else ('invalid' if values else 'inherit')
            fields = [filename, names[0] if names else '未知域名',
                      ','.join(sorted({r[1] for r in rows})) or '未知监听',
                      'HTTPS' if any(r[2] for r in rows) else 'HTTP', policy]
            if any(any(c in field for c in '\t\r\n') for field in fields): fail('unsupported list field')
            print('\t'.join(fields))
        elif query == 'meta':
            values = metadata.get(params[0], [])
            if len(values)>1: fail('duplicate metadata: '+params[0])
            print(values[0][2] if values else '')
        elif query == 'count': print(len(servers))
        elif query == 'locations': print(sum(n['args'][0]=='location' for n in walk(nodes)))
        elif query == 'proxy':
            print(next((unquote(n['args'][1]) for n in walk(nodes) if n['args'][0]=='proxy_pass'), ''))
        elif query == 'traffic':
            base = os.path.basename(filename)
            names = [name for _, _, _, aliases in rows for name in aliases]
            if any(any(c in field for c in '|\r\n') for field in [filename] + names):
                fail('unsupported traffic field')
            print('SITE|' + base)
            for name, port in sorted({(name.lower().rstrip('.'), sock.rsplit(':', 1)[1]) for _, sock, _, aliases in rows for name in aliases}):
                print('KEY|' + base + '|' + name + '|' + port)
        elif query == 'keys':
            print('\n'.join(sorted({name.lower().rstrip('.')+'|'+sock for _,sock,_,names in rows for name in names})))
        elif query == 'summary':
            if not rows: fail('no explicit listeners')
            row = next((r for r in rows if r[2]), rows[0])
            if not row[3]: fail('no server_name')
            domain=row[3][0]
            if not re.fullmatch(r'[A-Za-z0-9_.-]+',domain) or domain in ('_', 'localhost'): fail('unsupported primary server_name')
            backend=next((unquote(n['args'][1]) for n in walk(servers[row[0]]['children']) if n['args'][0]=='proxy_pass'), '')
            if any(c in backend for c in '|\n\r'): fail('unsupported proxy_pass')
            mode='external' if backend and not re.match(r'https?://(?:127\.0\.0\.1|localhost)(?=[:/]|$)',backend) else ''
            print('|'.join([domain,row[1].rsplit(':',1)[1],backend,str(row[2]).lower(),mode]))
        elif query == 'defaults':
            old = params[0].split(',') if params[0] else []
            oldrows = params[1].splitlines()
            newrows = params[2].splitlines()
            def listeners(lines):
                return [(p[1],p[2],p[0]) for p in (line.split('|') for line in lines) if len(p)>2]
            before, after = listeners(oldrows), listeners(newrows)
            mapping={}
            for a,b in zip(before,after):
                if a[1:]==b[1:]: mapping[a[0]]=b[0]
            result=[]
            for s in old:
                s=socket(s); s=mapping.get(s,s)
                if s in {r[0] for r in after} and s not in result: result.append(s)
            print(','.join(result))
        else: fail('unknown query')
    except (ValueError, OSError, UnicodeError, IndexError) as exc:
        print('Config inspection refused: '+str(exc), file=sys.stderr)
        sys.exit(1)

for filename in ([filename] + params if operation in ('list', 'traffic') else [filename]):
    inspect(filename)
PYCONF
}
