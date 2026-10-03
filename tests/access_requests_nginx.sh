#!/usr/bin/env bash
# Real sockets, HTTP and TLS; never uses the machine's nginx config/service.
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NGINX_BIN="${NGINX_BIN:-$(command -v nginx || true)}"
if [[ -z "$NGINX_BIN" ]]; then
  NGINX_BIN="$(dirname "$REPO_DIR")/tmp/nginx-x-test-runtime/extracted/usr/sbin/nginx"
fi
[[ -x "$NGINX_BIN" ]] || { echo 'SKIP: set NGINX_BIN to a real nginx binary' >&2; exit 77; }
command -v python3 >/dev/null
command -v openssl >/dev/null
TEST_ROOT="$(mktemp -d /tmp/nginxx-requests-XXXXXX)"
cleanup() {
  local rc=$?
  if [[ -f "$TEST_ROOT/nginx.pid" ]]; then
    "$NGINX_BIN" -p "$TEST_ROOT/" -c "$TEST_ROOT/nginx.conf" -s quit >/dev/null 2>&1 || true
# Wait for the isolated master to finish before removing its prefix.
    python3 - "$TEST_ROOT/nginx.pid" <<'PY'
import pathlib,sys,time
pidfile=pathlib.Path(sys.argv[1])
for _ in range(100):
    if not pidfile.exists(): break
    time.sleep(.02)
else: raise SystemExit('isolated nginx did not exit after quit')
PY
  fi
  if (( rc )); then
    echo "FAILED: isolated nginx log follows" >&2
    tail -60 "$TEST_ROOT/error.log" >&2 2>/dev/null || true
  fi
  rm -rf "$TEST_ROOT"
}
trap 'cleanup; nx_test_cleanup' EXIT
# nginx workers must be able to traverse the fixture when the suite runs as root.
chmod 755 "$TEST_ROOT"
export NX_CONF_DIR="$TEST_ROOT/conf.d" STATE_DIR="$TEST_ROOT/state" SSL_DIR="$TEST_ROOT/ssl"
export NGINX_MAIN_CONF="$TEST_ROOT/nginx.conf"
# shellcheck disable=SC1091
source "$REPO_DIR/nx.sh"
# shellcheck disable=SC2034
SUDO=""
mkdir -p "$CONF_DIR" "$STATE_DIR" "$SSL_DIR" "$TEST_ROOT/www/.well-known/acme-challenge"
printf 'renewal-proof\n' > "$TEST_ROOT/www/.well-known/acme-challenge/token"
# Keep the production capability gate, using the binary running this fixture.
nginx_local_version() {
  "$NGINX_BIN" -v 2>&1 | sed -E 's#^nginx version: nginx/##'
}
TLS_DENIED=CLOSED
if nginx_supports_ssl_reject_handshake; then TLS_DENIED=HANDSHAKE_REJECTED; fi
echo "Testing nginx $(nginx_local_version): TLS catchall expects $TLS_DENIED"
domain_only_warn_exposed_ports() { :; }
# Allocate distinct unprivileged loopback ports, retaining reservations until all
# choices have been made. The brief close/bind race is limited to this instance.
read -r HTTP_PORT TLS_PORT EXACT_PORT V6_PORT < <(python3 - <<'PY'
import socket
sockets=[]
for _ in range(4):
    s=socket.socket(); s.bind(('127.0.0.1',0)); sockets.append(s)
print(*(s.getsockname()[1] for s in sockets))
PY
)
HAS_IPV6=0
if python3 - <<'PY'
import socket
s=socket.socket(socket.AF_INET6); s.bind(('::1',0))
PY
then HAS_IPV6=1; else echo 'SKIP: IPv6 loopback unavailable'; fi
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=alpha.test \
  -keyout "$SSL_DIR/key.pem" -out "$SSL_DIR/cert.pem" >/dev/null 2>&1
cat > "$NGINX_MAIN_CONF" <<EOF
worker_processes 1;
pid $TEST_ROOT/nginx.pid;
error_log $TEST_ROOT/error.log notice;
lock_file $TEST_ROOT/nginx.lock;
events { worker_connections 128; }
http {
  access_log $TEST_ROOT/access.log;
  client_body_temp_path $TEST_ROOT/body;
  proxy_temp_path $TEST_ROOT/proxy;
  fastcgi_temp_path $TEST_ROOT/fastcgi;
  uwsgi_temp_path $TEST_ROOT/uwsgi;
  scgi_temp_path $TEST_ROOT/scgi;
  include $CONF_DIR/*.conf;
}
EOF
site() {
  local name="$1" policy="$2" address="$3" tls="${4:-0}"
  cat <<EOF
# managed_by=Nginx-X
# access_policy=$policy
server {
  listen $address$([[ "$tls" == 1 ]] && printf ' ssl');
  server_name $name.test www.$name.test;
EOF
  if [[ "$tls" == 1 ]]; then
    printf '  ssl_certificate %s/cert.pem;\n  ssl_certificate_key %s/key.pem;\n' "$SSL_DIR" "$SSL_DIR"
  fi
  cat <<EOF
  location ^~ /.well-known/acme-challenge/ { root $TEST_ROOT/www; }
  location / { return 200 "$name"; }
}
EOF
}
# One server deliberately shares HTTP/TLS listeners: HTTP has no SNI.
site alpha strict "127.0.0.1:$TLS_PORT" 1 |
  sed "/listen .* ssl;/a\\  listen 127.0.0.1:$HTTP_PORT;" |
  awk '/^#/ {print; next} {printf "%s ", $0} END {print ""}' > "$CONF_DIR/alpha.conf"
ensure_ssl_directives_present "$CONF_DIR/alpha.conf"
site beta inherit "127.0.0.1:$HTTP_PORT" > "$CONF_DIR/beta.conf"
site beta inherit "127.0.0.1:$TLS_PORT" 1 | sed '/^# managed_by=/d; /^# access_policy=/d' >> "$CONF_DIR/beta.conf"
site exact strict "127.0.0.2:$EXACT_PORT" > "$CONF_DIR/exact.conf"
if (( HAS_IPV6 )); then site six strict "[::1]:$V6_PORT" > "$CONF_DIR/six.conf"; fi
# A new worker PID proves the asynchronous reload has actually been applied.
reload_nginx_safe() {
  if ! "$NGINX_BIN" -p "$TEST_ROOT/" -c "$NGINX_MAIN_CONF" -t > "$TEST_ROOT/validation.log" 2>&1; then
    if grep -q 'unknown directive "invalid_directive"' "$TEST_ROOT/validation.log"; then
      : > "$TEST_ROOT/invalid-directive-rejected"
    fi
    return 1
  fi
  if [[ -f "$TEST_ROOT/fail-reload-once" ]]; then rm "$TEST_ROOT/fail-reload-once"; return 1; fi
  local before
  before="$(cat "/proc/$(cat "$TEST_ROOT/nginx.pid")/task/$(cat "$TEST_ROOT/nginx.pid")/children")"
  "$NGINX_BIN" -p "$TEST_ROOT/" -c "$NGINX_MAIN_CONF" -s reload || return 1
  python3 - "$TEST_ROOT/nginx.pid" "$before" <<'PY'
import pathlib,sys,time
master=pathlib.Path(sys.argv[1]).read_text().strip(); old=set(sys.argv[2].split())
children=pathlib.Path(f'/proc/{master}/task/{master}/children')
for _ in range(100):
    current=set(children.read_text().split())
    if current-old and not current.intersection(old):
        break
    time.sleep(.02)
else: raise SystemExit('reload did not produce a new worker')
PY
}
nx_access_sync_files
if [[ "$TLS_DENIED" == HANDSHAKE_REJECTED ]]; then
  grep -q 'ssl_reject_handshake on;' "$(domain_only_conf_path)"
else
  if grep -q 'ssl_reject_handshake' "$(domain_only_conf_path)"; then
    echo 'FAIL: unsupported handshake directive in legacy catchall' >&2; exit 1
  fi
  grep -q 'return 444;' "$(domain_only_conf_path)"
  grep -q 'ssl_certificate ' "$(domain_only_conf_path)"
fi
"$NGINX_BIN" -p "$TEST_ROOT/" -c "$NGINX_MAIN_CONF" -t
"$NGINX_BIN" -p "$TEST_ROOT/" -c "$NGINX_MAIN_CONF"
# Each assertion opens a fresh connection. Refused connections/timeouts are test
# failures, never accepted as evidence that access policy rejected a request.
request() {
  python3 - "$@" <<'PY'
import socket,ssl,sys
label,address,port,sni,host,expected,body,*rest=sys.argv[1:]
path=rest[0] if rest else '/'
raw=socket.create_connection((address,int(port)),timeout=3)
response=b''; handshake_rejected=False
if sni!='PLAIN':
    context=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname=False; context.verify_mode=ssl.CERT_NONE
    try: raw=context.wrap_socket(raw,server_hostname=None if sni=='NONE' else sni)
    except ssl.SSLError as exc:
        if 'UNRECOGNIZED_NAME' not in str(exc): raise
        handshake_rejected=True
if not handshake_rejected:
    with raw:
        version='1.0' if host=='NONE' else '1.1'
        headers='' if host=='NONE' else f'Host: {host}\r\n'
        raw.sendall(f'GET {path} HTTP/{version}\r\n{headers}Connection: close\r\n\r\n'.encode())
        while True:
            try: chunk=raw.recv(65536)
            except ConnectionResetError: break
            if not chunk: break
            response+=chunk
status=response.split(b' ',2)[1].decode() if response.startswith(b'HTTP/') else 'CLOSED'
if handshake_rejected: status='HANDSHAKE_REJECTED'
assert status==expected, f'{label}: expected {expected}, got {status}: {response!r}'
if body!='-': assert body.encode() in response.split(b'\r\n\r\n',1)[-1], (label,response)
print('PASS:',label)
PY
}
http() { request "$1" 127.0.0.1 "$HTTP_PORT" PLAIN "$2" "$3" "${4:--}" "${5:-/}"; }
tls() { request "$1" 127.0.0.1 "$TLS_PORT" "$2" "$3" "$4" "${5:--}"; }
http 'valid HTTP Host' alpha.test 200 alpha
http 'invalid HTTP Host' unknown.test CLOSED
http 'direct IPv4 Host' 127.0.0.1 CLOSED
http 'absent Host HTTP/1.0' NONE CLOSED
http 'HTTP alias' www.alpha.test 200 alpha
http 'HTTP uppercase and port' "ALPHA.TEST:$HTTP_PORT" 200 alpha
http 'HTTP trailing dot normalized' alpha.test. 200 alpha
http 'shared socket second site' beta.test 200 beta
tls 'valid SNI and Host' alpha.test alpha.test 200 alpha
tls 'absent SNI' NONE alpha.test "$TLS_DENIED"
tls 'unknown SNI' unknown.test alpha.test "$TLS_DENIED"
tls 'mismatching SNI and Host' beta.test alpha.test CLOSED
tls 'SNI alias matching Host' www.alpha.test www.alpha.test 200 alpha
tls 'SNI alias mismatching Host' www.alpha.test alpha.test CLOSED
# DNS case and a single trailing dot are normalized for Host and SNI.
tls 'TLS uppercase SNI normalized' ALPHA.TEST ALPHA.TEST 200 alpha
tls 'TLS trailing dot SNI normalized' alpha.test. alpha.test 200 alpha
tls 'TLS Host port and case' alpha.test "ALPHA.TEST:$TLS_PORT" 200 alpha
tls 'TLS absent Host HTTP/1.0' alpha.test NONE CLOSED
tls 'TLS trailing dot Host normalized' alpha.test alpha.test. 200 alpha
tls 'TLS IP Host rejected' alpha.test 127.0.0.1 CLOSED
request 'exact IPv4 listener valid' 127.0.0.2 "$EXACT_PORT" PLAIN exact.test 200 exact
request 'exact IPv4 listener denied' 127.0.0.2 "$EXACT_PORT" PLAIN unknown.test CLOSED -
if (( HAS_IPV6 )); then
  request 'exact IPv6 listener valid' ::1 "$V6_PORT" PLAIN six.test 200 six
  request 'exact IPv6 listener denied' ::1 "$V6_PORT" PLAIN '[::1]' CLOSED -
fi
http 'ACME renewal challenge on strict site' alpha.test 200 renewal-proof '/.well-known/acme-challenge/token'
http 'ACME path cannot bypass Host check' unknown.test CLOSED - '/.well-known/acme-challenge/token'
# Select one existing open site as default on shared HTTP/TLS sockets.
nx_access_set_default "$CONF_DIR/beta.conf" "127.0.0.1:$HTTP_PORT,127.0.0.1:$TLS_PORT"
http 'selected default serves unknown Host' unknown.test 200 beta
http 'selected default serves direct IP' 127.0.0.1 200 beta
http 'selected default serves absent Host' NONE 200 beta
tls 'selected open default without SNI' NONE unknown.test 200 beta
domain_only_enable
http 'global strict closes selected default' unknown.test CLOSED
tls 'global strict selected default without SNI' NONE beta.test CLOSED
tls 'global strict selected default unknown SNI' unknown.test beta.test CLOSED
http 'global strict preserves second site' beta.test 200 beta
domain_only_disable
http 'global disable reopens inherited default' unknown.test 200 beta
tls 'per-site strict survives global disable' alias.test alpha.test CLOSED
# A failed real nginx validation must restore every file and global state.
cp -a "$CONF_DIR" "$TEST_ROOT/before-conf"
cp -a "$DOMAIN_ONLY_STATE" "$TEST_ROOT/before-state"
invalid_mutation() { sed -i '/^server {/a\  invalid_directive;' "$CONF_DIR/beta.conf"; }
if nx_transaction invalid_mutation; then echo 'FAIL: invalid nginx config accepted' >&2; exit 1; fi
[[ -f "$TEST_ROOT/invalid-directive-rejected" ]]
diff -r "$TEST_ROOT/before-conf" "$CONF_DIR"
cmp "$TEST_ROOT/before-state" "$DOMAIN_ONLY_STATE"
http 'validation rollback preserves live default' unknown.test 200 beta
# Inject the reload failure after real nginx -t, then really reload restored files.
: > "$TEST_ROOT/fail-reload-once"
if domain_only_enable; then echo 'FAIL: injected reload failure accepted' >&2; exit 1; fi
diff -r "$TEST_ROOT/before-conf" "$CONF_DIR"
cmp "$TEST_ROOT/before-state" "$DOMAIN_ONLY_STATE"
http 'reload rollback preserves live default' unknown.test 200 beta
tls 'reload rollback preserves strict policy' alias.test alpha.test CLOSED
nx_access_set_default "$CONF_DIR/beta.conf" ''
http 'clearing default restores deny fallback' unknown.test CLOSED
http 'strict application still reachable' alpha.test 200 alpha
echo 'PASS: real isolated nginx access integration suite'
