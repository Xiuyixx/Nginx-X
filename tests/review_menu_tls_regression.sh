#!/usr/bin/env bash
# shellcheck disable=SC2317
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
source ./nx.sh
root="$NX_TEST_ENV_ROOT"
SUDO=''
CONF_DIR="$NX_CONF_DIR"
require_nginx_installed() { :; }
is_port_used_os() { return 0; }
port_has_ssl_listener() { return 0; }
confirm() { return 0; }
select_external_mode() { echo normal; }
mkdir -p "$SSL_DIR/example.com"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com \
 -addext subjectAltName=DNS:example.com -keyout "$SSL_DIR/example.com/privkey.pem" \
 -out "$SSL_DIR/example.com/fullchain.pem" >/dev/null 2>&1
reload_nginx_safe() {
  local count=0
  [[ ! -f "$root/reloads" ]] || count="$(cat "$root/reloads")"
  echo "$((count+1))" > "$root/reloads"
  cp "$CONF_DIR/example.com-18443.conf" "$root/published-$((count+1))"
}
for action in add_reverse_proxy add_external_url_proxy; do
 rm -f "$CONF_DIR"/* "$root"/published-* "$root/reloads"
 if [[ "$action" == add_reverse_proxy ]]; then input=$'example.com\n18443\n3000'; else input=$'example.com\n18443\nhttp://127.0.0.1:3000'; fi
 "$action" <<< "$input" > "$root/output" 2>&1
 [[ "$(cat "$root/reloads")" == 1 ]]
 grep -q 'listen 18443 ssl' "$root/published-1"
 # Port 80 is challenge/redirect only, never the application proxy.
 python3 - "$root/published-1" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
assert 'proxy_pass' in s
assert s.index('listen 18443 ssl') < s.index('proxy_pass')
assert 'listen 80;' not in s[s.index('listen 18443 ssl'):]
PY
 rm -f "$CONF_DIR"/* "$root"/published-* "$root/reloads"
 (
  nx_https_transform() { return 1; }
  if "$action" <<< "$input" > "$root/output" 2>&1; then exit 1; fi
  [[ ! -e "$CONF_DIR/example.com-18443.conf" && ! -e "$root/reloads" ]]
  run_menu_action "$action" <<< "$input" > "$root/output" 2>&1
  grep -q '操作未完成' "$root/output"
 )
 (
  reload_nginx_safe() { return 1; }
  if "$action" <<< "$input" > "$root/output" 2>&1; then exit 1; fi
  [[ ! -e "$CONF_DIR/example.com-18443.conf" ]]
  run_menu_action "$action" <<< "$input" > "$root/output" 2>&1
  grep -q "操作未完成" "$root/output"
  if grep -q "配置已生效" "$root/output"; then exit 1; fi
 )
done
echo 'review TLS menu atomic publication: PASS'
# Actual Nginx validation failure must also fail under the conditional menu.
# An unknown directive survives parsers and reaches the real nginx -t branch.
nginx_bin="${NGINX_TEST_BIN:-$(command -v nginx)}"
rm -f "$CONF_DIR"/* "$root"/published-* "$root/reloads"
cat > "$NGINX_MAIN_CONF" <<CONF
pid $root/nginx.pid;
error_log $root/error.log;
events {}
http {
 client_body_temp_path $root/body;
 proxy_temp_path $root/proxy;
 fastcgi_temp_path $root/fastcgi;
 uwsgi_temp_path $root/uwsgi;
 scgi_temp_path $root/scgi;
 include $CONF_DIR/*.conf;
}
CONF
saved_builder="$(declare -f build_proxy_conf)"
eval "${saved_builder/build_proxy_conf/review_build_original}"
build_proxy_conf() {
 review_build_original "$@" || return 1
 # Valid server-level syntax reaches Nginx, unlike unsupported top-level input.
 sed -i '/server_name /a\    nx_review_unknown_directive on;' "$4" || return 1
}
reload_nginx_safe() { "$nginx_bin" -t -p "$root/" -c "$NGINX_MAIN_CONF"; }
run_menu_action add_reverse_proxy <<< $'example.com\n18443\n3000' > "$root/validation-failure" 2>&1
[[ ! -e "$CONF_DIR/example.com-18443.conf" ]]
grep -q 'unknown directive "nx_review_unknown_directive"' "$root/validation-failure"
grep -q '操作未完成' "$root/validation-failure"
if grep -q '配置已生效' "$root/validation-failure"; then exit 1; fi
echo 'review TLS menu real nginx validation rollback: PASS'
