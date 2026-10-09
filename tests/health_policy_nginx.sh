#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317,SC2016
set -euo pipefail
source "$(dirname "$0")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
source ./nx.sh
bin="${NGINX_TEST_BIN:-$(command -v nginx || true)}"
[[ -x "$bin" ]] || { echo 'SKIP: real nginx unavailable'; exit 0; }
T="$NX_TEST_ENV_ROOT"; SUDO=''
cleanup() {
 if [[ -s "$T/pid" ]]; then "$bin" -p "$T/" -c "$NGINX_MAIN_CONF" -s quit >/dev/null 2>&1 || true; fi
 nx_test_wait_pidfile "$T/pid"
 nx_test_cleanup
}
trap cleanup EXIT
read -r port tlsport < <(python3 - <<'PY'
import socket
ss=[socket.socket(),socket.socket()]
for s in ss:s.bind(('127.0.0.1',0))
print(*(s.getsockname()[1] for s in ss))
PY
)
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=diag.example -keyout "$T/key" -out "$T/cert" >/dev/null 2>&1
printf 'types { text/html html; }\n' > "$T/mime.types"
printf 'map $http_upgrade $connection_upgrade { default upgrade; "" close; }\n'  > "$CONF_DIR/map.conf"
cat > "$NGINX_MAIN_CONF" <<CONF
pid $T/pid; error_log $T/error; events {} http { access_log off;
client_body_temp_path $T/body; proxy_temp_path $T/proxy; fastcgi_temp_path $T/fastcgi;
uwsgi_temp_path $T/uwsgi; scgi_temp_path $T/scgi;
include $T/mime.types;
include $CONF_DIR/*.conf;
}
CONF
site="$CONF_DIR/site.conf"
for policy in strict open; do
 for transport in http tls; do
  ssl=''; cert=''; p="$port"
  if [[ "$transport" == tls ]]; then ssl=ssl; p="$tlsport"; cert="ssl_certificate $T/cert; ssl_certificate_key $T/key;"; fi
  cat > "$T/input" <<CONF
server { listen 127.0.0.1:$p $ssl; listen [::1]:$p $ssl;
server_name diag.example; $cert
location / { return 404; }
}
# access_policy=$policy
CONF
  strict=0; [[ "$policy" != strict ]] || strict=1
  nx_access_parse "$T/input" transform "$strict" "127.0.0.1:$p,[::1]:$p" > "$site"
  "$bin" -t -p "$T/" -c "$NGINX_MAIN_CONF" > "$T/validation" 2>&1
  "$bin" -p "$T/" -c "$NGINX_MAIN_CONF"
  health_socket_policy "$site" > "$T/result" || { cat "$T/result"; exit 1; }
  grep -q '合法Host: 404 | 策略符合' "$T/result"
  grep -q '未验证\|策略不符' "$T/result" && exit 1
  [[ $(grep -c '本机策略' "$T/result") == "$([[ "$transport" == tls ]] && echo 12 || echo 8)" ]]
  # A stale/missing guard must be detected, not hidden by a healthy domain.
  if [[ "$policy" == open && "$transport" == http ]]; then
   sed -i 's/access_policy=open/access_policy=strict/' "$site"
   if health_socket_policy "$site" > "$T/bad"; then exit 1; fi
   grep -q '策略不符' "$T/bad"
  fi
  # Unknown custom include is reported unverified, never guessed safe.
  printf 'server { listen 127.0.0.1:19999; server_name other.example; }\n' > "$T/external"
  sed -i "/include.*mime.types/a include $T/external;" "$NGINX_MAIN_CONF"
  if health_socket_policy "$site" > "$T/unknown"; then exit 1; fi
  grep -q '未验证' "$T/unknown"
  sed -i '\|include.*/external;|d' "$NGINX_MAIN_CONF"
  "$bin" -p "$T/" -c "$NGINX_MAIN_CONF" -s quit >/dev/null 2>&1
  nx_test_wait_pidfile "$T/pid"
 done
done
echo 'PASS: real IPv4/v6 HTTP/TLS strict/open default multi-socket Host/SNI/no-Host; business 404 and unknown scope'
