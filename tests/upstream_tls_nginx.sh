#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "$0")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
nginx_bin="${NGINX_TEST_BIN:-$(command -v nginx || true)}"
[[ -x "$nginx_bin" ]] || { echo 'SKIP: real nginx unavailable'; exit 0; }
root="$NX_TEST_ENV_ROOT"
bash tools/build-bundle.sh "$root/bundle"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=nginxx-test-ca -addext basicConstraints=critical,CA:TRUE \
 -keyout "$root/ca.key" -out "$root/ca" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -subj /CN=localhost -addext subjectAltName=DNS:localhost \
 -keyout "$root/key" -out "$root/server.csr" >/dev/null 2>&1
openssl x509 -req -days 1 -in "$root/server.csr" -CA "$root/ca" -CAkey "$root/ca.key" \
 -CAcreateserial -out "$root/server.crt" -extfile <(printf 'subjectAltName=DNS:localhost') >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost \
 -keyout "$root/self.key" -out "$root/self.crt" >/dev/null 2>&1
chmod 0644 "$root/ca" "$root/server.crt"
python3 - "$PWD/nx.sh" "$root/bundle" "$nginx_bin" "$root" <<'PY'
import http.client, http.server, os, pathlib, socket, ssl, subprocess, sys, threading, time
source, bundle, nginx, root = sys.argv[1:]
root = pathlib.Path(root)
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data = b'verified upstream reached'
        self.send_response(200); self.send_header('Content-Length', str(len(data)))
        self.end_headers(); self.wfile.write(data)
    def log_message(self, *_): pass
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(str(root/'server.crt'), str(root/'key'))
self_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
self_context.load_cert_chain(str(root/'self.crt'), str(root/'self.key'))
upstreams = []
try:
    for entry in (source, bundle):
        cases, reservations, configs = [], [], []
        # All main modes and all split modes must fail closed. Mixed split URLs
        # prove the decision follows URL scheme, not the emby_http mode name.
        for mode in ('normal', 'streaming', 'media', 'emby_http', 'emby_https', 'emby_lily'):
            for policy, hostname, expected in (('system','localhost',502), ('private','localhost',200),
                                                ('private','127.0.0.1',502), ('off','127.0.0.1',200)):
                sock = socket.socket(); sock.bind(('127.0.0.1',0)); reservations.append(sock)
                port = sock.getsockname()[1]
                # Give each policy its own endpoint, so an expected rejection
                # cannot mark the private-CA case's peers temporarily down.
                upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
                upstream.socket = (self_context if policy == 'system' else context).wrap_socket(upstream.socket, server_side=True)
                threading.Thread(target=upstream.serve_forever, daemon=True).start()
                upstreams.append(upstream)
                url = f'https://{hostname}:{upstream.server_port}'
                conf = root/f'site-{len(configs)}.conf'; configs.append(conf)
                script = '''source "$1"; shift; SUDO=''; ipv6_available(){ return 1; };
                build_external_proxy_conf test.example "$1" "$2" "$3" "$4" 0 "$2" '' '' "$2|$2" "$5" "$6"'''
                result = subprocess.run(['bash','-ec',script,'_',entry,str(port),url,mode,str(conf),
                                         'off' if policy=='off' else 'on',str(root/'ca') if policy=='private' else ''],
                                        capture_output=True,text=True)
                assert result.returncode == 0, result.stderr
                text = conf.read_text()
                if policy=='off':
                    assert 'proxy_ssl_verify off' in result.stderr and '# upstream_tls_verify=off' in text
                else:
                    assert 'proxy_ssl_verify on;' in text
                text = text.replace(f'listen {port};', f'listen 127.0.0.1:{port};')
                conf.write_text(text)
                paths = ('/', '/s1/movie', '/s2/movie') if mode.startswith('emby') else ('/',)
                cases.extend((port, path, expected, mode, policy, hostname) for path in paths)
        config = root/'proof.conf'
        config.write_text(f'''daemon off;
master_process off;
pid {root}/nginx.pid;
error_log {root}/error.log info;
lock_file {root}/lock;
events {{}}
http {{
 access_log off;
 client_body_temp_path {root}/body;
 proxy_temp_path {root}/proxy;
 fastcgi_temp_path {root}/fastcgi;
 uwsgi_temp_path {root}/uwsgi;
 scgi_temp_path {root}/scgi;
 map $http_upgrade $connection_upgrade {{ default upgrade; '' close; }}
''' + ''.join(f' include {c};\n' for c in configs) + '}\n')
        check = subprocess.run([nginx,'-t','-p',str(root)+'/', '-c',str(config)],capture_output=True,text=True)
        assert check.returncode == 0, check.stderr
        for sock in reservations: sock.close()
        process = subprocess.Popen([nginx,'-p',str(root)+'/', '-c',str(config)],stderr=subprocess.PIPE)
        try:
            for _ in range(200):
                assert process.poll() is None, process.stderr.read()
                try:
                    with socket.create_connection(('127.0.0.1',cases[0][0]),.1): break
                except OSError: time.sleep(.02)
            else: raise AssertionError('nginx readiness timeout')
            for port, path, expected, mode, policy, hostname in cases:
                connection = http.client.HTTPConnection('127.0.0.1',port,timeout=5)
                connection.request('GET',path,headers={'Host':'test.example'})
                response = connection.getresponse(); body = response.read(); connection.close()
                assert response.status == expected, (mode,policy,hostname,path,response.status,body,(root/'error.log').read_text()[-6000:])
                if expected == 200: assert body == b'verified upstream reached'
            log = (root/'error.log').read_text()
            assert 'upstream SSL certificate verify error: (18:self-signed certificate)' in log
            assert 'upstream SSL certificate does not match' in log
        finally:
            process.terminate()
            try: process.communicate(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.communicate()
        print(f'PASS real upstream TLS {pathlib.Path(entry).name}: {len(cases)} requests; default self-signed rejection, private CA success, name mismatch rejection, explicit off')
finally:
    for upstream in upstreams: upstream.shutdown(); upstream.server_close()
PY
