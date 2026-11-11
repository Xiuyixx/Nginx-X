#!/usr/bin/env python3
"""Real PTYs: synchronize each field with Bash read, not pre-echoed input."""
import errno
import os
from pathlib import Path
import pty
import select
import signal
import sys
import termios
import time

entries, root = sys.argv[1:-1], Path(sys.argv[-1])
CASES = [
    ('1', [('Cloudflare API Token: ', 'pty-cf-token', True)]),
    ('2', [('DNSPod ID: ', 'pty-dp-id', False), ('DNSPod Key: ', 'pty-dp-secret', True)]),
    ('3', [('Aliyun AccessKey ID: ', 'pty-ali-id', False), ('Aliyun AccessKey Secret: ', 'pty-ali-secret', True)]),
    ('4', [('HE.net Username: ', 'pty-he-user', False), ('HE.net Password: ', 'pty-he-password', True)]),
    ('5', [('GoDaddy API Key: ', 'pty-gd-key', True), ('GoDaddy API Secret: ', 'pty-gd-secret', True)]),
    ('6', [('华为云 Username: ', 'pty-hw-user', False), ('华为云 Password: ', 'pty-hw-password', True)]),
    ('7', [('AWS Access Key ID: ', 'pty-aws-id', False), ('AWS Secret Access Key: ', 'pty-aws-secret', True)]),
    ('8', [('GCE Project: ', 'pty-gce-project', False), ('Service Account Email: ', 'pty-gce@example.com', False)]),
]
DRIVER = '''
source "$1"
STATE_DIR="$2"; DNS_CONF="$2/dns.conf"
mkdir -p "$STATE_DIR"
save_dns_conf cf old-token '' >/dev/null
rc=0
setup_dns_api || rc=$?
printf 'PTY_STATUS=%s\\n' "$rc"
# A post-menu ordinary read proves terminal echo restoration.
read -rp 'AFTER_MENU: ' after || true
'''


def run_case(entry, index, fields, mode='normal'):
    state = root / f'pty-{Path(entry).name}-{index}-{mode}'
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp('bash', ['bash', '-c', DRIVER, 'dns-pty', entry, str(state)])
    transcript = bytearray()
    reaped = False

    def receive_until(needle):
        deadline = time.monotonic() + 10
        target = needle.encode()
        while target not in transcript:
            assert time.monotonic() < deadline, f'timeout at {needle!r}: {transcript!r}'
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(fd, 65536)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        raise AssertionError(f'PTY exited at {needle!r}: {transcript!r}') from exc
                    raise
                assert chunk, (needle, transcript)
                transcript.extend(chunk)

    try:
        receive_until('请选择（1-8）: ')
        os.write(fd, (index + '\n').encode())
        for prompt, value, secret in fields:
            receive_until(prompt)
            # Read prompt is emitted after read has configured the terminal.
            echo = bool(termios.tcgetattr(fd)[3] & termios.ECHO)
            assert echo != secret, (entry, prompt, 'wrong terminal ECHO state')
            if mode == 'eof' and secret:
                os.write(fd, b'\x04')
                break
            if mode == 'interrupt' and secret:
                os.write(fd, b'partial-interrupted-secret')
                os.write(fd, b'\x03')
                break
            os.write(fd, (value + '\n').encode())
        if mode == 'interrupt':
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                done, status = os.waitpid(pid, os.WNOHANG)
                if done:
                    reaped = True
                    assert os.waitstatus_to_exitcode(status) in (-signal.SIGINT, 130), status
                    break
                ready, _, _ = select.select([fd], [], [], 0.1)
                if ready:
                    try:
                        transcript.extend(os.read(fd, 65536))
                    except OSError as exc:
                        if exc.errno != errno.EIO:
                            raise
            assert reaped, 'SIGINT did not stop read'
            assert b'partial-interrupted-secret' not in transcript
            assert termios.tcgetattr(fd)[3] & termios.ECHO, 'SIGINT left echo disabled'
        else:
            if mode == 'normal':
                receive_until('是否现在测试申请证书？ [y/N]: ')
                os.write(fd, b'n\n')
            receive_until('AFTER_MENU: ')
            assert termios.tcgetattr(fd)[3] & termios.ECHO, 'menu left echo disabled'
            os.write(fd, b'visible-after-menu\n')
            receive_until('visible-after-menu')
            _, status = os.waitpid(pid, 0)
            reaped = True
            assert os.waitstatus_to_exitcode(status) == 0, transcript
            expected = b'PTY_STATUS=10' if mode == 'eof' else b'PTY_STATUS=0'
            assert expected in transcript, transcript
            for _, value, secret in fields:
                if secret:
                    assert value.encode() not in transcript, f'secret echoed: {entry} {index}'
                elif mode == 'normal':
                    assert value.encode() in transcript, f'ordinary ID not echoed: {entry} {index}'
        conf = state / 'dns.conf'
        assert conf.stat().st_mode & 0o777 == 0o600
        if mode != 'normal':
            assert conf.read_text() == "DNS_PROVIDER=cf\nDNS_KEY1=old-token\nDNS_KEY2=''\n"
        else:
            for _, value, _ in fields:
                assert value in conf.read_text(), 'input not persisted'
        (state / 'transcript.txt').write_bytes(transcript)
    finally:
        if not reaped:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(fd)


for entry in entries:
    for index, fields in CASES:
        run_case(entry, index, fields)
    run_case(entry, '1', CASES[0][1], 'eof')
    run_case(entry, '1', CASES[0][1], 'interrupt')
    print(f'PASS: {Path(entry).name} real PTY: 8 providers, secrets hidden, IDs echoed, Ctrl-D/Ctrl-C restore echo and preserve old 0600 state')
