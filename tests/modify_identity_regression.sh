#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "$0")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
root="$NX_TEST_ENV_ROOT"
bash tools/build-bundle.sh "$root/bundle"
for entry in "$PWD/nx.sh" "$root/bundle"; do
 (
 source "$entry"
 SUDO=''
 require_nginx_installed() { :; }
 reload_nginx_safe() { echo reload >> "$root/reloads"; [[ ${FAIL_RELOAD:-0} != 1 ]]; }
 is_port_used_os() { return 1; }
 ipv6_available() { return 1; }
 nginx_supports_http2_on() { return 1; }
 mkdir -p "$SSL_DIR/example.com"
 openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com \
  -addext subjectAltName=DNS:example.com -keyout "$SSL_DIR/example.com/privkey.pem" \
  -out "$SSL_DIR/example.com/fullchain.pem" >/dev/null 2>&1
 for kind in internal external; do
  for disabled in 0 1; do
   rm -f "$CONF_DIR"/* "$CONF_DIR"/.[!.]* "$root/reloads"
   site="$CONF_DIR/example.com-18080.conf"
   if [[ "$kind" == internal ]]; then
    build_proxy_conf example.com 18080 3000 "$site" streaming
   else
    build_external_proxy_conf example.com 18080 http://127.0.0.1:3000 streaming "$site"
   fi
   chmod 640 "$site"
   enable_https_for_conf_file example.com "$site" 18443 > "$root/out" 2>&1
   nx_home_set "$site" /management.html > "$root/out" 2>&1
   nx_access_set_policy "$site" strict > "$root/out" 2>&1
   if (( disabled )); then disable_conf "${site##*/}" > "$root/out" 2>&1; site="$site.bak"; fi
   sed -i '/client_max_body_size 64m;/d' "$site"
   cp -a "$site" "$root/before"
   : > "$root/reloads"
   # All defaults: retain the source identity even though its historic filename
   # has the pre-HTTPS port. Existing callers/protection refer to this path.
   modify_conf "${site##*/}" <<< $'\n\n\n' > "$root/out" 2>&1
   [[ -f "$site" && $(stat -c %a "$site") == 640 ]]
   [[ ! -e "$CONF_DIR/example.com-18443.conf" && ! -e "$CONF_DIR/example.com-18443.conf.bak" ]]
   grep -q 'client_max_body_size 64m;' "$site"
   [[ "$(conf_meta_get "$site" listen_port)" == 18443 ]]
   [[ "$(conf_meta_get "$site" https_original_listen_port)" == 18080 ]]
   [[ "$(nx_home_status "$site")" == /management.html ]]
   [[ "$(nx_access_site_policy "$site")" == strict ]]
   grep -q 'listen 18443 ssl' "$site"
   [[ $(wc -l < "$root/reloads") == 1 ]]
   cp -a "$site" "$root/before"
   # Same identity, real backend change still uses the same file and rollback.
   if [[ "$kind" == internal ]]; then input=$'\n\n3001\n'; else input=$'\n\nhttp://127.0.0.1:3001\n'; fi
   if FAIL_RELOAD=1 modify_conf "${site##*/}" <<< "$input" > "$root/out" 2>&1; then exit 1; fi
   cmp "$site" "$root/before"
   [[ $(stat -c %a "$site") == 640 ]]
   modify_conf "${site##*/}" <<< "$input" > "$root/out" 2>&1
   [[ "$(extract_proxy_pass "$site")" == http://127.0.0.1:3001 ]]
   # An explicit port change must still rename and preserve enabled/disabled.
   modify_conf "${site##*/}" <<< $'\n18444\n\n' > "$root/out" 2>&1
   new="$CONF_DIR/example.com-18444.conf"
   (( disabled == 0 )) || new="$new.bak"
   [[ -f "$new" && ! -e "$site" && $(stat -c %a "$new") == 640 ]]
   grep -q 'listen 18444 ssl' "$new"
  done
 done
 )
done
echo 'PASS: source/bundle internal/external HTTPS resave keeps historic filename, metadata/policy/home/permissions and rollback; explicit port changes rename'
