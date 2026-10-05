#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/../nx.sh"
root="$(mktemp -d)"
trap 'rm -rf "$root"; nx_test_cleanup' EXIT
NGINX_BIN="$root/nginx"
mock_version() {
  printf '#!/bin/sh\nprintf "%%s\\n" %q >&2\nexit %s\n' "$1" "${2:-0}" > "$NGINX_BIN"
  chmod +x "$NGINX_BIN"
}
for v in 1.18.0 1.22.1 1.25.0; do
  mock_version "nginx version: nginx/$v"
  [[ "$(nginx_http2_syntax)" == listen ]]
done
for v in 1.25.1 1.26.3 1.28.3 2.0.0; do
  mock_version "nginx version: nginx/$v"
  [[ "$(nginx_http2_syntax)" == directive ]]
done
mock_version 'nginx version: nginx/1.25.1 (Ubuntu)'
[[ "$(nginx_http2_syntax)" == directive ]]
for v in '' 'nginx version: nginx/garbage' 'nginx version: nginx/99999999999999999999.2.3' '1.28.3'; do
  mock_version "$v"
  [[ "$(nginx_http2_syntax 2> "$root/diagnostic")" == listen ]]
  [[ -s "$root/diagnostic" ]]
done
mock_version 'nginx version: nginx/1.28.3' 1
[[ "$(nginx_http2_syntax 2>/dev/null)" == listen ]]
NGINX_BIN="$root/missing"
[[ "$(nginx_http2_syntax 2>/dev/null)" == listen ]]
NGINX_BIN="$root/nginx"
ipv6_available() { return 0; }
mkdir -p "$SSL_DIR/example.com"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com -addext subjectAltName=DNS:example.com \
  -keyout "$SSL_DIR/example.com/privkey.pem" -out "$SSL_DIR/example.com/fullchain.pem" >/dev/null 2>&1
printf '# managed_by=Nginx-X\nserver {\n listen 18080;\n listen [::]:18080;\n server_name example.com; location / { return 200 ok; } }\n' > "$root/plain"
for mode in old modern; do
  v=1.22.1; [[ "$mode" != modern ]] || v=1.28.3
  mock_version "nginx version: nginx/$v"
  build_external_proxy_conf example.com 18443 http://127.0.0.1:3000 normal "$root/template" 1
  nx_https_transform enable "$root/plain" example.com "$SSL_DIR" 18443 > "$root/tls"
  for f in template tls; do
    if [[ "$mode" == modern ]]; then
      [[ "$(grep -c 'http2 on;' "$root/$f")" == 1 ]]
      if grep -Eq 'listen .*http2' "$root/$f"; then exit 1; fi
    else
      [[ "$(grep -c 'listen .*ssl http2;' "$root/$f")" == 2 ]]
      if grep -q 'http2 on;' "$root/$f"; then exit 1; fi
    fi
    # Shared parser accepts both forms as TLS and preserves listener families.
    conf_https_enabled "$root/$f"
    nx_access_parse "$root/$f" scan >/dev/null
  done
  nx_https_transform disable "$root/tls" example.com "$SSL_DIR" '' > "$root/restored"
  if grep -Eq 'ssl|http2' "$root/restored"; then exit 1; fi
  grep -Fq 'listen [::]:18080;' "$root/restored"
done
# Uniform managed legacy config can migrate; imported/custom TLS is not rewritten.
mock_version 'nginx version: nginx/1.22.1'
nx_https_transform enable "$root/plain" example.com "$SSL_DIR" 18443 > "$root/legacy"
mock_version 'nginx version: nginx/1.28.3'
nx_https_transform enable "$root/legacy" example.com "$SSL_DIR" 18443 > "$root/migrated"
grep -q 'http2 on;' "$root/migrated"
if grep -Eq 'listen .*http2' "$root/migrated"; then exit 1; fi
sed '/managed_by=/d' "$root/legacy" > "$root/custom"
nx_https_transform enable "$root/custom" example.com "$SSL_DIR" 18443 > "$root/kept"
cmp "$root/custom" "$root/kept"
for setting in on off; do
  sed "s/http2 on;/http2 $setting;/" "$root/migrated" > "$root/explicit"
  nx_https_transform enable "$root/explicit" example.com "$SSL_DIR" 18443 > "$root/kept"
  cmp "$root/explicit" "$root/kept"
  # A modify/rebuild must retain the explicit server-level protocol decision.
  nx_https_transform enable "$root/plain" example.com "$SSL_DIR" 18443 "$root/explicit" > "$root/rebuilt"
  grep -q "http2 $setting;" "$root/rebuilt"
  if grep -Eq 'listen .*http2' "$root/rebuilt"; then exit 1; fi
  mock_version 'nginx version: nginx/1.22.1'
  nx_https_transform enable "$root/plain" example.com "$SSL_DIR" 18443 "$root/explicit" > "$root/downgraded"
  if grep -Eq 'http2 (on|off);' "$root/downgraded"; then exit 1; fi
  if [[ "$setting" == on ]]; then
    [[ "$(grep -c 'listen .*ssl http2;' "$root/downgraded")" == 2 ]]
  elif grep -q http2 "$root/downgraded"; then exit 1; fi
  mock_version 'nginx version: nginx/1.28.3'
done
NGINX_BIN="$root/missing"
nx_https_transform enable "$root/legacy" example.com "$SSL_DIR" 18443 > "$root/kept" 2>/dev/null
cmp "$root/legacy" "$root/kept"
echo 'PASS: HTTP/2 version boundaries, templates, transforms, explicit decisions and conservative fallback'
