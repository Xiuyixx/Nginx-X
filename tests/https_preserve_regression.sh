#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_DIR/nx.sh"
# shellcheck disable=SC1091
source "$REPO_DIR/lib/https.sh"
# Fixtures belong to the test user; only nginx -t may require elevation.
# shellcheck disable=SC2034
SUDO=""
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
SSL_DIR="$TEST_ROOT/ssl"
mkdir -p "$SSL_DIR/example.com"
NGINX_TEST_BIN="${NGINX_TEST_BIN:-$(command -v nginx || true)}"
if [[ -z "$NGINX_TEST_BIN" ]]; then
  NGINX_TEST_BIN=/root/.openclaw/workspace/tmp/nginx-x-test-runtime/extracted/usr/sbin/nginx
fi
[[ -x "$NGINX_TEST_BIN" ]] || { echo 'Set NGINX_TEST_BIN to a real Nginx binary' >&2; exit 1; }
# HTTPS migration deliberately retains the ACME listener on privileged port 80.
# Some nginx builds bind listeners during -t, so CI needs sudo for validation.
nginx_test_command=("$NGINX_TEST_BIN")
if [[ ${EUID:-0} -ne 0 ]] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  nginx_test_command=(sudo "$NGINX_TEST_BIN")
fi
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com -addext subjectAltName=DNS:example.com,DNS:alias.example.com \
  -keyout "$SSL_DIR/example.com/privkey.pem" -out "$SSL_DIR/example.com/fullchain.pem" >/dev/null 2>&1
# Exercise the transformation through its public API, with real syntax validation.
# The shared transaction helper's rollback mechanics have their own regression suite.
apply_count=0
apply_conf_with_rollback() {
  local candidate="$1" target="$2"
  apply_count=$((apply_count + 1))
  [[ "${FAIL_APPLY:-0}" != 1 ]] || return 1
  cat > "$TEST_ROOT/nginx.conf" <<EOF
pid $TEST_ROOT/nginx.pid;
error_log stderr;
events {}
http {
    access_log off;
    client_body_temp_path $TEST_ROOT/body-temp;
    proxy_temp_path $TEST_ROOT/proxy-temp;
    fastcgi_temp_path $TEST_ROOT/fastcgi-temp;
    uwsgi_temp_path $TEST_ROOT/uwsgi-temp;
    scgi_temp_path $TEST_ROOT/scgi-temp;
    map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
    include $candidate;
}
EOF
  "${nginx_test_command[@]}" -t -p "$TEST_ROOT" -c "$TEST_ROOT/nginx.conf" > "$TEST_ROOT/nginx-test.log" 2>&1 || {
    cat "$TEST_ROOT/nginx-test.log" >&2
    return 1
  }
  cp "$candidate" "$target"
}
conf="$TEST_ROOT/site.conf"
cat > "$conf" <<'EOF'
# managed_by=Nginx-X
# imported=true
# edited=true
# domain=example.com
# listen_port=8080
# backend_port=3000
server {
    listen 127.0.0.1:8080 default_server;
    listen [::1]:8080 ipv6only=on;
    server_name example.com alias.example.com;
    # Keep a literal closing brace } and a quoted semicolon.
    add_header X-Custom "brace }; # untouched" always;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header X-Path "${request_uri}";
    }
    location /api/ { proxy_pass http://127.0.0.1:4000/v2/; }
    location ~ "^/assets/[a-z]{2}\\.txt$" { return 200 'asset; { ok }'; }
}
EOF
cp "$conf" "$TEST_ROOT/original"
sed -n '/    # Keep/,$p' "$conf" > "$TEST_ROOT/body"
enable_https_for_conf_file example.com "$conf" 8443
grep -Fq 'listen 127.0.0.1:8443 default_server ssl http2;' "$conf"
grep -Fq 'listen [::1]:8443 ipv6only=on ssl http2;' "$conf"
grep -Fq 'listen [::1]:80 ipv6only=on;' "$conf"
# shellcheck disable=SC2016
grep -Fq 'return 301 https://$host:8443$request_uri;' "$conf"
grep -q '^# https_original_listen_port=8080$' "$conf"
[[ "$(grep -c 'server_name example.com alias.example.com;' "$conf")" == 2 ]]
cmp "$TEST_ROOT/body" <(sed -n '/    # Keep/,$p' "$conf")
cp "$conf" "$TEST_ROOT/enabled"
before_count="$apply_count"
enable_https_for_conf_file example.com "$conf" 8443
[[ "$apply_count" == "$before_count" ]]
cmp "$conf" "$TEST_ROOT/enabled"
disable_https_for_conf_file example.com "$conf"
grep -Fq 'listen 127.0.0.1:8080 default_server;' "$conf"
grep -Fq 'listen [::1]:8080 ipv6only=on;' "$conf"
grep -q '^# listen_port=8080$' "$conf"
if grep -q 'ssl_certificate\|return 301\|https_original_listen_port' "$conf"; then
  echo 'TLS state or redirect survived disable' >&2; exit 1
fi
cmp "$TEST_ROOT/body" <(sed -n '/    # Keep/,$p' "$conf")
# Plain IPv4 sites must not acquire an IPv6 binding during a toggle.
printf 'server { listen 80; server_name example.com alias.example.com; location / { return 200 "ok"; } }\n' > "$conf"
enable_https_for_conf_file example.com "$conf"
grep -q 'listen 443 ssl http2;' "$conf"
if grep -Fq '[::]' "$conf"; then
  echo 'IPv4-only site acquired an IPv6 listener' >&2; exit 1
fi
disable_https_for_conf_file example.com "$conf"
grep -q 'listen 80;' "$conf"
# Legacy generated HTTPS: map every TLS address to the metadata port.
cat > "$conf" <<EOF
# listen_port=8081
server {
    listen 80;
    listen [::]:80;
    server_name example.com alias.example.com;
    location ^~ /.well-known/acme-challenge/ {
        root /usr/share/nginx/html;
        default_type "text/plain";
        try_files \$uri =404;
    }
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name example.com alias.example.com;
    ssl_certificate $SSL_DIR/example.com/fullchain.pem;
    ssl_certificate_key $SSL_DIR/example.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    location /api { proxy_pass https://127.0.0.1:3000; proxy_ssl_server_name on; }
}
EOF
disable_https_for_conf_file example.com "$conf"
grep -q 'listen 8081;' "$conf"
grep -Fq 'listen [::]:8081;' "$conf"
grep -q 'proxy_ssl_server_name on;' "$conf"
[[ "$(grep -c 'server {' "$conf")" == 1 ]]
# Refusals and apply failures must leave the original byte-for-byte unchanged.
assert_refused() {
  cp "$conf" "$TEST_ROOT/before-refusal"
  local previous="$apply_count"
  if enable_https_for_conf_file example.com "$conf" > "$TEST_ROOT/refusal.log" 2>&1; then
    echo 'expected HTTPS refusal' >&2; exit 1
  fi
  cmp "$conf" "$TEST_ROOT/before-refusal"
  [[ "$apply_count" == "$previous" ]]
}
for body in \
  'listen unix:/tmp/example.sock;' \
  'listen 80; listen [::]:8080;' \
  'listen 80; include custom.conf;' \
  'listen 80; ssl_protocols TLSv1.2;' \
  'listen 443 quic;'; do
  printf 'server { %s server_name example.com; location / { return 200 ok; } }\n' "$body" > "$conf"
  assert_refused
done
printf 'server { listen 80; server_name example.com; } server { listen 81; server_name other.example.com; }\n' > "$conf"
assert_refused
cp "$TEST_ROOT/original" "$conf"
if FAIL_APPLY=1 enable_https_for_conf_file example.com "$conf" >/dev/null 2>&1; then
  echo 'expected apply failure' >&2; exit 1
fi
cmp "$conf" "$TEST_ROOT/original"
# Metadata-like text inside quoted directives and body/inline comments must
# neither select the HTTPS port nor be rewritten by metadata updates.
cat > "$conf" <<'SITE'
map $host $metadata_decoy { default "quoted
# listen_port=19001
# https_original_listen_port=19002
# access_default=0.0.0.0:19003
"; }
server {
 listen 18080;
 server_name example.com;
# listen_port=19004
# https_original_listen_port=19005
# access_default=0.0.0.0:19006
 location / { return 200 'quoted
# listen_port=19007
# https_original_listen_port=19008
# access_default=0.0.0.0:19009
'; }
} # listen_port=19010
SITE
cp "$conf" "$TEST_ROOT/metadata-decoys"
enable_https_for_conf_file example.com "$conf"
grep -q 'listen 18080 ssl http2;' "$conf"
disable_https_for_conf_file example.com "$conf"
diff -u <(grep '^# .*190' "$TEST_ROOT/metadata-decoys") <(grep '^# .*190' "$conf")
grep -q '} # listen_port=19010' "$conf"
grep -q 'listen 18080;' "$conf"
# Genuine duplicate metadata anywhere at top level must still be refused.
printf '# listen_port=18080\nserver { listen 18080; server_name example.com; }\n# listen_port=18081\n' > "$conf"
assert_refused
# A custom redirect server cannot be discarded on disable.
cp "$TEST_ROOT/enabled" "$conf"
sed -i '/return 301/i\    add_header X-Redirect-Custom keep;' "$conf"
cp "$conf" "$TEST_ROOT/before-refusal"
if disable_https_for_conf_file example.com "$conf" >/dev/null 2>&1; then
  echo 'expected refusal to remove custom redirect' >&2; exit 1
fi
cmp "$conf" "$TEST_ROOT/before-refusal"
echo 'ok: HTTPS transformations preserve application content, aliases, and listener families'
# Compose the actual transaction, strict guards, and HTTPS parser. Generated
# guards must not turn the recognized redirect into an ambiguous custom server.
# shellcheck disable=SC1091
source "$REPO_DIR/lib/transactions.sh"
CONF_DIR="$TEST_ROOT/integrated"
STATE_DIR="$TEST_ROOT/state"
# Consumed by sourced access-policy helpers.
# shellcheck disable=SC2034
DOMAIN_ONLY_STATE="$STATE_DIR/domain-only.conf"
mkdir -p "$CONF_DIR" "$STATE_DIR"
conf="$CONF_DIR/integrated.conf"
cat > "$conf" <<'SITE'
# managed_by=Nginx-X
# domain=example.com
# listen_port=18080
server {
 listen 127.0.0.1:18080;
 listen [::1]:18080;
 server_name example.com alias.example.com;
 location / { return 200 'kept'; }
 location /custom { return 200 'custom'; }
}
SITE
nginx_local_version() {
  "$NGINX_TEST_BIN" -v 2>&1 | sed -E 's#^nginx version: nginx/##'
}
reload_nginx_safe() {
  sed "s@include .*;@include $CONF_DIR/*.conf;@" "$TEST_ROOT/nginx.conf" > "$TEST_ROOT/integrated-nginx.conf"
  "${nginx_test_command[@]}" -t -p "$TEST_ROOT" -c "$TEST_ROOT/integrated-nginx.conf" > "$TEST_ROOT/nginx-test.log" 2>&1 || { cat "$TEST_ROOT/nginx-test.log" >&2; return 1; }
}
nx_access_set_policy "$conf" strict
nx_access_set_default "$conf" '127.0.0.1:18080'
[[ "$(tail -n 1 "$conf")" == '# access_default=127.0.0.1:18080' ]]
enable_https_for_conf_file example.com "$conf" 18443
grep -q '^# access_default=127.0.0.1:18443$' "$conf"
grep -q 'nx-access-begin' "$conf"
nx_access_set_default "$conf" '127.0.0.1:80,127.0.0.1:18443'
disable_https_for_conf_file example.com "$conf"
grep -q '^# access_default=127.0.0.1:18080$' "$conf"
grep -Fq 'listen [::1]:18080;' "$conf"
grep -Fq "return 200 'custom'" "$conf"
grep -q 'nx-access-begin' "$conf"
# shellcheck disable=SC2016
if grep -q '\$ssl_server_name' "$conf"; then echo 'TLS guard survived HTTPS disable' >&2; exit 1; fi
# A redirect-only default is cleared when its socket disappears.
enable_https_for_conf_file example.com "$conf" 18443
nx_access_set_default "$conf" '127.0.0.1:80'
disable_https_for_conf_file example.com "$conf"
grep -q '^# access_default=$' "$conf"
# Returning to port 80 merges the TLS and redirect choices into one default.
cat > "$conf" <<'SITE'
# managed_by=Nginx-X
# domain=example.com
server { listen 80; server_name example.com; location / { return 200 'kept'; } }
SITE
nx_access_set_default "$conf" '0.0.0.0:80'
enable_https_for_conf_file example.com "$conf" 18443
grep -q '^# access_default=0.0.0.0:18443$' "$conf"
nx_access_set_default "$conf" '0.0.0.0:80,0.0.0.0:18443'
disable_https_for_conf_file example.com "$conf"
grep -q '^# access_default=0.0.0.0:80$' "$conf"
echo 'ok: strict policy, explicit default, and HTTPS round trip'

# Unsupported alias coverage must refuse before any apply, preserving aliases.
cp "$conf" "$TEST_ROOT/uncovered.conf"
sed -i 's/server_name example.com;/server_name example.com uncovered.example.com;/' "$TEST_ROOT/uncovered.conf"
before_count="$apply_count"
if nx_https_transform enable "$TEST_ROOT/uncovered.conf" example.com "$SSL_DIR" 8443 > "$TEST_ROOT/refused" 2> "$TEST_ROOT/refusal"; then
  echo 'uncovered alias accepted' >&2; exit 1
fi
grep -q 'does not cover server_name uncovered.example.com' "$TEST_ROOT/refusal"
[[ "$apply_count" == "$before_count" ]]
# Server rewrite phase runs before ACME location selection. Refuse such valid
# configs through the actual challenge helper before any publication.
CONF_DIR="$TEST_ROOT/challenge-conf"
mkdir -p "$CONF_DIR"
apply_conf_with_rollback() { apply_count=$((apply_count + 1)); return 1; }
# shellcheck disable=SC2016
for routing in 'rewrite ^ /blocked permanent;' 'if ($request_uri) { return 403; }'; do
  printf 'server { listen 80; server_name example.com; %s location / { return 200 ok; } }\n' "$routing" > "$CONF_DIR/rewrite.conf"
  # Prove these are real valid Nginx configs, not malformed parser fixtures.
  reload_nginx_safe
  cp "$CONF_DIR/rewrite.conf" "$TEST_ROOT/rewrite-before"
  before_count="$apply_count"
  if ensure_acme_location_for_domain_conf example.com 2> "$TEST_ROOT/rewrite-refusal"; then exit 1; fi
  grep -q 'server-level rewrite/if precedes HTTP-01' "$TEST_ROOT/rewrite-refusal"
  [[ "$apply_count" == "$before_count" ]]
  cmp "$TEST_ROOT/rewrite-before" "$CONF_DIR/rewrite.conf"
done
echo 'ok: real Nginx server rewrite/if challenge refusal before publishing'
