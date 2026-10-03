#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
ROOT="${NX_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
T="$(mktemp -d)"
trap 'nx_test_cleanup; rm -rf "$T"' EXIT
export NX_CONF_DIR="$T/conf" STATE_DIR="$T/state" NGINX_MAIN_CONF="$T/nginx.conf"
mkdir -p "$NX_CONF_DIR" "$STATE_DIR"
# shellcheck disable=SC1091
source "$ROOT/nx.sh"
# shellcheck disable=SC2034
SUDO=''
SSL_DIR="$T/ssl"
mkdir -p "$SSL_DIR/example.com"
NGINX_TEST_BIN="${NGINX_TEST_BIN:-$(command -v nginx || true)}"
[[ -x "$NGINX_TEST_BIN" ]] || { echo 'Set NGINX_TEST_BIN to a real Nginx binary' >&2; exit 1; }
nginx_test_command=("$NGINX_TEST_BIN")
if [[ ${EUID:-0} -ne 0 ]] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  nginx_test_command=(sudo "$NGINX_TEST_BIN")
fi
cat > "$NGINX_MAIN_CONF" <<EOF
pid $T/pid;
error_log stderr;
events {}
http {
 access_log off;
 client_body_temp_path $T/body;
 proxy_temp_path $T/proxy;
 fastcgi_temp_path $T/fastcgi;
 uwsgi_temp_path $T/uwsgi;
 scgi_temp_path $T/scgi;
 map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
 include $CONF_DIR/*.conf;
}
EOF
reload_nginx_safe() {
  "${nginx_test_command[@]}" -t -p "$T" -c "$NGINX_MAIN_CONF" > "$T/nginx.log" 2>&1 || { cat "$T/nginx.log" >&2; return 1; }
}
nginx_supports_ssl_reject_handshake() { return 1; }
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com -addext subjectAltName=DNS:example.com,DNS:alias.example.com \
  -keyout "$SSL_DIR/example.com/privkey.pem" -out "$SSL_DIR/example.com/fullchain.pem" >/dev/null 2>&1
# Multiline quoted values deliberately contain exact metadata and guard markers.
cat > "$T/import" <<'SITE'
server {
 listen [0:0:0:0:0:0:0:1]:18080;
 server_name "example.com" 'alias.example.com';
 set $literal "begin
# access_policy=open
# access_default=[::1]:9999
    # nx-access-begin
quoted payload
    # nx-access-end
text default_server # nx-access-default
end";
 location / { return 200 $literal; }
}
SITE
check_literal() {
  python3 - "$T/import" "$1" <<'PY'
import sys
needle = open(sys.argv[1]).read().split('set $literal ', 1)[1].split(';', 1)[0]
assert 'set $literal ' + needle + ';' in open(sys.argv[2]).read(), 'multiline string was changed'
PY
}
case "${NX_PARSER_CASE:-all}" in
all|quoted)
  import_single_conf "$T/import" >/dev/null
  site="$CONF_DIR/example.com-18080.conf"
  check_literal "$site"
  nx_site_access_menu "$site" <<< 1 >/dev/null
  [[ "$(conf_meta_get "$site" access_policy)" == strict ]]
  check_literal "$site"
  nx_site_access_menu "$site" <<< 2 >/dev/null
  check_literal "$site"
  nx_site_access_menu "$site" <<< 1 >/dev/null
  nx_default_site_menu "$site" <<< 1 >/dev/null
  [[ "$(conf_meta_get "$site" access_default)" == '[::1]:18080' ]]
  check_literal "$site"
  enable_https_for_conf_file example.com "$site" 18443 >/dev/null
  [[ "$(conf_meta_get "$site" access_default)" == '[::1]:18443' ]]
  check_literal "$site"
  disable_https_for_conf_file example.com "$site" >/dev/null
  [[ "$(conf_meta_get "$site" access_default)" == '[::1]:18080' ]]
  check_literal "$site"
  # nx_write_conf preserves old policy while retaining candidate literal bytes.
  cp "$site" "$T/candidate"
  apply_conf_with_rollback "$T/candidate" "$site" "$site"
  check_literal "$site"
  # Simple quotes accepted; escape/concatenation must fail before publication.
  cp "$site" "$T/before"
  sed 's/"example.com"/"exam\\ple.com"/' "$site" > "$T/escaped"
  if apply_conf_with_rollback "$T/escaped" "$site" "$site" >/dev/null 2>&1; then exit 1; fi
  cmp "$site" "$T/before"
  echo 'PASS: real import -> strict/open/default menus -> HTTPS round trip; literal bytes and rollback'
  ;;
esac
# Independent cases allow proof against the old implementation for every bug.
case "${NX_PARSER_CASE:-all}" in
all|metadata)
  cp "$T/import" "$T/meta"
  nx_access_metadata "$T/meta" access_policy strict
  nx_access_metadata "$T/meta" access_default '[::1]:18080'
  check_literal "$T/meta"
  # Only real top-level standalone comments are replaced, including indentation.
  printf '  # access_policy=open\n' >> "$T/meta"
  nx_access_metadata "$T/meta" access_policy strict
  [[ "$(conf_meta_get "$T/meta" access_policy)" == strict ]]
  echo 'PASS: offset metadata replacement'
  ;;
esac
case "${NX_PARSER_CASE:-all}" in
all|ipv6)
  cat > "$T/ipv6" <<'SITE'
# access_default=[::1]:18080
server { listen [0:0:0:0:0:0:0:1]:18080; server_name example.com; return 200; }
SITE
  nx_https_transform enable "$T/ipv6" example.com "$SSL_DIR" 18443 > "$T/enabled"
  [[ "$(conf_meta_get "$T/enabled" access_default)" == '[::1]:18443' ]]
  nx_https_transform disable "$T/enabled" example.com "$SSL_DIR" '' > "$T/disabled"
  [[ "$(conf_meta_get "$T/disabled" access_default)" == '[::1]:18080' ]]
  echo 'PASS: expanded IPv6 default socket normalization'
  ;;
esac
case "${NX_PARSER_CASE:-all}" in
all|names)
  # Isolate quoted-name compatibility from literal-marker regression above.
  rm -f "$CONF_DIR"/*.conf
  printf 'server { listen 18081; server_name "example.com"; return 200; }\n' > "$T/names"
  import_single_conf "$T/names" >/dev/null
  nx_site_access_menu "$CONF_DIR/example.com-18081.conf" <<< 1 >/dev/null
  [[ "$(conf_meta_get "$CONF_DIR/example.com-18081.conf" access_policy)" == strict ]]
  echo 'PASS: quoted server_name import and strict menu compatibility'
  ;;
esac
