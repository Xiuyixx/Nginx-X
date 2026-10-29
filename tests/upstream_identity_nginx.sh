#!/usr/bin/env bash
# Real upstream Host/SNI/query proof, in an isolated temporary Nginx prefix.
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "$0")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
nginx_bin="${NGINX_TEST_BIN:-$(command -v nginx || true)}"
[[ -x "$nginx_bin" ]] || { echo 'SKIP: real nginx unavailable'; exit 0; }
root="$NX_TEST_ENV_ROOT"
bash tools/build-bundle.sh "$root/bundle"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
  -keyout "$root/key.pem" -out "$root/cert.pem" >/dev/null 2>&1
python3 - "$PWD/nx.sh" "$root/bundle" "$nginx_bin" "$root" <<'PY'
import http.server, threading, pathlib, subprocess, socket, ssl, sys, json, time, os
source, bundle, nginx, root = sys.argv[1:]
root = pathlib.Path(root)
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        data = json.dumps({'host': self.headers.get('Host'), 'path': self.path,
                           'referer': self.headers.get('Referer'),
                           'sni': getattr(self.connection, 'seen_sni', None)}).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, *args): pass
class V6(http.server.ThreadingHTTPServer): address_family = socket.AF_INET6
servers = []
try:
    for family, address in [(http.server.ThreadingHTTPServer, '127.0.0.1'), (V6, '::1')]:
        for tls in (False, True):
            try: srv = family((address, 0), Handler)
            except OSError:
                if address == '::1':
                    print('SKIP: IPv6 loopback unavailable'); continue
                raise
            if tls:
                ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                ctx.load_cert_chain(str(root/'cert.pem'), str(root/'key.pem'))
                ctx.set_servername_callback(lambda sock, name, _: setattr(sock, 'seen_sni', name))
                srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            servers.append((srv, address, tls))
    def shell(entry, script, *args):
        return subprocess.run(['bash', '-ec', 'source "$1"; shift; SUDO=""; ipv6_available(){ return 1; }; '+script,
                               '_', entry, *map(str,args)], capture_output=True, text=True)
    for entry in (source, bundle):
        # Refusal happens before truncating the caller's output for all modes.
        for mode in ('normal','streaming','media','emby_http','emby_https','emby_lily'):
            for bad in ('http://localhost?fixed=1', 'http://localhost/base/?fixed=1',
                        'https://[::1]:8443?fixed=1', 'http://localhost?'):
                for slot in ('main','stream'):
                    out = root/'rejected'; out.write_text('sentinel')
                    main, stream = (bad, 'http://localhost') if slot == 'main' else ('http://localhost', bad)
                    r = shell(entry, 'build_external_proxy_conf test.example 18080 "$1" "$2" "$3" 0 "$4"', main,mode,out,stream)
                    assert r.returncode and out.read_text() == 'sentinel', (mode,slot,r.stderr)
        for srv, address, tls in servers:
            for hostname in ([address, 'localhost'] if address == '127.0.0.1' and tls else [address]):
                host = '['+hostname+']' if ':' in hostname else hostname
                authority = f'{host}:{srv.server_port}'
                upstream = ('https' if tls else 'http')+'://'+authority
                for mode in ('normal','emby_https'):
                    s = socket.socket(); s.bind(('127.0.0.1',0)); port = s.getsockname()[1]; s.close()
                    site = root/'site.conf'
                    r = shell(entry, 'build_external_proxy_conf test.example "$1" "$2/base/" "$3" "$4" 0 "$2" "$2" "$2/web?ref=ok"', port,upstream,mode,site)
                    assert r.returncode == 0, r.stderr
                    conf = root/'proof.conf'
                    conf.write_text(f'''daemon off;
pid {root}/proof.pid;
error_log {root}/error.log;
events {{}}
http {{
 access_log off;
 client_body_temp_path {root}/body;
 proxy_temp_path {root}/proxy;
 fastcgi_temp_path {root}/fastcgi;
 uwsgi_temp_path {root}/uwsgi;
 scgi_temp_path {root}/scgi;
 map $http_upgrade $connection_upgrade {{ default upgrade; '' close; }}
 include {site};
}}
''')
                    check = subprocess.run([nginx,'-t','-p',str(root)+'/', '-c',str(conf)],capture_output=True)
                    assert check.returncode == 0, check.stderr
                    proc = subprocess.Popen([nginx,'-p',str(root)+'/', '-c',str(conf)], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                    try:
                        for _ in range(100):
                            try:
                                sock = socket.create_connection(('127.0.0.1',port),.2); sock.close(); break
                            except OSError:
                                assert proc.poll() is None, proc.stderr.read()
                                time.sleep(.02)
                        for path in (['/movie?client=ok','/s1/movie?client=ok'] if mode.startswith('emby') else ['/movie?client=ok']):
                            conn = http.client.HTTPConnection('127.0.0.1',port,timeout=8)
                            conn.request('GET',path,headers={'Host':'test.example'})
                            response = conn.getresponse(); data = response.read(); conn.close()
                            assert response.status == 200, (entry,hostname,mode,response.status,data)
                            data = json.loads(data)
                            assert data['host'] == authority, data
                            assert data['path'] == ('/movie?client=ok' if path.startswith('/s1/') else '/base/movie?client=ok'), data
                            assert data['sni'] == ('localhost' if tls and hostname=='localhost' else None), data
                            if path.startswith('/s1/'): assert data['referer'] == upstream+'/web?ref=ok', data
                    finally:
                        proc.terminate()
                        try: proc.communicate(timeout=5)
                        except subprocess.TimeoutExpired: proc.kill(); proc.communicate()
        print('PASS real upstream identity/query:', pathlib.Path(entry).name)
finally:
    for srv, _, _ in servers: srv.shutdown(); srv.server_close()
PY
