#!/usr/bin/env bash
# Dynamic menu/test callbacks are invoked indirectly by sourced functions.
# shellcheck disable=SC2317,SC1091,SC1090,SC2016,SC2034
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
root="$NX_TEST_ENV_ROOT"
repo="$PWD"
template_test_cleanup() {
 local rc=$?
 if (( rc != 0 )); then
   echo "FAIL template safety: entry=${entry:-setup} mode=${mode:-setup}" >&2
   for log in "$root/menu" "$root/refusal" "$root/nginx-test.log"; do
     [[ -f "$log" ]] || continue
     echo "--- ${log##*/} ---" >&2
     tail -60 "$log" >&2
   done
 fi
 nx_test_cleanup
 return "$rc"
}
trap template_test_cleanup EXIT
bash tools/build-bundle.sh "$root/bundle"
nginx_bin="${NGINX_TEST_BIN:-$(command -v nginx || true)}"
[[ -x "$nginx_bin" ]] || { echo 'SKIP: real nginx unavailable'; exit 0; }
export NGINX_BIN="$nginx_bin"
mkdir -p "$SSL_DIR/example.com"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com \
 -addext subjectAltName=DNS:example.com,DNS:alias.example.com \
 -keyout "$SSL_DIR/example.com/privkey.pem" -out "$SSL_DIR/example.com/fullchain.pem" >/dev/null 2>&1
cat > "$NGINX_MAIN_CONF" <<CONF
pid $root/nginx.pid;
error_log $root/error.log;
events {}
http {
 access_log off;
 client_body_temp_path $root/body;
 proxy_temp_path $root/proxy;
 fastcgi_temp_path $root/fastcgi;
 uwsgi_temp_path $root/uwsgi;
 scgi_temp_path $root/scgi;
 map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
 include $NX_CONF_DIR/*.conf;
}
CONF
for entry in "$repo/nx.sh" "$root/bundle"; do
 (
 source "$entry"
 SUDO=''
 ipv6_available() { return 1; }
 is_port_used_os() { return 1; }
 reload_nginx_safe() {
   local check_conf="$NGINX_MAIN_CONF" check_dir source target
   if [[ ${EUID:-$(id -u)} != 0 ]]; then
     # nginx -t binds listeners on these runners. Validate an identical copy
     # with only the generated port-80 redirect remapped to an unprivileged
     # port; the production fixture remains unchanged for all assertions.
     check_dir="$root/nginx-check-conf"
     rm -rf "$check_dir" || return 1
     mkdir -p "$check_dir" || return 1
     for source in "$CONF_DIR"/*.conf; do
       [[ -f "$source" ]] || continue
       target="$check_dir/$(basename "$source")"
       sed -E \
         -e 's/^([[:space:]]*listen[[:space:]]+)\[::\]:80([[:space:];].*)$/\1[::]:18000\2/' \
         -e 's/^([[:space:]]*listen[[:space:]]+)80([[:space:];].*)$/\118000\2/' \
         "$source" > "$target" || return 1
     done
     check_conf="$root/nginx-check.conf"
     cp "$NGINX_MAIN_CONF" "$check_conf" || return 1
     python3 - "$check_conf" "$CONF_DIR" "$check_dir" <<'PY' || return 1
import pathlib, sys
path, source, target = map(pathlib.Path, sys.argv[1:])
text = path.read_text()
text = text.replace(f'include {source}/*.conf;', f'include {target}/*.conf;')
path.write_text(text)
PY
   fi
   "$nginx_bin" -t -p "$root/" -c "$check_conf" > "$root/nginx-test.log" 2>&1 || { cat "$root/nginx-test.log"; return 1; }
   echo reload >> "$root/reloads"
 }
 site="$CONF_DIR/example.com-18080.conf"
 # A real menu refusal must not enter a transaction or touch attributes/bytes.
 refuse() {
   cp -a "$site" "$root/before"
   local attrs count
   attrs="$(stat -c '%u:%g:%a' "$site")"
   count="$(wc -l < "$root/reloads")"
   if modify_conf "${site##*/}" <<< $'\n\n3001\n' > "$root/refusal" 2>&1; then
     echo "unsafe template accepted: $1"; cat "$root/refusal"; exit 1
   fi
   grep -q '已阻止' "$root/refusal"
   cmp "$site" "$root/before"
   [[ "$(stat -c '%u:%g:%a' "$site")" == "$attrs" && "$(wc -l < "$root/reloads")" == "$count" ]]
   run_menu_action modify_conf "${site##*/}" <<< $'\n\n3001\n' > "$root/refusal" 2>&1
   grep -q '操作未完成' "$root/refusal"
   cmp "$site" "$root/before"
   [[ "$(wc -l < "$root/reloads")" == "$count" ]]
 }
 for mode in internal-normal internal-streaming normal streaming media emby_http emby_https emby_lily; do
   rm -f "$CONF_DIR"/*.conf "$CONF_DIR"/*.bak
   : > "$root/reloads"
   if [[ "$mode" == internal-* ]]; then
     build_proxy_conf example.com 18080 3000 "$site" "${mode#internal-}"
   else
     build_external_proxy_conf example.com 18080 http://127.0.0.1:3000/api/ "$mode" "$site" 0 \
       http://127.0.0.1:3001/ http://127.0.0.1:3000/api/ http://127.0.0.1:3000/api/web/index.html \
       'http://127.0.0.1:3001/|https://127.0.0.1:3002/'
   fi
   chmod 0640 "$site"
   conf_safe_for_template_rebuild "$site"
   cp "$site" "$root/native"
   # Native resave for each supported mode and TLS round-trip.
   modify_conf "${site##*/}" <<< $'\n\n\n\n\n\n\n' > "$root/menu" 2>&1
   conf_safe_for_template_rebuild "$site"
   enable_https_for_conf_file example.com "$site" 18443 > "$root/menu" 2>&1
   conf_safe_for_template_rebuild "$site"
   modify_conf "${site##*/}" <<< $'\n\n\n\n\n\n\n' > "$root/menu" 2>&1
   # HTTPS conversion keeps the source filename; the actual TLS listener is
   # represented by metadata/config content rather than a filename rename.
   site="$CONF_DIR/example.com-18080.conf"
   conf_safe_for_template_rebuild "$site"
   disable_https_for_conf_file example.com "$site" > "$root/menu" 2>&1
   conf_safe_for_template_rebuild "$site"
   rm -f "$site"
   site="$CONF_DIR/example.com-18080.conf"
   cp "$root/native" "$site"
   chmod 0640 "$site"
   # Same directive names with changed values are custom policy, too.
   for rule in 'deny all;' 'if ($host = example.com) { return 403; }' \
       'set $custom value;' 'rewrite ^ /private last;' \
       'proxy_set_header Authorization "";' 'proxy_read_timeout 10s;' \
       'proxy_hide_header Authorization;' 'location /nested { return 403; }'; do
     cp "$root/native" "$site"
     RULE="$rule" python3 - "$site" <<'PY'
import os,sys
p=sys.argv[1];s=open(p).read();s=s.replace('location / {','location / { '+os.environ['RULE'],1);open(p,'w').write(s)
PY
     refuse "$mode: $rule"
   done
   cp "$root/native" "$site"
   sed -i 's/proxy_read_timeout 3600s;/proxy_read_timeout 60s;/' "$site"
   refuse "$mode: changed timeout"
   cp "$root/native" "$site"
   sed -i '/server_name /a\    proxy_set_header X-Custom keep;' "$site"
   refuse "$mode: server custom header"
   cp "$root/native" "$site"
   printf '\nmap $host $custom { default keep; }\n' >> "$site"
   refuse "$mode: top-level map"
   if [[ "$mode" == *streaming ]]; then
     cp "$root/native" "$site"
     sed -i '/client_max_body_size 64m;/d' "$site"
     conf_safe_for_template_rebuild "$site"
     modify_conf "${site##*/}" <<< $'\n\n\n\n' > "$root/menu" 2>&1
     grep -q 'client_max_body_size 64m;' "$site"
     sed -i 's/client_max_body_size 64m;/client_max_body_size 128m;/' "$site"
     refuse "$mode: custom body cap"
   fi
   if [[ "$mode" == emby_* ]]; then
     cp "$root/native" "$site"
     sed -i 's@rewrite \^/s1(/\.\*)\$ \$1 break;@rewrite ^/s1(/.*)$ /custom break;@' "$site"
     refuse "$mode: changed stream rewrite"
   fi
   echo "PASS $(basename "$entry"): $mode native/TLS and custom refusal cases"
 done
 rm -f "$CONF_DIR"/*.conf
 build_proxy_conf example.com 18080 3000 "$site" streaming
 nx_access_set_policy "$site" strict
 nx_access_set_default "$site" '0.0.0.0:18080'
 nx_home_set "$site" /management.html
 conf_safe_for_template_rebuild "$site"
 modify_conf "${site##*/}" <<< $'\n\n3001\n' > "$root/menu" 2>&1
 [[ "$(nx_home_status "$site")" == /management.html ]]
 grep -q 'proxy_pass http://127.0.0.1:3001;' "$site"
 cp "$site" "$root/managed"
 sed -i '/# nx-access-begin/a\    deny all;' "$site"
 refuse 'custom code hidden inside access markers'
 cp "$root/managed" "$site"
 sed -i '/# nx-home-map-begin/a\    set $custom keep;' "$site"
 refuse 'custom code hidden inside homepage markers'
 cp "$root/managed" "$site"
 enable_https_for_conf_file example.com "$site" 18443 > "$root/menu" 2>&1
 conf_safe_for_template_rebuild "$site"
 modify_conf "${site##*/}" <<< $'\n\n3002\n' > "$root/menu" 2>&1
 # Re-saving an HTTPS site keeps its historical source filename.
 site="$CONF_DIR/example.com-18080.conf"
 grep -q 'proxy_pass http://127.0.0.1:3002;' "$site"
 # Custom certificate path/protocol are preserved by the TLS rebuild helper.
 mkdir -p "$root/custom cert"
 cp "$SSL_DIR/example.com/"*.pem "$root/custom cert/"
 sed -i "s@${SSL_DIR}/example.com/fullchain.pem@\"$root/custom cert/fullchain.pem\"@;s@${SSL_DIR}/example.com/privkey.pem@\"$root/custom cert/privkey.pem\"@;s@ssl_protocols TLSv1.2 TLSv1.3;@ssl_protocols TLSv1.2;@" "$site"
 conf_safe_for_template_rebuild "$site"
 modify_conf "${site##*/}" <<< $'\n\n3003\n' > "$root/menu" 2>&1
 python3 - "$site" "$root/custom cert/fullchain.pem" <<'PYVERIFY'
import re,sys
assert re.search(r'ssl_certificate\s+"' + re.escape(sys.argv[2]) + r'";', open(sys.argv[1]).read())
PYVERIFY
 grep -q 'ssl_protocols TLSv1.2;' "$site"
 # Multi-alias custom sites remain supported by preservative HTTPS toggles;
 # parameter rebuild refuses because its single-domain renderer drops aliases.
 nx_access_set_policy "$site" open
 nx_access_set_default "$site" ''
 nx_home_set "$site" ''
 sed -i 's/server_name example.com;/server_name example.com alias.example.com;/' "$site"
 refuse 'template rebuild would drop alias'
 disable_https_for_conf_file example.com "$site" > "$root/menu" 2>&1
 enable_https_for_conf_file example.com "$site" 18443 > "$root/menu" 2>&1
 grep -q 'server_name example.com alias.example.com;' "$site"
 echo "PASS $(basename "$entry"): native modes/TLS/legacy cap; custom values/scope/markers refused without write/reload; strict/home/certificates preserved"
 )
done
