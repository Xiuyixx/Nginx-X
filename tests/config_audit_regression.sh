#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/nx.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
CONF_DIR="$T/conf"; SSL_DIR="$T/ssl"; DOMAIN_ONLY_STATE="$T/state"
SUDO=""
NGINX_MAIN_CONF="$T/nginx.conf"
mkdir -p "$CONF_DIR" "$SSL_DIR/example.com"
NGINX_TEST_BIN="${NGINX_TEST_BIN:-$(command -v nginx || true)}"
[[ -x "$NGINX_TEST_BIN" ]] || { echo 'Set NGINX_TEST_BIN to a real Nginx binary' >&2; exit 1; }
# HTTPS transforms also generate a port-80 challenge listener. Elevate only
# nginx -t; fixture writes must retain the unprivileged test user's ownership.
nginx_test_command=("$NGINX_TEST_BIN")
if [[ ${EUID:-0} -ne 0 ]] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  nginx_test_command=(sudo "$NGINX_TEST_BIN")
fi
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com -addext subjectAltName=DNS:example.com,DNS:external.example -keyout "$SSL_DIR/example.com/privkey.pem" -out "$SSL_DIR/example.com/fullchain.pem" >/dev/null 2>&1
cat > "$T/nginx.conf" <<NGINX
pid $T/pid;
error_log stderr;
events {}
http {
 access_log off;
 map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
 client_body_temp_path $T/body;
 proxy_temp_path $T/proxy;
 fastcgi_temp_path $T/fastcgi;
 uwsgi_temp_path $T/uwsgi;
 scgi_temp_path $T/scgi;
 include $CONF_DIR/*.conf;
}
NGINX
reload_nginx_safe() {
  printf 'apply\n' >> "$T/applies"
  "${nginx_test_command[@]}" -t -p "$T" -c "$T/nginx.conf" > "$T/nginx.log" 2>&1 || { cat "$T/nginx.log" >&2; return 1; }
  [[ ! -f "$T/fail" ]]
}
require_nginx_installed() { :; }
is_port_used_os() { return 1; }
ipv6_available() { return 1; }
confirm() { return 1; }
# Single-line/address-bound and alias dedup share one structural interpretation.
printf 'server { listen 127.0.0.1:18443 ssl; server_name example.com www.example.com; location / { proxy_pass http://127.0.0.1:3000; } }\n' > "$T/compact"
[[ "$(_extract_conf_meta "$T/compact")" == 'example.com|18443|http://127.0.0.1:3000|true|' ]]
[[ "$(conf_server_block_count "$T/compact")" == 1 ]]
nx_conf_query keys "$T/compact" | grep -qx 'www.example.com|127.0.0.1:18443'
# Duplicate add refuses before builder side effects, even for disabled edited sites.
cp "$T/compact" "$CONF_DIR/example.com-18443.conf.bak"
build_proxy_conf() { touch "$T/unexpected-build"; }
if add_reverse_proxy <<< $'example.com\n18443\n3001' >/dev/null 2>&1; then exit 1; fi
[[ ! -e "$T/unexpected-build" ]]
cmp "$T/compact" "$CONF_DIR/example.com-18443.conf.bak"
# shellcheck disable=SC1091
source "$ROOT/lib/templates.sh"
rm "$CONF_DIR/example.com-18443.conf.bak"
build_proxy_conf example.com 18080 3000 "$T/http"
nx_https_transform enable "$T/http" example.com "$SSL_DIR" 18443 > "$CONF_DIR/example.com-18443.conf"
nx_access_set_policy "$CONF_DIR/example.com-18443.conf" strict
nx_access_set_default "$CONF_DIR/example.com-18443.conf" '0.0.0.0:18443'
printf '' > "$T/applies"
modify_conf example.com-18443.conf <<< $'\n18444\n3001' >/dev/null
[[ "$(wc -l < "$T/applies")" == 1 ]]
conf_https_enabled "$CONF_DIR/example.com-18444.conf"
[[ "$(conf_meta_get "$CONF_DIR/example.com-18444.conf" https_original_listen_port)" == 18080 ]]
[[ "$(conf_meta_get "$CONF_DIR/example.com-18444.conf" access_default)" == '0.0.0.0:18444' ]]
grep -q 'proxy_pass http://127.0.0.1:3001;' "$CONF_DIR/example.com-18444.conf"
cp "$CONF_DIR/example.com-18444.conf" "$T/before"
if modify_conf example.com-18444.conf <<< $'missing.example\n\n3002' >/dev/null 2>&1; then exit 1; fi
cmp "$T/before" "$CONF_DIR/example.com-18444.conf"
touch "$T/fail"
if modify_conf example.com-18444.conf <<< $'\n\n3002' >/dev/null 2>&1; then exit 1; fi
cmp "$T/before" "$CONF_DIR/example.com-18444.conf"
rm "$T/fail"
# External disabled HTTPS also publishes only its final disabled configuration.
build_external_proxy_conf external.example 18090 http://127.0.0.1:3000 normal "$T/ext" 0
mkdir -p "$SSL_DIR/external.example"
cp "$SSL_DIR/example.com/"*.pem "$SSL_DIR/external.example/"
nx_https_transform enable "$T/ext" external.example "$SSL_DIR" 18445 > "$CONF_DIR/external.example-18445.conf.bak"
select_external_mode() { echo normal; }
printf '' > "$T/applies"
modify_conf external.example-18445.conf.bak <<< $'\n\nhttp://127.0.0.1:3003' >/dev/null
[[ "$(wc -l < "$T/applies")" == 1 ]]
[[ ! -e "$CONF_DIR/external.example-18445.conf" ]]
conf_https_enabled "$CONF_DIR/external.example-18445.conf.bak"
[[ "$(conf_meta_get "$CONF_DIR/external.example-18445.conf.bak" https_original_listen_port)" == 18090 ]]
grep -q 'proxy_pass http://127.0.0.1:3003;' "$CONF_DIR/external.example-18445.conf.bak"
# Health chooses actual TLS port over old listen_port metadata; disabled is never probed.
nx_access_metadata "$CONF_DIR/example.com-18444.conf" listen_port 80
health_probe_url() { printf '%s\n' "$1" >> "$T/probes"; echo '200|127.0.0.1||0'; }
getent() { :; }; timeout() { return 1; }
health_check_conf_file "$CONF_DIR/example.com-18444.conf" >/dev/null
grep -qx 'https://example.com:18444' "$T/probes"
mv "$CONF_DIR/example.com-18444.conf" "$CONF_DIR/example.com-18444.conf.bak"
rm "$T/probes"
health_check_conf_file "$CONF_DIR/example.com-18444.conf.bak" >/dev/null
[[ ! -e "$T/probes" ]]
# Unrelated opaque include does not block all-open operations.
rm -f "$CONF_DIR/00-nx-domain-only.conf"
printf 'add_header X-Audit yes;\n' > "$T/headers"
printf 'server { listen 18088; server_name other.example; include %s/headers; }\n' "$T" > "$CONF_DIR/unmanaged.conf"
build_proxy_conf open.example 18089 3000 "$CONF_DIR/open.example-18089.conf"
disable_conf open.example-18089.conf >/dev/null
# External paths are refused for setters and old paths before mutation.
cp "$T/http" "$T/external"
if nx_access_set_policy "$T/external" strict >/dev/null 2>&1; then exit 1; fi
if apply_conf_with_rollback "$T/http" "$CONF_DIR/new.conf" "$T/external" >/dev/null 2>&1; then exit 1; fi
cmp "$T/http" "$T/external"
# Expanded/compressed IPv6 sockets share one identity.
printf 'server { listen [::1]:18980; server_name v6.example; }\n' > "$T/a"
printf 'server { listen [0:0:0:0:0:0:0:1]:18980; server_name v6.example; }\n' > "$T/b"
[[ "$(nx_access_parse "$T/a")" == "$(nx_access_parse "$T/b")" ]]
echo 'ok: config audit real menu callers, endpoint parsing, TLS atomicity, rollback and real nginx validation'
rm "$CONF_DIR/unmanaged.conf"
# Plain default selection follows exact application sockets during a port move.
build_proxy_conf plain.example 18100 3000 "$CONF_DIR/plain.example-18100.conf"
nx_access_set_default "$CONF_DIR/plain.example-18100.conf" '0.0.0.0:18100'
modify_conf plain.example-18100.conf <<< $'\n18101\n3001' >/dev/null
[[ "$(conf_meta_get "$CONF_DIR/plain.example-18101.conf" access_default)" == '0.0.0.0:18101' ]]
# A TERM delivered inside the mutation restores all snapshotted files.
cp "$CONF_DIR/plain.example-18101.conf" "$T/plain-before"
interrupt_mutation() { printf 'corrupted\n' > "$CONF_DIR/plain.example-18101.conf"; kill -TERM "$BASHPID"; }
if nx_transaction interrupt_mutation >/dev/null 2>&1; then exit 1; fi
cmp "$T/plain-before" "$CONF_DIR/plain.example-18101.conf"
echo 'ok: plain default remapping and signal rollback'
# Two nx processes serialize the mutation boundary (no interleaved snapshots).
serialized_mutation() { printf '%s-start\n' "$1" >> "$T/serial"; sleep 0.1; printf '%s-end\n' "$1" >> "$T/serial"; }
nx_transaction serialized_mutation first >/dev/null &
pid1=$!
nx_transaction serialized_mutation second >/dev/null &
pid2=$!
wait "$pid1"
wait "$pid2"
python3 - "$T/serial" <<'PY'
import sys
lines=open(sys.argv[1]).read().splitlines()
assert lines in (["first-start","first-end","second-start","second-end"], ["second-start","second-end","first-start","first-end"]), lines
PY
echo 'ok: concurrent transaction serialization'
# Read-only queries retain hostname listeners and accept quoted token values.
for listener in localhost:18080 '"18080"'; do
  printf '# backend_port=3000\nserver { listen %s; server_name example.com; location / { proxy_pass "http://127.0.0.1:3000"; } }\n' "$listener" > "$T/inspect"
  [[ "$(conf_meta_get "$T/inspect" backend_port)" == 3000 ]]
  [[ "$(conf_server_block_count "$T/inspect")" == 1 ]]
  [[ "$(extract_proxy_pass "$T/inspect")" == http://127.0.0.1:3000 ]]
  [[ "$(nx_conf_query summary "$T/inspect")" == 'example.com|18080|http://127.0.0.1:3000|false|' ]]
  printf 'pid %s/inspect.pid; error_log stderr; events {} http { access_log off; client_body_temp_path body; proxy_temp_path proxy; fastcgi_temp_path fastcgi; uwsgi_temp_path uwsgi; scgi_temp_path scgi; include %s/inspect; }\n' "$T" "$T" > "$T/inspect-main"
  "${nginx_test_command[@]}" -t -p "$T" -c "$T/inspect-main" > "$T/inspect.log" 2>&1 || { cat "$T/inspect.log"; exit 1; }
  nx_conf_query keys "$T/inspect" > "$T/keys"
  if [[ "$listener" == localhost:* ]]; then
    grep -qx 'example.com|localhost:18080' "$T/keys"
    if nx_access_parse "$T/inspect" >/dev/null 2>&1; then exit 1; fi
    if nx_conf_query defaults "$T/inspect" localhost:18080 '' '' >/dev/null 2>&1; then exit 1; fi
  else
    grep -qx 'example.com|0.0.0.0:18080' "$T/keys"
  fi
done
# Same-domain TLS modifications validate and preserve the actual custom cert,
# including compact directives and quoted paths, without managed certificates.
mkdir -p "$T/custom cert"
cp "$SSL_DIR/example.com/"*.pem "$T/custom cert/"
rm "$SSL_DIR/example.com/"*.pem
printf 'server { listen 18443 ssl; server_name example.com; ssl_certificate "%s/custom cert/fullchain.pem"; ssl_certificate_key "%s/custom cert/privkey.pem"; ssl_protocols TLSv1.2; location / { proxy_pass http://127.0.0.1:3000; } }\n' "$T" "$T" > "$T/custom-old"
build_proxy_conf example.com 18444 3001 "$T/custom-new"
nx_preserve_modify_tls "$T/custom-old" "$T/custom-new" example.com 18444
grep -Fq "ssl_certificate \"$T/custom cert/fullchain.pem\";" "$T/custom-new"
grep -Fq "ssl_certificate_key \"$T/custom cert/privkey.pem\";" "$T/custom-new"
grep -Fq 'ssl_protocols TLSv1.2;' "$T/custom-new"
# shellcheck disable=SC2016
printf 'pid %s/custom.pid; error_log stderr; events {} http { access_log off; client_body_temp_path body; proxy_temp_path proxy; fastcgi_temp_path fastcgi; uwsgi_temp_path uwsgi; scgi_temp_path scgi; map $http_upgrade $connection_upgrade { default upgrade; } include %s/custom-new; }\n' "$T" "$T" > "$T/custom-main"
"${nginx_test_command[@]}" -t -p "$T" -c "$T/custom-main" > "$T/custom.log" 2>&1 || { cat "$T/custom.log"; exit 1; }
build_proxy_conf example.com 18444 3001 "$T/custom-uncovered"
sed -i 's/server_name example.com;/server_name example.com uncovered.example;/' "$T/custom-uncovered"
cp "$T/custom-uncovered" "$T/custom-before"
if nx_preserve_modify_tls "$T/custom-old" "$T/custom-uncovered" example.com 18444 2> "$T/refusal"; then exit 1; fi
grep -q 'does not cover server_name uncovered.example' "$T/refusal"
cmp "$T/custom-before" "$T/custom-uncovered"
echo 'ok: hostname/quoted inspection and compact custom TLS preservation with alias validation'
