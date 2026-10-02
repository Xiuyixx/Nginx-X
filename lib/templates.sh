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
