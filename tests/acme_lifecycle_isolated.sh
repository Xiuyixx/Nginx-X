#!/usr/bin/env bash
# Run in an isolated root filesystem/network: NX_ACME_ISOLATED=1 bash tests/acme_lifecycle_isolated.sh
set -euo pipefail
if [[ ${NX_ACME_ISOLATED:-0} != 1 ]]; then
  echo 'skip: ACME privileged lifecycle requires an isolated root filesystem and network'
  exit 0
fi
# shellcheck disable=SC1091
source "$(dirname "$0")/../nx.sh"
# shellcheck disable=SC2034
SUDO=''
CONF_DIR=/etc/nginx/acme-test
SSL_DIR=/etc/nginx/ssl-test
NGINX_MAIN_CONF=/etc/nginx/nginx-acme-test.conf
# shellcheck disable=SC2034
DOMAIN_ONLY_STATE=/etc/nginx/acme-test-policy
mkdir -p "$CONF_DIR" "$SSL_DIR/example.com" /usr/share/nginx/html/.well-known/acme-challenge
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com \
  -keyout "$SSL_DIR/example.com/privkey.pem" -out "$SSL_DIR/example.com/fullchain.pem" >/dev/null 2>&1
cat > "$NGINX_MAIN_CONF" <<CONF
pid /tmp/acme-test.pid;
error_log /tmp/acme-test-error.log;
events {}
http { access_log off; map \$http_upgrade \$connection_upgrade { default upgrade; '' close; } include $CONF_DIR/*.conf; }
CONF
reload_nginx_safe() {
  nginx -t -c "$NGINX_MAIN_CONF" || return 1
  [[ ${FAIL_RELOAD:-0} == 0 ]] || return 8
  if [[ -s /tmp/acme-test.pid ]]; then
    nginx -s reload -c "$NGINX_MAIN_CONF"
  else
    nginx -c "$NGINX_MAIN_CONF"
  fi
}
trap 'nginx -s quit -c "$NGINX_MAIN_CONF" >/dev/null 2>&1 || true' EXIT
ensure_websocket_map() { :; }
# Legacy plain :80 site had a deployed cert before route markers existed.
build_proxy_conf example.com 80 3000 "$CONF_DIR/legacy.conf"
nx_transaction nx_remove_conf "$CONF_DIR/legacy.conf"
[[ -f "$CONF_DIR/.nx-acme-example.com.state" ]]
# The first transaction starts a real daemon. A second mutation must acquire
# the lock while that daemon survives, with a bounded failure on regression.
export NX_CONF_DIR="$CONF_DIR" SSL_DIR NGINX_MAIN_CONF DOMAIN_ONLY_STATE
# shellcheck disable=SC2016 # expanded by the isolated child shell
timeout 15 bash -c 'source "$1/nx.sh"; SUDO=""; reload_nginx_safe() { nginx -t -c "$NGINX_MAIN_CONF" && nginx -s reload -c "$NGINX_MAIN_CONF"; }; nx_transaction touch "$CONF_DIR/second-mutation"' _ "$(cd "$(dirname "$0")/.." && pwd)"
NX_ACME_PENDING=example.com nx_transaction nx_acme_prepare_routes example.com
build_proxy_conf example.com 8080 3000 /tmp/acme-plain
nx_https_transform enable /tmp/acme-plain example.com "$SSL_DIR" 8443 > /tmp/acme-tls
apply_conf_with_rollback /tmp/acme-tls "$CONF_DIR/site.conf"
[[ ! -e "$CONF_DIR/acme-challenge-example.com.conf" ]]
printf token > /usr/share/nginx/html/.well-known/acme-challenge/test
request() { curl -s --retry 10 --retry-delay 0 --retry-connrefused -H 'Host: example.com' "$@"; }
# Reload is asynchronous; poll meaningful responses rather than sleeping.
for ((i=0;i<100;i++)); do
  headers="$(request -I http://127.0.0.1/hello)"
  [[ "$headers" == *'https://example.com:8443/hello'* ]] && break
done
[[ "$headers" == *'301 Moved Permanently'* && "$headers" == *'https://example.com:8443/hello'* ]]
[[ "$(request http://127.0.0.1/.well-known/acme-challenge/test)" == token ]]
# shellcheck disable=SC2016 # literal nginx variables
# An unmanaged map and unnamed status server may coexist with retained routes.
printf 'map $request_method $acme_test_method { default 0; }\nserver { listen 127.0.0.1:8099; location / { return 200; } }\n' > "$CONF_DIR/status.conf"
FAIL_RELOAD=1
if disable_conf site.conf; then exit 1; fi
[[ -f "$CONF_DIR/site.conf" && ! -f "$CONF_DIR/acme-challenge-example.com.conf" ]]
FAIL_RELOAD=0
disable_conf site.conf
[[ -f "$CONF_DIR/acme-challenge-example.com.conf" ]]
for ((i=0;i<100;i++)); do
  status="$(request -o /dev/null -w '%{http_code}' http://127.0.0.1/hello)"
  [[ "$status" == 404 ]] && break
done
[[ "$status" == 404 ]]
[[ "$(request http://127.0.0.1/.well-known/acme-challenge/test)" == token ]]
# Helper tampering blocks a mutation and preserves the current application.
printf '\n# harmless comment\n' >> "$CONF_DIR/acme-challenge-example.com.conf"
enable_conf site.conf.bak
[[ ! -e "$CONF_DIR/acme-challenge-example.com.conf" ]]
confirm() { return 0; }
delete_conf site.conf
[[ -f "$CONF_DIR/acme-challenge-example.com.conf" ]]
FAIL_RELOAD=1
if nx_delete_certificate example.com; then exit 1; fi
[[ -s "$SSL_DIR/example.com/privkey.pem" && -f "$CONF_DIR/acme-challenge-example.com.conf" ]]
FAIL_RELOAD=0
nx_delete_certificate example.com
[[ ! -e "$CONF_DIR/acme-challenge-example.com.conf" && ! -e "$CONF_DIR/.nx-acme-example.com.state" ]]
echo 'ok: real HTTP 301 correct TLS port, challenge 200, disabled/deleted route, rollback and certificate removal'
