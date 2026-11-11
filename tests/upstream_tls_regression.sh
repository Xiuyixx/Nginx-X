#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2317,SC2034
set -euo pipefail
source "$(dirname "$0")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
root="$NX_TEST_ENV_ROOT"
bash tools/build-bundle.sh "$root/bundle"
mkdir -p "$SSL_DIR/example.com"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com \
 -keyout "$SSL_DIR/example.com/privkey.pem" -out "$SSL_DIR/example.com/fullchain.pem" >/dev/null 2>&1
ca="$SSL_DIR/example.com/fullchain.pem"
for entry in "$PWD/nx.sh" "$root/bundle"; do
 (
 source "$entry"
 SUDO=''
 ipv6_available() { return 1; }
 nginx_http2_syntax() { echo listen; }
 reload_nginx_safe() { echo reload >> "$root/reloads"; [[ ${FAIL_RELOAD:-0} != 1 ]]; }
 require_nginx_installed() { :; }
 is_port_used_os() { return 1; }
 confirm() { return 1; }
 site="$CONF_DIR/example.com-18080.conf"
 for mode in normal streaming media emby_http emby_https emby_lily; do
   build_external_proxy_conf example.com 18080 https://localhost:9443/ "$mode" "$site" 0 \
     https://localhost:9444/ '' '' 'https://localhost:9444/|http://localhost:9445/|https://localhost:9446/'
   [[ "$(conf_meta_get "$site" upstream_tls_verify)" == on ]]
   [[ "$(conf_meta_get "$site" upstream_ca_file)" == "$(nx_system_ca_file)" ]]
   count=1; [[ "$mode" != emby_* ]] || count=3
   [[ "$(grep -c 'proxy_ssl_verify on;' "$site")" == "$count" ]]
   conf_safe_for_template_rebuild "$site"
   # Older templates with no upstream policy cannot silently keep verification
   # disabled on resave; refuse without modifying them or calling reload.
   cp "$site" "$root/native"
   sed -i '/proxy_ssl_verify /d; /proxy_ssl_verify_depth /d; /proxy_ssl_trusted_certificate /d; /^# upstream_tls_verify=/d; /^# upstream_ca_file=/d' "$site"
   cp "$site" "$root/legacy"
   if modify_conf "${site##*/}" <<< $'\n\n\n\n' > "$root/refusal" 2>&1; then exit 1; fi
   cmp "$site" "$root/legacy"
   grep -q '已阻止' "$root/refusal"
   cp "$root/native" "$site"
 done
 # EOF at the new policy prompt cancels without publishing, including an
 # existing explicit-off site; it is not equivalent to a blank response.
 rm -f "$CONF_DIR"/*.conf "$CONF_DIR"/*.bak
 if add_external_url_proxy <<< $'example.com\n18080\nhttps://localhost:9443/\n1' > "$root/eof" 2>&1; then exit 1; else [[ $? == 10 ]]; fi
 [[ ! -e "$site" ]]
 build_external_proxy_conf example.com 18080 https://localhost:9443/ normal "$site" 0 '' '' '' '' off '' 2>/dev/null
 cp "$site" "$root/before"
 if modify_conf "${site##*/}" <<< $'\n\n\n' > "$root/eof" 2>&1; then exit 1; else [[ $? == 10 ]]; fi
 cmp "$site" "$root/before"
 # Missing/bad/injected trust anchors and invalid policies fail before output.
 printf sentinel > "$root/rejected"
 printf 'not PEM\n' > "$root/not-pem"
 for bad in "$root/missing" "$root/not-pem" "$root/ca;evil" "$root/ca\$variable"; do
   if build_external_proxy_conf example.com 18080 https://localhost normal "$root/rejected" 0 '' '' '' '' on "$bad" 2>/dev/null; then exit 1; fi
   [[ "$(cat "$root/rejected")" == sentinel ]]
 done
 if NX_SYSTEM_CA_FILE="$root/missing" build_external_proxy_conf example.com 18080 https://localhost normal "$root/rejected" 2>/dev/null; then exit 1; fi
 if build_external_proxy_conf example.com 18080 https://localhost normal "$root/rejected" 0 '' '' '' '' invalid 2>/dev/null; then exit 1; fi
 [[ "$(cat "$root/rejected")" == sentinel ]]
 # Private trust and explicit off survive the real modify/HTTPS/disabled paths.
 for verify in on off; do
   rm -f "$CONF_DIR"/*.conf "$CONF_DIR"/*.bak
   build_external_proxy_conf example.com 18080 https://localhost:9443/ emby_lily "$site" 0 \
     https://localhost:9444/ '' '' '' "$verify" "$ca" 2> "$root/warning"
   if [[ "$verify" == off ]]; then grep -q 'proxy_ssl_verify off' "$root/warning"; fi
   conf_safe_for_template_rebuild "$site"
   modify_conf "${site##*/}" <<< $'\n\n\n\n\n\n\n\n' > "$root/menu" 2>&1
   [[ "$(conf_meta_get "$site" upstream_tls_verify)" == "$verify" ]]
   [[ "$(conf_meta_get "$site" upstream_ca_file)" == "$ca" ]]
   enable_https_for_conf_file example.com "$site" 18443 > "$root/menu" 2>&1
   grep -F "'https://example.com:18443/s1'" "$site" >/dev/null
   [[ "$(grep -c "proxy_ssl_verify $verify;" "$site")" == 2 ]]
   conf_safe_for_template_rebuild "$site"
   disable_https_for_conf_file example.com "$site" > "$root/menu" 2>&1
   grep -F "'http://example.com:18080/s1'" "$site" >/dev/null
   [[ "$(conf_meta_get "$site" upstream_tls_verify)" == "$verify" ]]
   [[ "$(conf_meta_get "$site" upstream_ca_file)" == "$ca" ]]
   cp "$site" "$root/before"
   if FAIL_RELOAD=1 modify_conf "${site##*/}" <<< $'\n\n\n\n\n\n\n\n' > "$root/menu" 2>&1; then exit 1; fi
   cmp "$site" "$root/before"
   disable_conf "${site##*/}" > "$root/menu" 2>&1
   modify_conf "${site##*/}.bak" <<< $'\n\n\n\n\n\n\n\n' > "$root/menu" 2>&1
   [[ "$(conf_meta_get "$site.bak" upstream_tls_verify)" == "$verify" ]]
   [[ "$(conf_meta_get "$site.bak" upstream_ca_file)" == "$ca" ]]
 done
 # Real creation wizard has an explicit private-CA/off entry; blank is secure.
 for choice in '' "$ca" off; do
   rm -f "$CONF_DIR"/*.conf "$CONF_DIR"/*.bak
   add_external_url_proxy <<< $'example.com\n18080\nhttps://localhost:9443/\n1\n'"$choice" > "$root/menu" 2>&1
   expected=on; [[ "$choice" != off ]] || expected=off
   [[ "$(conf_meta_get "$site" upstream_tls_verify)" == "$expected" ]]
   if [[ "$choice" == "$ca" ]]; then [[ "$(conf_meta_get "$site" upstream_ca_file)" == "$ca" ]]; fi
   if [[ "$choice" == off ]]; then grep -q 'proxy_ssl_verify off' "$root/menu"; fi
 done
 echo "PASS upstream TLS policy/lifecycle: ${entry##*/}"
 )
done
