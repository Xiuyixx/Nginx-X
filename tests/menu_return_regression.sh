#!/usr/bin/env bash
# Real menus and parsers, only external effects/probes are isolated.
# shellcheck disable=SC2317,SC1090,SC2034,SC1091
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
root="$NX_TEST_ENV_ROOT"
bash tools/build-bundle.sh "$root/bundle"
for entry in "$PWD/nx.sh" "$root/bundle"; do
 (
 source "$entry"
 SUDO=''
 HOME="$root/home"; mkdir -p "$HOME/.acme.sh"
 cat > "$HOME/.acme.sh/acme.sh" <<'ACME'
#!/bin/sh
printf 'Main_Domain\nexample.com\n'
ACME
 chmod +x "$HOME/.acme.sh/acme.sh"
 clear() { :; }
 require_nginx_installed() { :; }
 has_acme_cron_task() { return 1; }
 nx_backend_status() { echo '{"sites": {}}'; }
 system_info_panel() { echo PANEL; }
 nx_stub_status() { return 1; }
 pause() { echo PAUSE; read -r _ || return 0; }
 reload_nginx_safe() { echo reload >> "$root/reloads"; }
 site="$CONF_DIR/example.com-18080.conf"
 build_proxy_conf example.com 18080 3000 "$site" normal
 cp "$site" "$root/original"
 # Back and the very next selection must reach the real parent, no blank line.
 config_manage_menu <<< $'1\n7\n0\n6\n0\n0\n0' > "$root/out"
 if grep -q PAUSE "$root/out"; then exit 1; fi
 grep -q '路径映射：' "$root/out"
 config_manage_menu <<< $'1\n7\n3\n4\n0\n0\n0\n6\n0\n0\n0' > "$root/out"
 [[ $(grep -c '高级设置（' "$root/out") == 2 ]]
 [[ $(grep -c '仅域名访问：' "$root/out") == 2 ]]
 grep -q '路径映射：' "$root/out"
 if grep -q PAUSE "$root/out"; then exit 1; fi
 cmp "$site" "$root/original"; [[ ! -e "$root/reloads" ]]
 # Real mapping mutation with simulated reload, then a real validation failure.
 config_file_action_menu "${site##*/}" <<< $'6\n1\n/admin.html\n\n6\n1\n/../bad\n\n7\n0\n0' > "$root/out" 2>&1
 [[ $(grep -c PAUSE "$root/out") == 2 ]]
 grep -q '路径映射已设置' "$root/out"
 grep -q '操作未完成' "$root/out"
 [[ $(wc -l < "$root/reloads") == 2 ]] # failed transaction also reloads its rollback
 [[ $(nx_home_status "$site") == /admin.html ]]
 rm "$root/reloads"
 cert_menu <<< $'6\n0\n5\n1\n0\n0\n0' > "$root/out"
 grep -q '证书操作：example.com' "$root/out"
 if grep -q PAUSE "$root/out"; then exit 1; fi
 cert_menu <<< $'6\n1\nn\n5\n0\n0' > "$root/out"
 grep -q '已取消启用 HTTPS' "$root/out"
 grep -q '证书列表' "$root/out"
 if grep -q PAUSE "$root/out"; then exit 1; fi
 realtime_info_menu <<< $'3\n2\n0\n0\n0' > "$root/out"
 if grep -q PAUSE "$root/out"; then exit 1; fi
 uninstall_menu <<< 0 > "$root/out"; if grep -q PAUSE "$root/out"; then exit 1; fi
 config_entry_menu <<< $'3\n0\n5\n0\n0' > "$root/out"
 if grep -q PAUSE "$root/out"; then exit 1; fi
 # Certificate action failures retain one result pause and do not exit set -e.
 enable_acme_cron() { error 'fixture renewal failure'; return 1; }
 nx_acme_assert_unreferenced() { :; }
 nx_delete_certificate() { error 'fixture delete failure'; return 1; }
 cert_list_action_menu example.com <<< $'2\n1\ny\n\n0' > "$root/out"
 [[ $(grep -c '^PAUSE$' "$root/out") == 1 ]]
 grep -q '操作未完成' "$root/out"
 cert_list_action_menu example.com <<< $'3\ny\n' > "$root/out"
 [[ $(grep -c '^PAUSE$' "$root/out") == 1 ]]
 grep -q '操作未完成' "$root/out"
 # EOF at all looping navigation levels, including wrapped conditional context.
 for menu in config_manage_menu cert_menu cert_list_menu site_health_menu realtime_info_menu uninstall_menu dns_setup_menu; do
   "$menu" < /dev/null > "$root/out"
 done
 cert_list_action_menu example.com < /dev/null > "$root/out"
 run_menu_action_paused nx_site_access_menu "$site" < /dev/null > "$root/out"
 if grep -q PAUSE "$root/out"; then exit 1; fi
 show_nginx_realtime_status < /dev/null > "$root/out"
 show_traffic_stats < /dev/null > "$root/out"
 echo "PASS: $(basename "$entry") real menu returns, actions, errors and EOF"
 )
done
# PTY: use the production pause/read, not the stream instrumentation above.
python3 - "$PWD/nx.sh" "$root/bundle" <<'PY'
import os, pty, select, subprocess, sys, time
for entry in sys.argv[1:]:
    master, slave = pty.openpty()
    script = r'''
source "$1"
clear() { :; }
require_nginx_installed() { :; }
nx_backend_status() { echo '{"sites": {}}'; }
config_manage_menu
printf 'RETURNED\n'
'''
    proc = subprocess.Popen(['bash', '-c', script, 'test', entry],
                            stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    output = b''
    def until(text):
        global output
        deadline = time.monotonic() + 12
        while text.encode() not in output:
            if time.monotonic() > deadline:
                raise AssertionError(('PTY timeout', text, output.decode(errors='replace')))
            if select.select([master], [], [], .1)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    chunk = b''
                if not chunk:
                    raise AssertionError(('PTY closed', output))
                output += chunk
        before, output = output.split(text.encode(), 1)
        assert '按回车继续'.encode() not in before, before
    try:
        until('请选择配置序号: ')
        os.write(master, b'1\n')
        until('请选择: ')
        os.write(master, b'7\n')
        until('请选择: ')
        os.write(master, b'3\n')
        until('请选择: ')
        os.write(master, b'0\n')
        until('请选择: ')
        os.write(master, b'0\n')
        until('请选择: ')
        os.write(master, b'6\n')
        until('请选择: ')
        os.write(master, b'0\n')
        until('请选择: ')
        os.write(master, b'0\n')
        until('请选择配置序号: ')
        os.write(master, b'0\n')
        until('RETURNED')
        assert proc.wait(timeout=5) == 0
        print('PASS: PTY real pause and nested parent selection:', os.path.basename(entry))
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        os.close(master)
PY

# Actual timed reads: timeout refreshes, a key returns, EOF never spins.
python3 - "$PWD/nx.sh" "$root/bundle" <<'PYREFRESH'
import os, pty, select, subprocess, sys, time
for entry in sys.argv[1:]:
    for menu in ('show_nginx_realtime_status', 'show_traffic_stats'):
        master, slave = pty.openpty()
        script = r'''source "$1"
clear() { :; }
require_nginx_installed() { :; }
nx_stub_status() { return 1; }
"$2"
printf 'RETURNED\n'
'''
        proc = subprocess.Popen(['bash', '-c', script, 'test', entry, menu],
                                stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        output = b''
        try:
            deadline = time.monotonic() + 20
            while output.count('每5秒自动刷新'.encode()) < 2:
                assert time.monotonic() < deadline, output.decode(errors='replace')
                if select.select([master], [], [], .1)[0]:
                    output += os.read(master, 65536)
            os.write(master, b'\n')
            assert proc.wait(timeout=5) == 0
            print('PASS: PTY timeout refresh and key return:', os.path.basename(entry), menu)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            os.close(master)
PYREFRESH
