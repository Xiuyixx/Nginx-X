#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
source ./nx.sh
nginx_bin="${NGINX_TEST_BIN:-$(command -v nginx || true)}"
[[ -x "$nginx_bin" ]] || { echo 'skip: real nginx unavailable'; exit 0; }
root="$NX_TEST_ENV_ROOT"
SUDO=''
CONF_DIR="$NX_CONF_DIR"
ipv6_available() { return 1; }
cleanup() {
 if [[ -f "$root/nginx.pid" ]]; then
  "$nginx_bin" -p "$root/" -c "$NGINX_MAIN_CONF" -s quit >/dev/null 2>&1 || true
  nx_test_wait_pidfile "$root/nginx.pid"
 fi
 nx_test_cleanup
}
trap cleanup EXIT
# Python owns both upstream and clients. First event must arrive while the
# upstream is waiting for the client's release event (not a timing benchmark).
cat > "$root/proof.py" <<'PY'
import http.server, threading, pathlib, sys, ssl, socket, subprocess, time
root=pathlib.Path(sys.argv[1]); release=threading.Event(); received=[]
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def do_GET(self):
        received.append((self.path,self.headers.get('Authorization'),self.headers.get('Host')))
        self.send_response(200)
        self.send_header('Content-Type','text/event-stream')
        self.send_header('Connection','close')
        self.end_headers() # deliberately no X-Accel-Buffering
        self.wfile.write(b'data: first\n\n'); self.wfile.flush()
        if not release.wait(15): return
        self.wfile.write(b'data: last\n\n'); self.wfile.flush()
        self.close_connection=True
    def log_message(self,*args): pass
servers=[]
for tls in [False,True]:
    srv=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    if tls:
        ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(str(root/'cert.pem'),str(root/'key.pem'))
        srv.socket=ctx.wrap_socket(srv.socket,server_side=True)
    servers.append(srv)
    threading.Thread(target=srv.serve_forever,daemon=True).start()
(root/'ports').write_text(' '.join(str(s.server_port) for s in servers))
(root/'ready').touch()
while not (root/'start').exists(): time.sleep(.02)
try:
    for port, path, expected, host in [
        (18090,'/v1/chat?token=abc','/v1/chat?token=abc','internal.example'),
        (18091,'/chat?token=abc','/api/chat?token=abc',f'127.0.0.1:{servers[0].server_port}'),
        (18092,'/chat?token=abc','/api/chat?token=abc',f'127.0.0.1:{servers[1].server_port}')]:
        release.clear()
        conn=socket.create_connection(('127.0.0.1',port),5); conn.settimeout(10)
        conn.sendall(f'GET {path} HTTP/1.1\r\nHost: {"internal.example" if port==18090 else "external.example"}\r\nAuthorization: Bearer proof\r\nConnection: close\r\n\r\n'.encode())
        data=b''
        try:
            while b'data: first\n\n' not in data:
                chunk=conn.recv(4096)
                assert chunk, 'ended before first event'
                data+=chunk
            assert b'data: last' not in data, 'first event buffered until completion'
            assert received[-1]==(expected,'Bearer proof',host), received[-1]
        finally: release.set()
        while True:
            chunk=conn.recv(4096)
            if not chunk: break
            data+=chunk
        assert b'data: last\n\n' in data
        conn.close()
    (root/'passed').touch()
finally:
    release.set()
    for srv in servers: srv.shutdown()
PY
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
 -keyout "$root/key.pem" -out "$root/cert.pem" >/dev/null 2>&1
python3 "$root/proof.py" "$root" > "$root/proof.log" 2>&1 &
proof_pid=$!
# Extend cleanup to release/terminate an upstream if configuration fails.
trap 'kill "$proof_pid" 2>/dev/null || true; cleanup' EXIT
for ((i=0;i<250;i++)); do [[ ! -f "$root/ready" ]] || break; sleep .02; done
read -r http_port https_port < "$root/ports" || true
build_proxy_conf internal.example 18090 "$http_port" "$CONF_DIR/internal.conf" streaming
build_external_proxy_conf external.example 18091 "http://127.0.0.1:$http_port/api/" streaming "$CONF_DIR/external.conf"
build_external_proxy_conf external.example 18092 "https://127.0.0.1:$https_port/api/" streaming "$CONF_DIR/tls-upstream.conf"
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
 include $CONF_DIR/*.conf;
}
CONF
"$nginx_bin" -t -p "$root/" -c "$NGINX_MAIN_CONF"
"$nginx_bin" -p "$root/" -c "$NGINX_MAIN_CONF"
touch "$root/start"
if ! wait "$proof_pid"; then cat "$root/proof.log" >&2; exit 1; fi
[[ -f "$root/passed" ]]
echo 'real Nginx SSE: internal + external HTTP/HTTPS, first event before completion, authorization/path/query: PASS'
