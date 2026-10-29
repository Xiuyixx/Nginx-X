#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
nginx_bin="${NGINX_TEST_BIN:-$(command -v nginx || true)}"
[[ -x "$nginx_bin" ]] || { echo 'skip: real nginx unavailable'; exit 0; }
root="$NX_TEST_ENV_ROOT"
mkdir -p "$SSL_DIR/stream.example" "$root/logs"
# Packaged nginx may run workers as nobody; allow traversal of the test prefix.
chmod 0755 "$root"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=stream.example \
 -keyout "$SSL_DIR/stream.example/privkey.pem" -out "$SSL_DIR/stream.example/fullchain.pem" >/dev/null 2>&1
bash tools/build-bundle.sh "$root/nx-bundle"
cat > "$root/proof.py" <<'PY'
import hashlib
import http.client
import http.server
import pathlib
import socket
import ssl
import subprocess
import sys
import threading

root = pathlib.Path(sys.argv[1])
entry, nginx = sys.argv[2:4]
release = threading.Event()
received = []
authorization = 'Bearer ' + 'body-fixture'
limit = 64 * 1024 * 1024

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def do_POST(self):
        digest = hashlib.sha256()
        size = 0
        if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
            while True:
                n = int(self.rfile.readline().split(b';')[0], 16)
                if not n:
                    assert self.rfile.readline() == b'\r\n'
                    break
                block = self.rfile.read(n)
                size += len(block)
                digest.update(block)
                assert self.rfile.read(2) == b'\r\n'
        else:
            remaining = int(self.headers['Content-Length'])
            while remaining:
                block = self.rfile.read(min(remaining, 65536))
                assert block, 'truncated upstream body'
                remaining -= len(block)
                size += len(block)
                digest.update(block)
        received.append((self.path, size, digest.hexdigest(), self.headers.get('Authorization')))
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Connection', 'close')
        self.end_headers()  # No X-Accel-Buffering: the template must stream.
        self.wfile.write(b'data: first\n\n')
        self.wfile.flush()
        if release.wait(15):
            self.wfile.write(b'data: last\n\n')
            self.wfile.flush()
        self.close_connection = True

    def log_message(self, *_):
        pass

servers = []
reserved = []
process = None
try:
    for tls in (False, True):
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        if tls:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(str(root/'ssl/stream.example/fullchain.pem'), str(root/'ssl/stream.example/privkey.pem'))
            server.socket = ctx.wrap_socket(server.socket, server_side=True)
        servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    for _ in range(7):
        sock = socket.socket()
        sock.bind(('127.0.0.1', 0))
        reserved.append(sock)
    ports = [sock.getsockname()[1] for sock in reserved]
    builder = r'''
set -euo pipefail
source "$1"
SUDO=''
ipv6_available() { return 1; }
http_port="$2" https_port="$3"
shift 3
build_proxy_conf stream.example "$1" "$http_port" "$CONF_DIR/internal.conf" streaming
build_external_proxy_conf stream.example "$2" "http://127.0.0.1:$http_port/api/" streaming "$CONF_DIR/external.conf"
build_external_proxy_conf stream.example "$3" "https://127.0.0.1:$https_port/api/" streaming "$CONF_DIR/external-upstream-tls.conf"
nx_https_transform enable "$CONF_DIR/internal.conf" stream.example "$SSL_DIR" "$4" > "$CONF_DIR/internal-tls.conf"
build_external_proxy_conf stream.example "$5" "https://127.0.0.1:$https_port/api/" streaming "$CONF_DIR/external-tls.conf" 1
build_proxy_conf normal.example "$6" "$http_port" "$CONF_DIR/normal-internal.conf" normal
build_external_proxy_conf normal.example "$7" "http://127.0.0.1:$http_port/api/" normal "$CONF_DIR/normal-external.conf"
'''
    subprocess.run(['bash', '-s', '--', entry, str(servers[0].server_port), str(servers[1].server_port), *map(str, ports)], input=builder, text=True, check=True)
    # Strip only generated port-80 redirects; keep the real TLS business blocks.
    for file in (root/'conf').glob('*.conf'):
        text = file.read_text()
        if file.name in ('internal-tls.conf', 'external-tls.conf'):
            first = text.index('server {')
            second = text.index('server {', first + 8)
            text = text[:first] + text[second:]
        for port in ports:
            text = text.replace(f'listen {port}', f'listen 127.0.0.1:{port}')
        file.write_text(text)
    config = root/'nginx.conf'
    config.write_text(f'''daemon off;
master_process off;
pid {root}/nginx.pid;
error_log {root}/error.log;
lock_file {root}/nginx.lock;
events {{}}
http {{
 access_log off;
 client_body_temp_path {root}/body;
 proxy_temp_path {root}/proxy;
 fastcgi_temp_path {root}/fastcgi;
 uwsgi_temp_path {root}/uwsgi;
 scgi_temp_path {root}/scgi;
 map $http_upgrade $connection_upgrade {{ default upgrade; '' close; }}
 include {root}/conf/*.conf;
}}
''')
    subprocess.run([nginx, '-t', '-p', str(root)+'/', '-c', str(config)], check=True)
    for sock in reserved:
        sock.close()
    process = subprocess.Popen([nginx, '-p', str(root)+'/', '-c', str(config)])
    # Bounded readiness probe, not a latency assertion.
    import time
    for _ in range(250):
        assert process.poll() is None, 'isolated nginx exited'
        try:
            with socket.create_connection(('127.0.0.1', ports[0]), .2):
                break
        except OSError:
            time.sleep(.02)
    else:
        raise AssertionError('isolated nginx did not start')

    def connection(index):
        if index in (3, 4):
            return http.client.HTTPSConnection('127.0.0.1', ports[index], timeout=10, context=ssl._create_unverified_context())
        return http.client.HTTPConnection('127.0.0.1', ports[index], timeout=10)

    def post(index, body, chunked=False):
        release.clear()
        before = len(received)
        path = '/v1/chat/completions?case=large'
        expected_path = ('/api' if index in (1, 2, 4) else '') + path
        conn = connection(index)
        data = (body[i:i+65536] for i in range(0, len(body), 65536)) if chunked else body
        try:
            conn.request('POST', path, body=data, encode_chunked=chunked,
                         headers={'Host': 'stream.example', 'Authorization': authorization, 'Content-Type': 'application/json'})
            response = conn.getresponse()
            assert response.status == 200, (index, len(body), chunked, response.status)
            assert response.readline() == b'data: first\n', 'first SSE event was buffered'
            assert len(received) == before + 1
            assert received[-1] == (expected_path, len(body), hashlib.sha256(body).hexdigest(), authorization), received[-1]
            release.set()
            assert b'data: last\n\n' in response.read()
        finally:
            release.set()
            conn.close()

    def rejected(index, length, path='/v1/chat/completions'):
        before = len(received)
        # Known oversized Content-Length must fail before uploading any payload.
        conn = connection(index)
        try:
            conn.putrequest('POST', path)
            conn.putheader('Content-Length', str(length))
            conn.putheader('Connection', 'close')
            conn.endheaders()
            response = conn.getresponse()
            assert response.status == 413, (index, path, response.status)
            response.read()
            assert len(received) == before, 'oversized request reached upstream'
        finally:
            conn.close()

    def rejected_chunked():
        before = len(received)
        conn = connection(0)
        try:
            # No Content-Length: the streaming parser must still enforce the cap.
            chunks = (b'x' * 65536 for _ in range(limit // 65536 + 1))
            try:
                conn.request('POST', '/v1/chat/completions', body=chunks,
                             encode_chunked=True, headers={'Connection': 'close'})
            except (BrokenPipeError, ConnectionResetError):
                pass  # Nginx may stop reading as soon as the cap is exceeded.
            response = conn.getresponse()
            assert response.status == 413, response.status
            response.read()
            assert len(received) == before, 'oversized chunked request reached upstream'
        finally:
            conn.close()

    payload = b'{"stream":true,"messages":[{"role":"user","content":"' + b'x'*(2*1024*1024) + b'"}]}'
    for i in range(5):
        post(i, payload)
        post(i, payload, chunked=True)
    # Exact cap works, cap+1 is rejected; not merely an unlimited upload change.
    post(0, b'x'*limit)
    for i in range(5):
        rejected(i, limit + 1)
    rejected_chunked()
    # Normal mode retains Nginx's 1 MiB default; ACME does not inherit 64 MiB.
    for i in (5, 6):
        rejected(i, len(payload))
    for i in (0, 1, 2):
        rejected(i, len(payload), '/.well-known/acme-challenge/proof')
    print(f'PASS {pathlib.Path(entry).name}: 2 MiB POST/chunked + gated SSE over HTTP/TLS; 64 MiB exact/oversize; auth/path/body integrity; normal/ACME unchanged')
finally:
    release.set()
    for sock in reserved:
        sock.close()
    if process is not None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    for server in servers:
        server.shutdown()
        server.server_close()
PY
for entry in "$PWD/nx.sh" "$root/nx-bundle"; do
  python3 "$root/proof.py" "$root" "$entry" "$nginx_bin"
done
