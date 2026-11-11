#!/usr/bin/env bash
# Real process/socket evidence; all paths and ports are isolated, no host service.
# shellcheck disable=SC2317
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/fixtures/test-environment.sh
source "$ROOT/tests/fixtures/test-environment.sh"
T="$NX_TEST_ENV_ROOT"
BIN="${NGINX_TEST_BIN:-$(command -v nginx || true)}"
[[ -x "$BIN" ]] || BIN="$ROOT/../tmp/nginx-x-test-runtime/extracted/usr/sbin/nginx"
[[ -x "$BIN" ]] || { echo 'SKIP: real nginx unavailable'; exit 77; }
# Dynamic-link capability check precedes execution of the isolated binary.
ldd "$BIN" > "$T/ldd.log" 2>&1 || true
if grep -q 'not found' "$T/ldd.log"; then cat "$T/ldd.log"; exit 1; fi
# shellcheck disable=SC1091
source "$ROOT/nx.sh"
SUDO=''
# Only this isolated test supplies the service-driver seam. Production shell
# and dispatcher call the same engine without an environment hook.
reload_nginx_safe() {
  local engine
  engine="$(nx_nginx_reload_engine)" || return 1
  python3 -c "$engine
nx_reload(*sys.argv[1:])
" "$NX_NGINX_BIN" "$NGINX_MAIN_CONF" "$NX_NGINX_PID_FILE" "$NX_NGINX_PREFIX" "$NX_NGINX_SERVICE_DRIVER" "$NX_NGINX_VERIFY_TIMEOUT"
}
export NX_NGINX_BIN="$BIN" NX_NGINX_PID_FILE="$T/nginx.pid" NX_NGINX_PREFIX="$T/" NX_NGINX_VERIFY_TIMEOUT=1.5
export NX_NGINX_SERVICE_DRIVER="$T/driver" NX_TEST_MODE="$T/mode" NX_TEST_CALLS="$T/calls"
chmod 755 "$T"
cleanup() {
  local rc=$?
  if [[ -s "$NX_NGINX_PID_FILE" ]]; then
    "$BIN" -p "$T/" -c "$NGINX_MAIN_CONF" -s quit >/dev/null 2>&1 || true
    nx_test_wait_pidfile "$NX_NGINX_PID_FILE" || true
  fi
  if (( rc )); then cat "$T/error.log" "$T/output" 2>/dev/null || true; fi
  nx_test_cleanup
  return "$rc"
}
trap cleanup EXIT
read -r PORT PORT2 < <(python3 - <<'PY'
import socket
s=[socket.socket(),socket.socket()]
for x in s: x.bind(('127.0.0.1',0))
print(*(x.getsockname()[1] for x in s))
PY
)
cat > "$NGINX_MAIN_CONF" <<CONF
worker_processes 1;
pid $NX_NGINX_PID_FILE;
error_log $T/error.log notice;
events { worker_connections 128; }
http {
 access_log off;
 client_body_temp_path $T/body;
 proxy_temp_path $T/proxy;
 fastcgi_temp_path $T/fastcgi;
 uwsgi_temp_path $T/uwsgi;
 scgi_temp_path $T/scgi;
 include $CONF_DIR/*.conf;
}
CONF
cat > "$NX_NGINX_SERVICE_DRIVER" <<'DRIVER'
#!/usr/bin/env python3
import os,subprocess,sys,time
mode=open(os.environ['NX_TEST_MODE']).read().strip()
with open(os.environ['NX_TEST_CALLS'],'a') as out: out.write(sys.argv[1]+'\n')
args=[os.environ['NX_NGINX_BIN'],'-p',os.environ['NX_NGINX_PREFIX'],'-c',os.environ['NGINX_MAIN_CONF']]
if sys.argv[1]=='reload': args+=['-s','reload']
if mode=='noop': sys.exit(0)
if mode=='noop-once':
    open(os.environ['NX_TEST_MODE'],'w').write('real')
    sys.exit(0)
if mode=='fail': sys.exit(9)
if mode=='respawn':
    pid=int(open(os.environ['NX_NGINX_PID_FILE']).read())
    for child in open(f'/proc/{pid}/task/{pid}/children').read().split():
        try:
            if open(f'/proc/{child}/comm').read().strip() == 'nginx': os.kill(int(child),9)
        except FileNotFoundError: pass
    sys.exit(0)
if mode=='delay':
    # Service manager returns before daemon readiness; explicitly detached stdio
    # ensures command collection does not wait on the delayed daemon.
    subprocess.Popen([sys.executable,'-c','import subprocess,sys,time; time.sleep(.35); subprocess.run(sys.argv[1:],check=True)',*args],close_fds=True,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    sys.exit(0)
subprocess.run(args,check=True,close_fds=True)
DRIVER
chmod +x "$NX_NGINX_SERVICE_DRIVER"
site() { printf 'server { listen 127.0.0.1:%s; server_name test.example; location / { return 200 "%s"; } }\n' "$1" "$2" > "$CONF_DIR/site.conf"; }
request() {
  local actual
  actual="$(curl --noproxy '*' -fsS --max-time 2 "http://127.0.0.1:$1/")"
  [[ "$actual" == "$2" ]]
}
expect_fail() {
  if "$@" > "$T/output" 2>&1; then cat "$T/output"; echo 'unexpected success' >&2; exit 1; fi
}
site "$PORT" one
printf noop > "$NX_TEST_MODE"
expect_fail reload_nginx_safe
[[ ! -s "$NX_NGINX_PID_FILE" ]]
printf fail > "$NX_TEST_MODE"
expect_fail reload_nginx_safe
[[ ! -s "$NX_NGINX_PID_FILE" ]]
echo 'PASS: start-zero-without-daemon and nonzero start are failures'

# First real start is inside a transaction. Check both held directory locks
# disappear in the daemon and a second transaction cannot hang on inherited FD.
printf delay > "$NX_TEST_MODE"
mutate() { site "$PORT" "$1"; }
nx_transaction mutate started > "$T/output" 2>&1
request "$PORT" started
python3 - "$NX_NGINX_PID_FILE" "$CONF_DIR" "$SSL_DIR" <<'PY'
import glob,os,sys
pid=open(sys.argv[1]).read().strip()
for fd in glob.glob('/proc/'+pid+'/fd/*'):
    try: path=os.readlink(fd)
    except FileNotFoundError: continue
    assert path not in sys.argv[2:], (fd,path)
PY
flock -w 1 "$CONF_DIR" true
printf real > "$NX_TEST_MODE"
nx_transaction mutate reloaded > "$T/output" 2>&1
request "$PORT" reloaded
flock -w 1 "$CONF_DIR" true
echo 'PASS: delayed real start, real reload, second transaction and daemon lock-FD isolation'

# Same PID and old listeners are insufficient when reload command does nothing.
printf noop > "$NX_TEST_MODE"
site "$PORT" stale
expect_fail reload_nginx_safe
request "$PORT" reloaded
printf respawn > "$NX_TEST_MODE"
site "$PORT" respawned
expect_fail reload_nginx_safe
request "$PORT" reloaded
printf real > "$NX_TEST_MODE"
site "$PORT" stale
reload_nginx_safe > "$T/output" 2>&1
request "$PORT" stale

# Real accepted SIGHUP with an impossible bind: nginx -t succeeds, -s reload
# returns zero, but old workers/listeners remain. Must reject and restore files.
python3 - "$PORT2" "$T/ready" <<'PY' &
import socket,sys,time
s=socket.socket(); s.bind(('127.0.0.1',int(sys.argv[1]))); s.listen()
open(sys.argv[2],'w').close()
time.sleep(12)
PY
blocker=$!
for _ in {1..100}; do [[ ! -f "$T/ready" ]] || break; sleep .02; done
cp "$CONF_DIR/site.conf" "$T/before"
mutate_bind() { site "$PORT2" blocked; }
expect_fail nx_transaction mutate_bind
cmp "$T/before" "$CONF_DIR/site.conf"
request "$PORT" stale
kill "$blocker" 2>/dev/null || true
wait "$blocker" 2>/dev/null || true
echo 'PASS: zero-exit reload with bind failure rejected; disk and live rollback retained'

# Deterministic no-op once lets rollback itself converge to a new generation.
printf noop-once > "$NX_TEST_MODE"
expect_fail nx_transaction mutate rejected
cmp "$T/before" "$CONF_DIR/site.conf"
request "$PORT" stale
# If both apply and rollback are unproven, the snapshot must remain available.
printf noop > "$NX_TEST_MODE"
expect_fail nx_transaction mutate retained
cmp "$T/before" "$CONF_DIR/site.conf"
request "$PORT" stale
backup="$(sed -n 's/.*备份保留在 \(\/tmp\/nginxx-transaction-[A-Za-z0-9]*\).*/\1/p' "$T/output" | tail -1)"
[[ -n "$backup" && -f "$backup/conf/site.conf" ]]
cmp "$T/before" "$backup/conf/site.conf"
rm -rf -- "$backup"
echo 'PASS: failed rollback retains recoverable snapshot and returns nonzero'
# Verify production pid discovery as well as explicit fixture pid injection.
printf real > "$NX_TEST_MODE"
NX_NGINX_PID_FILE='' reload_nginx_safe > "$T/output" 2>&1
# Successful listener migration proves kernel socket observation on a new port.
nx_transaction mutate_bind > "$T/output" 2>&1
request "$PORT2" blocked
echo 'PASS: stale reload rollback and real listener migration'

# A legal configuration with no TCP listener is still a successful reload;
# the generation record, not a non-empty listener set, proves activation.
"$BIN" -p "$T/" -c "$NGINX_MAIN_CONF" -s quit >/dev/null 2>&1
nx_test_wait_pidfile "$NX_NGINX_PID_FILE"
: > "$CONF_DIR/site.conf"
printf real > "$NX_TEST_MODE"
reload_nginx_safe
echo 'PASS: legal zero-TCP-listener configuration is accepted after new generation'
# The witness path remains valid until the running cycle is replaced; USR1
# must not encounter a deleted temporary directory after verification.
master=$(cat "$NX_NGINX_PID_FILE")
python3 - "$master" <<'PY'
import glob, os, signal, sys, time
pid=int(sys.argv[1]); logs=[]
for fd in glob.glob(f'/proc/{pid}/fd/*'):
    try: path=os.readlink(fd)
    except FileNotFoundError: continue
    if '/nginxx-generation-' in path:
        assert not path.endswith(' (deleted)'), path
        assert os.path.isfile(path), path
        logs.append(path)
assert logs, 'missing active generation evidence log'
os.kill(pid,signal.SIGUSR1)
time.sleep(.2)
assert all(os.path.isfile(p) for p in logs)
PY
# Recreate then disable the only managed site through the product transaction.
site "$PORT" final
printf '# managed_by=Nginx-X\n' | cat - "$CONF_DIR/site.conf" > "$T/site.new"
mv "$T/site.new" "$CONF_DIR/site.conf"
reload_nginx_safe > "$T/output" 2>&1
request "$PORT" final
disable_conf site.conf > "$T/output" 2>&1
[[ -f "$CONF_DIR/site.conf.bak" && ! -f "$CONF_DIR/site.conf" ]]
if curl --noproxy '*' -fsS --max-time 1 "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then exit 1; fi
echo 'PASS: generation log survives reopen and disabling the last site succeeds'
