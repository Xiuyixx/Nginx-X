#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source ./nx.sh
bin="${NGINX_TEST_BIN:-$(command -v nginx)}"
T="$(mktemp -d)"
cleanup() {
  if [[ -s "$T/pid" ]]; then "$bin" -p "$T/" -c "$T/nginx.conf" -s quit >/dev/null 2>&1 || true; fi
  rm -rf "$T"
}
trap cleanup EXIT
read -r port tlsport < <(python3 - <<'PY'
import socket
sockets=[socket.socket(),socket.socket()]
for s in sockets:s.bind(('127.0.0.1',0))
print(*(s.getsockname()[1] for s in sockets))
PY
)
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=diag.example -addext subjectAltName=DNS:diag.example -keyout "$T/key" -out "$T/cert" >/dev/null 2>&1
cat > "$T/nginx.conf" <<EOF
pid $T/pid;
error_log $T/error;
events {}
http {
 access_log off;
 client_body_temp_path $T/body;
 proxy_temp_path $T/proxy;
 fastcgi_temp_path $T/fastcgi;
 uwsgi_temp_path $T/uwsgi;
 scgi_temp_path $T/scgi;
 server { listen 127.0.0.1:$port; server_name diag.example;
  location / { return 200 "\$host"; }
 }
 server { listen 127.0.0.1:$tlsport ssl; server_name diag.example;
  ssl_certificate $T/cert; ssl_certificate_key $T/key;
  location / { return 200 "\$ssl_server_name"; }
 }
}
EOF
"$bin" -p "$T/" -c "$T/nginx.conf"
result="$(health_probe_url "http://diag.example:$port" "diag.example:$port:127.0.0.1")"
[[ "$result" == 200\|*\|0\|0 ]]
# Self signed certificate must fail; trusting the fixture cert must pass.
result="$(health_probe_url "https://diag.example:$tlsport" "diag.example:$tlsport:127.0.0.1")"
IFS='|' read -r code _ _ verify rc <<< "$result"
if health_probe_label "$code" "$verify" "$rc" >/dev/null; then exit 1; fi
result="$(CURL_CA_BUNDLE="$T/cert" health_probe_url "https://diag.example:$tlsport" "diag.example:$tlsport:127.0.0.1")"
[[ "$result" == 200\|*\|0\|0 ]]
[[ "$(curl --noproxy '*' --cacert "$T/cert" -fsS --resolve "diag.example:$tlsport:127.0.0.1" "https://diag.example:$tlsport")" == diag.example ]]
echo 'diagnostics real nginx: OK'
