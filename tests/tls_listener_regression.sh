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
 ipv6_available() { return 1; }
 for address in 18443 0.0.0.0:18443 127.0.0.1:18443 '[::]:18443' '"[::1]:18443"' localhost:18443; do
  printf 'server { listen %s ssl; server_name old.example; }\n' "$address" > "$CONF_DIR/old.conf"
  port_has_ssl_listener 18443
  if port_has_ssl_listener 18444; then exit 1; fi
 done
 printf '# listen 18443 ssl;\nserver { listen 18443; server_name old.example; add_header X-Test "listen 18443 ssl;"; }\n' > "$CONF_DIR/old.conf"
 if port_has_ssl_listener 18443; then exit 1; fi
 printf 'server { listen 18443 ssl; }\n' > "$CONF_DIR/disabled.conf.bak"
 if port_has_ssl_listener 18443; then exit 1; fi
 rm "$CONF_DIR/disabled.conf.bak"
 # Invoke actual menu entry and actual listener discovery, rather than a mock
 # returning true for every socket. Only service effects are simulated.
 require_nginx_installed() { :; }
 is_port_used_os() { return 0; }
 confirm() { return 0; }
 select_external_mode() { echo streaming; }
 mkdir -p "$SSL_DIR/new.example"
 openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=new.example \
  -keyout "$SSL_DIR/new.example/privkey.pem" -out "$SSL_DIR/new.example/fullchain.pem" >/dev/null 2>&1
 reload_nginx_safe() {
  echo reload >> "$root/reloads"
  grep -q 'listen 18443 ssl' "$CONF_DIR/new.example-18443.conf"
  grep -q 'client_max_body_size 64m;' "$CONF_DIR/new.example-18443.conf"
 }
 for action in add_reverse_proxy add_external_url_proxy; do
  rm -f "$CONF_DIR"/* "$root/reloads"
  printf 'server { listen 0.0.0.0:18443 ssl; server_name old.example; ssl_certificate %s/new.example/fullchain.pem; ssl_certificate_key %s/new.example/privkey.pem; }\n' "$SSL_DIR" "$SSL_DIR" > "$CONF_DIR/old.conf"
  backend=3000; [[ "$action" != add_external_url_proxy ]] || backend=http://127.0.0.1:3000
  "$action" <<< $'new.example\n18443\n'"$backend" > "$root/out" 2>&1
  [[ $(wc -l < "$root/reloads") == 1 ]]
  rm -f "$CONF_DIR/new.example-18443.conf" "$root/reloads"
  printf 'server { listen broken ssl; server_name old.example; }\n' > "$CONF_DIR/old.conf"
  if "$action" <<< $'new.example\n18443\n'"$backend" > "$root/out" 2>&1; then exit 1; fi
  grep -q '无法解析现有 TLS 监听' "$root/out"
  [[ ! -e "$CONF_DIR/new.example-18443.conf" && ! -e "$root/reloads" ]]
 done
 rm -f "$CONF_DIR"/*
 )
done
echo 'PASS: source/bundle TLS IPv4/IPv6/quoted listeners, comments/strings/disabled exclusion, actual menu final-TLS publication and parse failure'
