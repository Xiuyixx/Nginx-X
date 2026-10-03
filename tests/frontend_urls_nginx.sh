#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/../nx.sh"
root="$(mktemp -d)"
nginx_bin="${NGINX_TEST_BIN:-/root/.openclaw/workspace/tmp/nginx-x-test-runtime/extracted/usr/sbin/nginx}"
[[ -x "$nginx_bin" ]] || nginx_bin="$(command -v nginx)"
cleanup() {
 [[ ! -f "$root/nginx.pid" ]] || kill "$(cat "$root/nginx.pid")" 2>/dev/null || true
 [[ -z "${backend_pid:-}" ]] || kill "$backend_pid" 2>/dev/null || true
 nx_test_wait_pidfile "$root/nginx.pid"
 [[ -z "${backend_pid:-}" ]] || wait "$backend_pid" 2>/dev/null || true
 rm -rf "$root"
}
trap 'cleanup; nx_test_cleanup' EXIT
# shellcheck disable=SC2034
SUDO=""
SSL_DIR="$root/ssl"
mkdir -p "$SSL_DIR/example.com"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com \
 -keyout "$SSL_DIR/example.com/privkey.pem" -out "$SSL_DIR/example.com/fullchain.pem" >/dev/null 2>&1
python3 - "$root/backend.port" <<'PY' &
import http.server,sys
class Handler(http.server.BaseHTTPRequestHandler):
 def do_GET(self):
  self.send_response(200)
  self.send_header('Content-Type','application/json')
  self.send_header('Location','http://127.0.0.1:'+str(self.server.server_port)+'/stream')
  self.end_headers()
  self.wfile.write(('"http://127.0.0.1:'+str(self.server.server_port)+'/stream"').encode())
 def log_message(self,*args): pass
server=http.server.HTTPServer(('127.0.0.1',0),Handler)
open(sys.argv[1],'w').write(str(server.server_port))
server.serve_forever()
PY
backend_pid=$!
for ((i=0;i<100;i++)); do [[ -s "$root/backend.port" ]] && break; sleep .02; done
backend="$(cat "$root/backend.port")"
port="$(python3 - <<'PY'
import socket
s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()
PY
)"
ensure_websocket_map() { :; }
ipv6_available() { return 1; }
build_external_proxy_conf example.com "$port" "http://127.0.0.1:$backend" emby_lily "$root/plain" 0 "http://127.0.0.1:$backend" "http://127.0.0.1:$backend"
# A custom directive is outside the exact managed destination pattern.
sed -i '/proxy_http_version 1.1;/a\        proxy_redirect http://custom.invalid https://keep.invalid;' "$root/plain"
nx_https_transform enable "$root/plain" example.com "$SSL_DIR" "$port" > "$root/tls"
nx_https_transform disable "$root/tls" example.com "$SSL_DIR" '' > "$root/restored"
for stage in plain tls restored; do
 cp "$root/$stage" "$root/site.conf"
 # No privileged listener in this runtime test: redirect routing has separate tests.
 if [[ "$stage" == tls ]]; then
   python3 - "$root/site.conf" <<'PY'
import sys
p=sys.argv[1];s=open(p).read();a=s.index('server {');b=s.index('server {',a+8);s=s[:a]+s[b:];open(p,'w').write(s)
PY
 fi
 cat > "$root/nginx.conf" <<CONF
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
 include $root/site.conf;
}
CONF
 "$nginx_bin" -t -p "$root" -c "$root/nginx.conf"
 "$nginx_bin" -p "$root" -c "$root/nginx.conf"
 scheme=http; [[ "$stage" != tls ]] || scheme=https
 curl --noproxy '*' -ksS --retry 4 --retry-connrefused --retry-delay 0 -D "$root/headers" "$scheme://127.0.0.1:$port/" > "$root/body.out"
 grep -Fiq "Location: $scheme://example.com:$port/s1//stream" "$root/headers"
 grep -Fq "$scheme://example.com:$port" "$root/body.out"
 grep -Fq 'proxy_redirect http://custom.invalid https://keep.invalid;' "$root/site.conf"
 "$nginx_bin" -s quit -p "$root" -c "$root/nginx.conf"
 nx_test_wait_pidfile "$root/nginx.pid"
 for ((i=0;i<100;i++)); do [[ -f "$root/nginx.pid" ]] || break; sleep .02; done
done
echo 'real frontend response URL round trips passed'
