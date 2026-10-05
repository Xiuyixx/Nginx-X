#!/usr/bin/env bash
set -euo pipefail
# Deterministic PTY proof for the interactive updater.  The Python harness keeps
# the updater blocked at its explicit read, then releases it with Enter.
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
import os, pty, select, subprocess, sys, time
root = os.environ['ROOT']
env = os.environ.copy()
env.update(SOURCE=root + '/source', TARGET_BIN=root + '/bin/nx', MARKER=root + '/executed',
          PATH=root + ':' + env['PATH'])
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
            f.write("printf '#!/bin/bash\\nprintf EXECUTED > \"$MARKER\"\\nprintf EXECUTED\\n' > \"$TARGET_BIN\"\n")
            f.write('chmod 0755 "$TARGET_BIN"\n')
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
        assert '按回车重启，其他输入取消:'.encode() not in data
    else:
        read_until('按回车重启，其他输入取消:'.encode())
        assert not os.path.exists(marker), 'exec occurred before input'
        # Prompt is emitted immediately before the blocking read; the kernel
        # PTY canonical input queue is empty. No sleep/timing guess is used.
        if mode == 'cancel': os.write(fd, b'no\n')
        elif mode == 'eof': os.write(fd, b'\x04')
        elif mode == 'execfail':
            os.chmod(target, 0o644)
            os.write(fd, b'\n')
        else: os.write(fd, b'\n')
        read_until(b'EXECUTED' if mode == 'enter' else b'RETURNED:')
    _, status = os.waitpid(pid, 0)
    os.close(fd)
    expected = 1 if mode in ('failure', 'execfail') else 0
    assert os.waitstatus_to_exitcode(status) == expected, (mode, status, data)
    assert os.path.exists(marker) == (mode == 'enter'), (mode, data)
    if mode == 'execfail': assert '重启新版本失败'.encode() in data
for mode in ('enter', 'cancel', 'eof', 'execfail', 'failure', 'unchanged'):
    scenario(mode)
# Also exercise the production-generated standalone bundle helper on a PTY.
subprocess.run(['bash', 'tools/build-bundle.sh', root + '/bundle'], check=True)
scenario('enter', root + '/bundle')

PY

# Non-interactive success must return without exec or blocking.
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
echo 'ok: interactive update waits for Enter; non-interactive and failed updates do not exec'
