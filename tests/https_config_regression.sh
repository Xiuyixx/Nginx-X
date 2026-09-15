#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

MOCK_BIN="$TMPDIR_ROOT/bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/nginx" <<'EOF'
#!/usr/bin/env bash
if [[ "${NGINX_MOCK_FAIL:-0}" == "1" ]]; then
  exit 1
fi
exit 0
EOF
cat > "$MOCK_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${SYSTEMCTL_MOCK_FAIL:-0}" == "1" ]]; then
  exit 1
fi
case "$1" in
  is-active) exit 1 ;;
  start|reload) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$MOCK_BIN/nginx" "$MOCK_BIN/systemctl"
export PATH="$MOCK_BIN:$PATH"

# shellcheck disable=SC1091
source nx.sh

# Make the test deterministic: don't depend on the host kernel IPv6 state.
ipv6_available() { return 0; }

# shellcheck disable=SC2034
SUDO=""
CONF_DIR="$TMPDIR_ROOT/conf.d"
SSL_DIR="$TMPDIR_ROOT/ssl"
mkdir -p "$CONF_DIR" "$SSL_DIR/example.com"
: > "$SSL_DIR/example.com/fullchain.pem"
: > "$SSL_DIR/example.com/privkey.pem"

out="$TMPDIR_ROOT/example-443.conf"
build_external_proxy_conf \
  "example.com" \
  "443" \
  "https://upstream.example.com" \
  "normal" \
  "$out" \
  "1"

grep -q '^# https_enabled=true$' "$out"
grep -q 'listen 443 ssl' "$out"
grep -q 'listen 443 ssl http2;' "$out"
grep -q 'listen \[::\]:443 ssl http2;' "$out"
grep -q 'listen \[::\]:80;' "$out"
if grep -q 'http2 on;' "$out"; then
  echo "unexpected directive: http2 on;" >&2
  exit 1
fi
# shellcheck disable=SC2016
grep -Fq 'return 301 https://$host$request_uri;' "$out"
grep -q "ssl_certificate     ${SSL_DIR}/example.com/fullchain.pem;" "$out"
grep -q "ssl_certificate_key ${SSL_DIR}/example.com/privkey.pem;" "$out"

# Internal helper configs should not appear in the user-managed site list,
# including disabled/backup variants.
cat > "$CONF_DIR/00-websocket-map.conf.bak" <<'EOF'
# managed_by=Nginx-X
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF
cat > "$CONF_DIR/nginx_status.conf" <<'EOF'
# managed_by=Nginx-X
server { listen 127.0.0.1:80; }
EOF
cat > "$CONF_DIR/nginx_status.conf.bak" <<'EOF'
# managed_by=Nginx-X
server { listen 127.0.0.1:80; }
EOF
cat > "$CONF_DIR/acme-challenge-example.conf.bak" <<'EOF'
# managed_by=Nginx-X
server { listen 80; }
EOF
managed_list="$(list_managed_conf_files 1)"
if grep -Eq '00-websocket-map\.conf|nginx_status\.conf|acme-challenge-example\.conf' <<<"$managed_list"; then
  echo "internal helper config leaked into managed config list" >&2
  exit 1
fi

# Imported or custom-location configs should be protected from template rebuilds.
imported_conf="$TMPDIR_ROOT/imported.conf"
cat > "$imported_conf" <<'EOF'
# managed_by=Nginx-X
# domain=imported.example.com
# listen_port=80
# imported=true
server {
    listen 80;
    server_name imported.example.com;
    location / { proxy_pass http://127.0.0.1:3000; }
}
EOF
if require_template_rebuild_safe "$imported_conf" "测试" >/dev/null 2>&1; then
  echo "imported config should not be considered safe for template rebuild" >&2
  exit 1
fi

edited_conf="$TMPDIR_ROOT/edited.conf"
cat > "$edited_conf" <<'EOF'
# managed_by=Nginx-X
# domain=edited.example.com
# listen_port=80
server {
    listen 80;
    server_name edited.example.com;
    location / { proxy_pass http://127.0.0.1:3000; }
}
EOF
mark_conf_manual_edited "$edited_conf"
grep -q '^# edited=true$' "$edited_conf"
[[ "$(stat -c '%a' "$edited_conf")" == "644" ]]
if require_template_rebuild_safe "$edited_conf" "测试" >/dev/null 2>&1; then
  echo "manually edited config should not be considered safe for template rebuild" >&2
  exit 1
fi

custom_conf="$TMPDIR_ROOT/custom.conf"
cat > "$custom_conf" <<'EOF'
# managed_by=Nginx-X
# domain=custom.example.com
# listen_port=80
server {
    listen 80;
    server_name custom.example.com;
    location / { proxy_pass http://127.0.0.1:3000; }
    location /api/ { proxy_pass http://127.0.0.1:4000; }
}
EOF
if require_template_rebuild_safe "$custom_conf" "测试" >/dev/null 2>&1; then
  echo "custom-location config should not be considered safe for template rebuild" >&2
  exit 1
fi

multi_server_conf="$TMPDIR_ROOT/multi-server.conf"
cat > "$multi_server_conf" <<'EOF'
server { listen 80; server_name one.example.com; }
server { listen 80; server_name two.example.com; }
EOF
if validate_importable_conf "$multi_server_conf" >/dev/null 2>&1; then
  echo "multi-server config should be rejected by import validation" >&2
  exit 1
fi

rollback_import_conf="$CONF_DIR/rollback-import.conf"
cat > "$rollback_import_conf" <<'EOF'
server {
    listen 80;
    server_name rollback.example.com;
    location / { proxy_pass http://127.0.0.1:3000; }
}
EOF
if NGINX_MOCK_FAIL=1 import_single_conf "$rollback_import_conf" >/dev/null 2>&1; then
  echo "import should fail when nginx -t fails" >&2
  exit 1
fi
[[ -f "$rollback_import_conf" ]]
if grep -q '^# managed_by=Nginx-X$' "$rollback_import_conf"; then
  echo "failed import should restore original unmanaged config" >&2
  exit 1
fi
[[ ! -f "$CONF_DIR/rollback.example.com-80.conf" ]]

reload_rollback_target="$TMPDIR_ROOT/reload-rollback.conf"
reload_rollback_tmp="$TMPDIR_ROOT/reload-rollback.new"
printf 'original\n' > "$reload_rollback_target"
printf 'replacement\n' > "$reload_rollback_tmp"
if SYSTEMCTL_MOCK_FAIL=1 apply_conf_with_rollback "$reload_rollback_tmp" "$reload_rollback_target" >/dev/null 2>&1; then
  echo "config apply should fail when Nginx reload fails" >&2
  exit 1
fi
[[ "$(cat "$reload_rollback_target")" == "original" ]]

cert_ref_conf="$CONF_DIR/cert-ref.conf"
cat > "$cert_ref_conf" <<EOF
# managed_by=Nginx-X
server {
    listen 443 ssl;
    server_name example.com;
    ssl_certificate     ${SSL_DIR}/example.com/fullchain.pem;
    ssl_certificate_key ${SSL_DIR}/example.com/privkey.pem;
}
EOF
grep -q 'cert-ref.conf' < <(cert_referenced_confs example.com)
rm -f "$cert_ref_conf"

# Stream mode must not duplicate timeout directives in the same location.
stream_conf="$TMPDIR_ROOT/stream-443.conf"
build_external_proxy_conf \
  "stream.example.com" \
  "443" \
  "https://free.lilyemby.com" \
  "media" \
  "$stream_conf" \
  "0"

[[ "$(grep -c 'proxy_read_timeout' "$stream_conf")" -eq 1 ]]
[[ "$(grep -c 'proxy_send_timeout' "$stream_conf")" -eq 1 ]]

http_conf="$TMPDIR_ROOT/http-80.conf"
cat > "$http_conf" <<'EOF'
# managed_by=Nginx-X
# domain=example.com
# listen_port=80
# backend_port=3000
server {
    listen 80;
    server_name example.com;

    location / {
        proxy_pass http://127.0.0.1:3000;
    }
}
EOF

enable_https_for_conf_file "example.com" "$http_conf"
grep -q '^# listen_port=443$' "$http_conf"
grep -q 'listen 443 ssl' "$http_conf"
grep -q 'listen 443 ssl http2;' "$http_conf"
grep -q 'listen \[::\]:443 ssl http2;' "$http_conf"
grep -q 'listen \[::\]:80;' "$http_conf"
if grep -q 'http2 on;' "$http_conf"; then
  echo "unexpected directive: http2 on;" >&2
  exit 1
fi
# shellcheck disable=SC2016
grep -Fq 'return 301 https://$host$request_uri;' "$http_conf"
grep -q '^# backend_port=3000$' "$http_conf"

disable_https_for_conf_file "example.com" "$http_conf"
grep -q '^# backend_port=3000$' "$http_conf"
grep -q 'proxy_pass http://127.0.0.1:3000;' "$http_conf"

# URL parsing: IPv6 host extraction should handle bracketed addresses.
[[ "$(url_host 'http://[2001:db8::1]:8080/path')" == "2001:db8::1" ]]
[[ "$(url_host 'https://example.com:8443/a/b')" == "example.com" ]]
[[ "$(url_explicit_port 'http://127.0.0.1:3000/path')" == "3000" ]]
[[ "$(url_explicit_port 'https://[2001:db8::1]:8443/path')" == "8443" ]]
[[ -z "$(url_explicit_port 'https://example.com/path')" ]]

proxy_extract_conf="$TMPDIR_ROOT/proxy-extract.conf"
cat > "$proxy_extract_conf" <<'EOF'
location / {
    proxy_pass http://localhost:9876/path;
}
EOF
[[ "$(extract_proxy_pass "$proxy_extract_conf")" == "http://localhost:9876/path" ]]

valid_url 'https://example.com/path'
# shellcheck disable=SC2016
if valid_url 'https://example.com/$PATH'; then
  echo 'URL containing a shell variable should be rejected' >&2
  exit 1
fi

# WebSocket map injection must roll nginx.conf back when nginx -t fails.
NGINX_MAIN_CONF="$TMPDIR_ROOT/nginx.conf"
cat > "$NGINX_MAIN_CONF" <<'EOF'
events {}
include /etc/nginx/conf.d/*.conf;
http {
}
EOF
nginx_main_before="$(cat "$NGINX_MAIN_CONF")"
if NGINX_MOCK_FAIL=1 ensure_websocket_map >/dev/null 2>&1; then
  echo 'WebSocket map injection should fail when nginx -t fails' >&2
  exit 1
fi
[[ "$(cat "$NGINX_MAIN_CONF")" == "$nginx_main_before" ]]
if find "$TMPDIR_ROOT" -maxdepth 1 -name 'nginx.conf.bak.*' | grep -q .; then
  echo 'failed WebSocket map injection left a backup file behind' >&2
  exit 1
fi
ensure_websocket_map >/dev/null
# shellcheck disable=SC2016
grep -Fq 'map $http_upgrade $connection_upgrade' "$NGINX_MAIN_CONF"

STATE_DIR="$TMPDIR_ROOT/state"
EMAIL_CONF="$STATE_DIR/email.conf"
save_email 'user@example.com' >/dev/null
[[ "$(stat -c '%a' "$EMAIL_CONF")" == "600" ]]

DNS_CONF="$STATE_DIR/dns.conf"
dns_marker="$TMPDIR_ROOT/dns-key-executed"
dns_key="\$(touch ${dns_marker})\"quoted"
save_dns_conf 'cloudflare' "$dns_key" 'second-key' >/dev/null 2>&1
unset DNS_PROVIDER DNS_KEY1 DNS_KEY2
load_dns_conf
[[ "$DNS_PROVIDER" == 'cloudflare' ]]
[[ "$DNS_KEY1" == "$dns_key" ]]
[[ "$DNS_KEY2" == 'second-key' ]]
[[ ! -e "$dns_marker" ]]
[[ "$(stat -c '%a' "$DNS_CONF")" == "600" ]]

meta_match_conf="$CONF_DIR/meta-match.conf"
cat > "$meta_match_conf" <<'EOF'
# managed_by=Nginx-X
# domain=meta.example.com
server { listen 80; }
EOF
meta_matches="$(list_confs_by_meta_domain 'meta.example.com')"
grep -qF "$meta_match_conf" <<<"$meta_matches"

acme_conf="$CONF_DIR/acme-rollback.conf"
cat > "$acme_conf" <<'EOF'
# managed_by=Nginx-X
# domain=acme.example.com
# listen_port=80
# backend_port=3000
server {
    listen 80;
    server_name acme.example.com;
    location / { proxy_pass http://127.0.0.1:3000; }
}
EOF
acme_before="$(cat "$acme_conf")"
if NGINX_MOCK_FAIL=1 ensure_acme_location_for_domain_conf 'acme.example.com' >/dev/null 2>&1; then
  echo 'ACME location update should fail when nginx -t fails' >&2
  exit 1
fi
[[ "$(cat "$acme_conf")" == "$acme_before" ]]
ensure_acme_location_for_domain_conf 'acme.example.com' >/dev/null
grep -q '/\.well-known/acme-challenge/' "$acme_conf"
[[ "$(stat -c '%a' "$acme_conf")" == "644" ]]

# Emby/Lily split-proxy mode should support multiple stream upstreams.
multi_stream_conf="$TMPDIR_ROOT/emby-multi-stream.conf"
normalized_stream_urls="$(normalize_url_list 'https://stream-a.example.com, https://stream-b.example.com')"
build_external_proxy_conf \
  "emby.example.com" \
  "80" \
  "https://main.example.com" \
  "emby_lily" \
  "$multi_stream_conf" \
  "0" \
  "https://stream-a.example.com" \
  "https://main.example.com" \
  "" \
  "$normalized_stream_urls"

grep -q '^# stream_upstream_url=https://stream-a.example.com$' "$multi_stream_conf"
grep -q '^# stream_upstream_urls=https://stream-a.example.com|https://stream-b.example.com$' "$multi_stream_conf"
grep -q 'location /s1/' "$multi_stream_conf"
grep -q 'location /s2/' "$multi_stream_conf"
grep -q 'proxy_pass https://stream-a.example.com;' "$multi_stream_conf"
grep -q 'proxy_pass https://stream-b.example.com;' "$multi_stream_conf"
grep -q "sub_filter 'https://stream-a.example.com' 'https://emby.example.com/s1';" "$multi_stream_conf"
grep -q "sub_filter 'https://stream-b.example.com' 'https://emby.example.com/s2';" "$multi_stream_conf"

# 回归：非标端口（如 8443）的 LilyEmby 方案，sub_filter / proxy_redirect 的重写目标必须带端口后缀，
# 否则客户端在非 443 端口访问时拿到不可达地址，播放流量会绕过反代直连源站（见 issue #6）。
nonstd_conf="$TMPDIR_ROOT/emby-lily-8443.conf"
build_external_proxy_conf \
  "emby.example.com" \
  "8443" \
  "https://main.example.com" \
  "emby_lily" \
  "$nonstd_conf" \
  "1" \
  "https://stream-a.example.com" \
  "https://main.example.com" \
  "" \
  ""

grep -q "return 301 https://\$host:8443\$request_uri;" "$nonstd_conf"
grep -q "sub_filter 'https://main.example.com' 'https://emby.example.com:8443';" "$nonstd_conf"
grep -q "sub_filter 'https://stream-a.example.com' 'https://emby.example.com:8443/s1';" "$nonstd_conf"
grep -q "proxy_redirect https://stream-a.example.com https://emby.example.com:8443/s1/;" "$nonstd_conf"
grep -q "proxy_redirect https://main.example.com https://emby.example.com:8443;" "$nonstd_conf"
# 标准 443 端口不得带端口后缀
grep -q "sub_filter 'https://stream-a.example.com' 'https://emby.example.com/s1';" "$multi_stream_conf"

bad_conf="$TMPDIR_ROOT/bad.conf"
cat > "$bad_conf" <<'EOF'
server {
    listen 443 ssl;
    server_name broken.example.com;
}
EOF

if ensure_ssl_directives_present "$bad_conf" >/dev/null 2>&1; then
  echo "expected ensure_ssl_directives_present to fail for incomplete ssl config" >&2
  exit 1
fi

echo "[OK] expected failure: ensure_ssl_directives_present blocked incomplete ssl config" >&2

echo "ok"
