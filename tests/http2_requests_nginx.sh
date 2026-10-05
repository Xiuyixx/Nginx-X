#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/../nx.sh"
root="$(mktemp -d)"
NGINX_BIN="${NGINX_BIN:-${NGINX_TEST_BIN:-$(command -v nginx || true)}}"
[[ -x "$NGINX_BIN" ]] || { echo 'SKIP: real Nginx unavailable'; nx_test_cleanup; rm -rf "$root"; exit 0; }
cleanup() {
  if [[ -f "$root/nginx.pid" ]]; then kill "$(cat "$root/nginx.pid")" 2>/dev/null || true; fi
  nx_test_wait_pidfile "$root/nginx.pid"
  rm -rf "$root"; nx_test_cleanup
}
trap cleanup EXIT
# Some builds open their compiled prefix error log before parsing -c.
mkdir -p "$root/logs"
mkdir -p "$SSL_DIR/example.com"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com -addext subjectAltName=DNS:example.com \
  -keyout "$SSL_DIR/example.com/privkey.pem" -out "$SSL_DIR/example.com/fullchain.pem" >/dev/null 2>&1
port="$(python3 - <<'PY'
import socket
s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()
PY
)"
ipv6_available() { return 1; }
build_external_proxy_conf example.com "$port" http://127.0.0.1:3000 normal "$root/generated" 1
printf '# managed_by=Nginx-X\nserver { listen 127.0.0.1:%s; server_name example.com; location / { return 200 h2-ok; } }\n' "$port" > "$root/plain"
nx_https_transform enable "$root/plain" example.com "$SSL_DIR" "$port" > "$root/transformed"
write_main() {
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
 include $root/site;
}
CONF
}
for variant in generated transformed; do
  # Remove only generated HTTP redirect for runtime proof: no privileged :80.
  python3 - "$root/$variant" "$root/site" <<'PY'
import sys
s=open(sys.argv[1]).read();a=s.index('server {');b=s.index('server {',a+8)
s=s[:a]+s[b:]
# Generated proxy body is unrelated to the frontend protocol proof.
if sys.argv[1].endswith('generated'):
    i=s.index('    location / {');s=s[:i]+'    location / { return 200 h2-ok; }\n}\n'
open(sys.argv[2],'w').write(s)
PY
  write_main
  "$NGINX_BIN" -t -p "$root/" -c "$root/nginx.conf" > "$root/test.log" 2>&1 || { cat "$root/test.log"; exit 1; }
  if grep -qi deprecated "$root/test.log"; then cat "$root/test.log"; exit 1; fi
  "$NGINX_BIN" -p "$root/" -c "$root/nginx.conf"
  # TLS ALPN plus a real HTTP/2 SETTINGS exchange and HEADERS/DATA request.
  python3 - "$port" <<'PY'
import socket,ssl,struct,sys
ctx=ssl._create_unverified_context();ctx.set_alpn_protocols(['h2'])
s=ctx.wrap_socket(socket.create_connection(('127.0.0.1',int(sys.argv[1])),timeout=5),server_hostname='example.com')
assert s.selected_alpn_protocol()=='h2','HTTP/2 was disabled'
def frame(t,f,stream,p):return len(p).to_bytes(3,'big')+bytes([t,f])+struct.pack('!I',stream)+p
s.sendall(b'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n'+frame(4,0,0,b''))
# HPACK static :method GET, :scheme https, :path /, literal :authority.
h=b'\x82\x87\x84\x01\x0bexample.com'
s.sendall(frame(1,5,1,h))
def read(n):
 out=b''
 while len(out)<n:
  chunk=s.recv(n-len(out));assert chunk,'premature EOF';out+=chunk
 return out
body=b''
while True:
 head=read(9);n=int.from_bytes(head[:3],'big');t,f=head[3:5];stream=int.from_bytes(head[5:],'big');p=read(n)
 if t==4 and not f&1:s.sendall(frame(4,1,0,b''))
 if stream==1 and t==0:body+=p
 if stream==1 and f&1:break
assert body==b'h2-ok',body
s.close()
PY
  curl --noproxy '*' -ksS --resolve "example.com:$port:127.0.0.1" "https://example.com:$port/" | grep -q '^h2-ok$'
  kill "$(cat "$root/nginx.pid")"
  nx_test_wait_pidfile "$root/nginx.pid"
done
if [[ "$(nginx_http2_syntax)" == listen ]]; then
  for decision in on off; do
    python3 - "$root/transformed" "$root/modern-source" "$decision" <<'PYDOWN'
import sys
s=open(sys.argv[1]).read().replace('ssl http2;', 'ssl;')
i=s.rfind('server {')+len('server {')
s=s[:i]+'\n http2 '+sys.argv[3]+';'+s[i:]
open(sys.argv[2],'w').write(s)
PYDOWN
    nx_https_transform enable "$root/plain" example.com "$SSL_DIR" "$port" "$root/modern-source" > "$root/site"
    write_main
    "$NGINX_BIN" -t -p "$root/" -c "$root/nginx.conf" > "$root/test.log" 2>&1 || { cat "$root/test.log"; exit 1; }
  done
fi
nx_https_transform disable "$root/transformed" example.com "$SSL_DIR" '' > "$root/site"
write_main
"$NGINX_BIN" -t -p "$root/" -c "$root/nginx.conf" > "$root/test.log" 2>&1
"$NGINX_BIN" -p "$root/" -c "$root/nginx.conf"
curl --noproxy '*' -fsS "http://127.0.0.1:$port/" | grep -q '^h2-ok$'
"$NGINX_BIN" -v 2>&1
echo 'PASS: generated/transformed TLS have no deprecation warning, negotiate h2 and serve real HTTP/2 requests; disable restores HTTP'
