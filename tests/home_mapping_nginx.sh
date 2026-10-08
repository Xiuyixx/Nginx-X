#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
source ./nx.sh
nginx_bin="${NGINX_TEST_BIN:-$(command -v nginx || true)}"
[[ -x "$nginx_bin" ]] || { echo 'skip: real nginx unavailable'; exit 0; }
root="$NX_TEST_ENV_ROOT"
chmod 755 "$root"
SUDO=''
export NX_BACKEND_STATE_DIR="$root/backend" NX_BACKEND_UNIT_DIR="$root/units" NX_BACKEND_LIBEXEC_DIR="$root/libexec"
ipv6_available() { return 1; }
cleanup() {
 local rc=$?
 if (( rc )); then cat "$root/validation.log" "$root/error.log" 2>/dev/null || true; fi
 if [[ -s "$root/nginx.pid" ]]; then
  "$nginx_bin" -p "$root/" -c "$NGINX_MAIN_CONF" -s quit >/dev/null 2>&1 || true
  nx_test_wait_pidfile "$root/nginx.pid"
 fi
 nx_test_cleanup
 return "$rc"
}
trap cleanup EXIT
mkdir -p "$SSL_DIR/example.com" "$root/web/.well-known/acme-challenge"
echo acme-proof > "$root/web/.well-known/acme-challenge/proof"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com \
 -addext subjectAltName=DNS:example.com -keyout "$SSL_DIR/example.com/privkey.pem" \
 -out "$SSL_DIR/example.com/fullchain.pem" >/dev/null 2>&1
# Independent upstream exposes URI, arguments and method without its own rewrite.
cat > "$root/upstream.conf" <<'CONF'
server {
 listen 127.0.0.1:18971;
 server_name upstream.example;
 location / { return 200 "$request_method|$uri|$args"; }
}
CONF
cat > "$NGINX_MAIN_CONF" <<CONF
user $(id -un);
pid $root/nginx.pid;
error_log $root/error.log notice;
events {}
http {
 access_log off;
 client_body_temp_path $root/body;
 proxy_temp_path $root/proxy;
 fastcgi_temp_path $root/fastcgi;
 uwsgi_temp_path $root/uwsgi;
 scgi_temp_path $root/scgi;
 map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
 include $root/upstream.conf;
 include $CONF_DIR/*.conf;
}
CONF
site="$CONF_DIR/example.com-18970.conf"
build_proxy_conf example.com 18970 18971 "$site"
# Preserve a private ACME root in this fixture; never touch the system webroot.
chmod 640 "$site"
attrs="$(stat -c '%u:%g:%a' "$site")"
reload_nginx_safe() {
 # Use an isolated daemon candidate; retain port 80 in product metadata/config.
 local candidate="$root/daemon.conf" rc=0 generation
 generation="$(($(cat "$root/generation" 2>/dev/null || echo 0) + 1))"
 echo "$generation" > "$root/generation"
 sed 's/listen 80;/listen 18973;/; s/listen \[::\]:80;/listen [::]:18973;/' "$site" > "$root/daemon-site"
 sed "s@include $CONF_DIR/\*.conf;@include $root/daemon-site;@" "$NGINX_MAIN_CONF" > "$candidate"
 # A private listener identifies this exact generation without changing the
 # business fixture. The same marker also diagnoses reload readiness.
 sed -i "/^http {/a\\ server { listen 127.0.0.1:18974; location = /__generation { return 200 '$generation'; } }" "$candidate"
 "$nginx_bin" -t -p "$root/" -c "$candidate" >> "$root/validation.log" 2>&1 || return 1
 if [[ -s "$root/nginx.pid" ]]; then
  [[ ! -f "$root/fail-reload" ]] || { rm "$root/fail-reload"; return 1; }
  "$nginx_bin" -p "$root/" -c "$candidate" -s reload >> "$root/reload.log" 2>&1 || rc=$?
 else "$nginx_bin" -p "$root/" -c "$candidate" || rc=$?; fi
 (( rc == 0 )) || return "$rc"
 # -s reload only delivers SIGHUP. Wait for the new configuration generation
 # on every fresh connection, including same-response reloads and rollbacks.
 wait_response "$generation" --http1.1 -H 'Connection: close' \
  --resolve 'example.com:18974:127.0.0.1' 'http://example.com:18974/__generation' || return 1
 echo applied >> "$root/applies"
}
# Request assertions are bounded state waits, not sleeps or whole-test retries.
# A successful marker/GET may be followed by a connection accepted by an old
# worker (e.g. old ACME root, old method guard, or disappearing TLS listener).
wait_response() {
 local expected="$1" actual='' rc=0
 shift
 for _ in {1..150}; do
  rc=0
  actual="$(curl --noproxy '*' -ksS --connect-timeout 1 --max-time 2 "$@" 2> "$root/curl-error")" || rc=$?
  if (( rc == 0 )) && [[ "$actual" == "$expected" ]]; then return 0; fi
  sleep .03
 done
 printf 'request did not converge: expected=%s actual=%s curl_rc=%s args=%s\n' "$expected" "$actual" "$rc" "$*" >&2
 cat "$root/curl-error" >&2
 return 1
}
wait_request() {
 local expected="$1"
 shift
 wait_response "$expected" --http1.1 -H 'Connection: close' --resolve "example.com:$port:127.0.0.1" "$@" "$scheme://example.com:$port$path"
}
wait_root() { wait_request "$1"; }
port=18970 scheme=http path='/?a=1&b=two'
nx_home_set "$site" /management.html
# Isolate the generated ACME webroot without touching the host path.
sed -i "s@/usr/share/nginx/html@$root/web@" "$site"
reload_nginx_safe
wait_root 'GET|/management.html|a=1&b=two'
check_requests() {
 path='/?a=1&b=two'; wait_root 'GET|/management.html|a=1&b=two'
 wait_request 200 -I -o /dev/null -w '%{http_code}'
 for method in POST PUT DELETE OPTIONS PATCH; do
  wait_request 405 -X "$method" -o /dev/null -w '%{http_code}'
 done
 path='/v1/chat?item=fixture'; wait_request 'GET|/v1/chat|item=fixture'
 wait_request 'POST|/v1/chat|item=fixture' -X POST -d payload
 path='/.well-known/acme-challenge/proof'; wait_request acme-proof
 path='/'; wait_request 'GET|/management.html|' -D "$root/headers"
 if grep -qi '^Location:' "$root/headers"; then exit 1; fi
}
check_requests
# HTTPS transitions preserve mapping and redirects; challenge remains independent.
enable_https_for_conf_file example.com "$site" 18972
port=18972 scheme=https
check_requests
[[ "$(nx_home_status "$site")" == /management.html ]]
# Validate the generated port-80 redirect structurally without contacting host port 80.
grep -Fq 'return 301 https://$host:18972$request_uri;' "$site"
[[ "$(grep -c 'location = /' "$site")" == 1 ]]
disable_https_for_conf_file example.com "$site"
port=18970 scheme=http
check_requests
# nginx -t failure really reaches Nginx, then restores exact bytes and live response.
cp "$site" "$root/before"
saved="$(declare -f nx_home_set_files)"
eval "${saved/nx_home_set_files/home_original_set_files}"
nx_home_set_files() {
 home_original_set_files "$@" || return 1
 sed -i '/server_name /a\    nx_home_unknown_directive on;' "$1"
}
run_menu_action nx_home_set "$site" /bad.html > "$root/failure" 2>&1
cmp "$site" "$root/before"
grep -q 'unknown directive "nx_home_unknown_directive"' "$root/validation.log"
eval "$saved"
path='/'; wait_root 'GET|/management.html|'
# Reload failure after valid publication also restores old live response/mode.
touch "$root/fail-reload"
if nx_home_set "$site" /other.html > "$root/reload-failure" 2>&1; then exit 1; fi
cmp "$site" "$root/before"
[[ "$(stat -c '%u:%g:%a' "$site")" == "$attrs" ]]
wait_root 'GET|/management.html|'
nx_home_set "$site" ''
wait_root 'GET|/|'
wait_request 'POST|/|' -X POST -d payload
echo 'PASS: real HTTP/TLS homepage, query, HEAD, methods, API, ACME, HTTPS roundtrip, nginx-t/reload rollback and permissions'
