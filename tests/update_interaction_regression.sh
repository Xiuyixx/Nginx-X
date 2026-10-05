#!/usr/bin/env bash
set -euo pipefail
# Deterministic PTY proof for the interactive updater.  The Python harness keeps
# publication blocked on a FIFO, then validates automatic foreground exec.
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
root="$(mktemp -d)"
trap 'nx_test_cleanup; rm -rf "$root"' EXIT
mkdir -p "$root/source/.git" "$root/bin"
cp nx.sh "$root/source/nx.sh"
cp -R lib "$root/source/lib"
cat > "$root/source/install.sh" <<'INSTALL'
#!/usr/bin/env bash
set -eu
printf '#!/usr/bin/env bash\nprintf EXECUTED > "$MARKER"\nprintf EXECUTED\n' > "$TARGET_BIN"
chmod 0755 "$TARGET_BIN"
INSTALL
chmod +x "$root/source/install.sh"
cat > "$root/git" <<'GIT'
#!/usr/bin/env bash
case "$*" in
  *'remote get-url'*) printf '%s\n' 'https://github.com/Xiuyixx/Nginx-X.git' ;;
  *'pull'*) : ;;
  *) exit 1 ;;
esac
GIT
chmod +x "$root/git"
printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/nx"
chmod +x "$root/bin/nx"

# The driver sources the product (so main is never entered), then calls only the
# update helper.  MARKER is written exclusively by the replacement executable.
cat > "$root/driver.sh" <<'DRIVER'
#!/usr/bin/env bash
set -u
source "${ENTRY:-$SOURCE/nx.sh}"
NX_RUNNING_SOURCE="$TARGET_BIN"
NX_INSTALLED_TARGET="$TARGET_BIN"
NX_INSTALLED_REPO="$SOURCE"
REPO_INSTALL_DIR="$SOURCE"
SUDO=""
NX_IN_MENU=1
MARKER="$MARKER"
if update_script; then rc=0; else rc=$?; fi
printf "RETURNED:%s\n" "$rc"
exit "$rc"
DRIVER
chmod +x "$root/driver.sh"

ROOT="$root" python3 - <<'PY'
import os, pty, select, subprocess, sys, time, re, pathlib, fcntl, signal
root = os.environ['ROOT']
env = os.environ.copy()
env.update(SOURCE=root + '/source', TARGET_BIN=root + '/bin/nx', MARKER=root + '/executed',
          PATH=root + ':' + env['PATH'], GATE=root + '/gate')
os.mkfifo(root + '/gate')
def scenario(mode, entry=None):
    marker = root + '/executed'
    if os.path.exists(marker): os.unlink(marker)
    target = root + '/bin/nx'
    with open(target, 'w') as f: f.write('#!/bin/sh\nexit 0\n')
    os.chmod(target, 0o755)
    installer = root + '/source/install.sh'
    with open(installer, 'w') as f:
        f.write('#!/bin/bash\nset -eu\n')
        if mode == 'failure': f.write('exit 42\n')
        elif mode == 'unchanged': f.write('exit 0\n')
        else:
            # FIFO gate makes signal/close tests deterministic, no timing guess.
            f.write('read -r _ < "$GATE"\n')
            f.write("cat > \"$TARGET_BIN\" <<'NEW'\n#!/bin/bash\nprintf PUBLISHED > \"$MARKER\"\nprintf 'NEW_INPUT:\\n'\nread -r value || exit 0\nprintf 'INPUT:%s\\n' \"$value\"\nNEW\n")
            f.write('chmod ' + ('0644' if mode == 'execfail' else '0755') + ' "$TARGET_BIN"\n')
    child_env = env.copy()
    if entry: child_env['ENTRY'] = entry
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(root + '/driver.sh', [root + '/driver.sh'], child_env)
    data = b''
    def read_until(needle, timeout=10):
        nonlocal data
        end = time.monotonic() + timeout
        while needle not in data and time.monotonic() < end:
            ready, _, _ = select.select([fd], [], [], max(0, end-time.monotonic()))
            if ready:
                try: data += os.read(fd, 4096)
                except OSError: break
        if needle not in data:
            os.kill(pid, 9)
            os.waitpid(pid, 0)
            raise SystemExit(mode + ': missing expected output: ' + repr(data[-800:]))
    if mode in ('failure', 'unchanged'):
        read_until(b'RETURNED:')
    else:
        read_until('更新助手已启动'.encode())
        if mode == 'interrupt': os.write(fd, b'\x03')
        if mode == 'disconnect':
            os.close(fd)
        if mode == 'concurrent':
            other = subprocess.run([root + '/driver.sh'], env=child_env, stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
            assert other.returncode != 0 and '更新锁失败'.encode() in other.stdout + other.stderr
        gate = os.open(root + '/gate', os.O_WRONLY)
        os.write(gate, b'go\n'); os.close(gate)
        if mode == 'disconnect':
            os.waitpid(pid, 0)
            # Worker status and published marker are evidence after tty loss.
            end = time.monotonic() + 10
            while 'NEW_INPUT' not in open(target).read() and time.monotonic() < end:
                time.sleep(.02)
            assert 'NEW_INPUT' in open(target).read(), 'detached publication did not finish'
            job = re.search(rb'/tmp/nginxx-update-[A-Za-z0-9]+', data).group().decode()
            status_file = pathlib.Path(job) / 'status'
            while not status_file.exists() and time.monotonic() < end: time.sleep(.02)
            assert status_file.read_text().strip() == '0'
            assert not os.path.exists(marker), 'offline menu executed'
            lock = os.open(target + '.update.lock', os.O_RDWR)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB); os.close(lock)
            return
        read_until(b'RETURNED:' if mode == 'execfail' else b'NEW_INPUT:')
        if mode != 'execfail':
            os.write(fd, b'hello\n')
            read_until(b'INPUT:hello')
    _, status = os.waitpid(pid, 0)
    os.close(fd)
    expected = 126 if mode == 'execfail' else (1 if mode == 'failure' else 0)
    assert os.waitstatus_to_exitcode(status) == expected, (mode, status, data)
    assert os.path.exists(marker) == (mode in ('enter', 'interrupt', 'concurrent')), (mode, data)
    if mode == 'execfail': assert '重启新版本失败'.encode() in data
# Main EOF must terminate even in a conditional (errexit suppressed).
eof = subprocess.run(['bash', '-c', 'source "$SOURCE/nx.sh"; ensure_runtime_dependencies(){ :; }; ensure_dirs(){ :; }; ensure_websocket_map(){ :; }; nx_migrate_certificate_renewal(){ :; }; banner(){ :; }; if main; then :; fi'], env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=5)
assert eof.returncode == 0 and eof.stdout.count(b'5)') == 1
for mode in ('enter', 'interrupt', 'concurrent', 'disconnect', 'execfail', 'failure', 'unchanged'):
    scenario(mode)
# Also exercise the production-generated standalone bundle helper on a PTY.
subprocess.run(['bash', 'tools/build-bundle.sh', root + '/bundle'], check=True)
scenario('enter', root + '/bundle')

PY

# Non-interactive success must return without exec or blocking.
cat > "$root/source/install.sh" <<'INSTALL'
#!/bin/bash
printf "#!/bin/bash\nexit 0\n" > "$TARGET_BIN"
chmod +x "$TARGET_BIN"
INSTALL
rm -f "$root/executed"
MARKER="$root/executed" SOURCE="$root/source" TARGET_BIN="$root/bin/nx" \
  PATH="$root:$PATH" bash "$root/driver.sh" </dev/null >/dev/null
[[ ! -e "$root/executed" ]] || { echo 'non-interactive updater unexpectedly execed' >&2; exit 1; }

# A failed publication must not reach the restart prompt or replacement.
cat > "$root/source/install.sh" <<'FAIL'
#!/usr/bin/env bash
exit 42
FAIL
chmod +x "$root/source/install.sh"
if MARKER="$root/executed" SOURCE="$root/source" TARGET_BIN="$root/bin/nx" \
  PATH="$root:$PATH" bash "$root/driver.sh" </dev/null >/dev/null 2>&1; then
  echo 'failed update unexpectedly succeeded' >&2
  exit 1
fi
[[ ! -e "$root/executed" ]] || { echo 'failed update execed replacement' >&2; exit 1; }
echo 'ok: interactive detached update automatically execs; non-interactive and failed updates do not exec'
