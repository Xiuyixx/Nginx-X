#!/usr/bin/env bash
# shellcheck disable=SC2317
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
source ./nx.sh
root="$NX_TEST_ENV_ROOT"
SUDO=''
CONF_DIR="$NX_CONF_DIR"
require_nginx_installed() { :; }
is_port_used_os() { return 1; }
confirm() { return 1; }
reload_nginx_safe() {
 echo reload >> "$root/reloads"
 [[ "${FAIL_RELOAD:-0}" != 1 ]]
}
assert_stream() {
 [[ "$(grep -c 'proxy_buffering off;' "$1")" == 1 ]]
 [[ "$(grep -c 'proxy_cache off;' "$1")" == 1 ]]
 python3 - "$1" <<'PY'
import sys
s=open(sys.argv[1]).read()
assert s.index('location / {') < s.index('proxy_buffering off;')
assert not any(x in s for x in ['proxy_request_buffering','client_max_body_size'])
PY
}
# Exercise the real selector: scoped display, defaults, aliases and invalid input.
for item in '1 normal' '2 streaming' '6 streaming' '3 normal' '4 normal' '5 normal' 'invalid normal' '0 normal'; do
 read -r number mode <<< "$item"
 [[ "$(select_external_mode normal internal <<< "$number" 2> "$root/menu")" == "$mode" ]]
 grep -q '^2) 流式反代' "$root/menu"
 if grep -q '^6)\|Emby\|Jellyfin' "$root/menu"; then exit 1; fi
done
for item in 'normal normal' 'streaming streaming' 'media normal'; do
 read -r current mode <<< "$item"
 [[ "$(select_external_mode "$current" internal <<< '' 2>/dev/null)" == "$mode" ]]
done
for item in '1 normal' '2 media' '3 emby_http' '4 emby_https' '5 emby_lily' '6 streaming'; do
 read -r number mode <<< "$item"
 [[ "$(select_external_mode normal <<< "$number" 2> "$root/menu")" == "$mode" ]]
 [[ "$(select_external_mode "$mode" <<< '' 2>/dev/null)" == "$mode" ]]
 grep -q '^2) Stream 模式' "$root/menu"
 grep -q '^6) 流式反代' "$root/menu"
done
# read -p only prints its prompt on a terminal; assert the actual prompt via PTY.
python3 - <<'PYPTY'
import os, pty, select, subprocess
for scope, current, default, interval in [('internal','normal','1','1-2'), ('internal','streaming','2','1-2'), ('external','streaming','6','1-6')]:
    master, slave = pty.openpty()
    proc = subprocess.Popen(['bash','-c',f'source ./nx.sh; select_external_mode {current} {scope}'], stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    data = b''
    try:
        while b'(\xe9\xbb\x98\xe8\xae\xa4 ' not in data:
            assert select.select([master], [], [], 5)[0], 'prompt timeout'
            data += os.read(master, 4096)
        assert f'选择模式（{interval}） (默认 {default}): '.encode() in data, data
        os.write(master, b'\n')
        assert proc.wait(timeout=5) == 0
    finally:
        if proc.poll() is None:
            proc.kill(); proc.wait()
        os.close(master)
PYPTY
for kind in internal external; do
 rm -f "$CONF_DIR"/* "$root/reloads"
 if [[ "$kind" == internal ]]; then
  add_reverse_proxy <<< $'example.com\n18080\n3000\n2' > "$root/output" 2>&1
  field=proxy_mode
 else
  add_external_url_proxy <<< $'example.com\n18080\nhttps://127.0.0.1:3000/v1/\n6' > "$root/output" 2>&1
  field=external_mode
 fi
 conf="$CONF_DIR/example.com-18080.conf"
 assert_stream "$conf"
 [[ "$(conf_meta_get "$conf" "$field")" == streaming ]]
 [[ "$(wc -l < "$root/reloads")" == 1 ]]
 # Real editor: blank selection retains mode; backend/port changes remain atomic.
 if [[ "$kind" == internal ]]; then
  modify_conf "${conf##*/}" <<< $'\n18081\n3001\n' > "$root/output" 2>&1
 else
  modify_conf "${conf##*/}" <<< $'\n18081\nhttps://127.0.0.1:3001/v2/\n' > "$root/output" 2>&1
 fi
 conf="$CONF_DIR/example.com-18081.conf"
 assert_stream "$conf"
 [[ "$(conf_meta_get "$conf" "$field")" == streaming ]]
 [[ "$(wc -l < "$root/reloads")" == 2 ]]
 mkdir -p "$SSL_DIR/example.com"
 openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com -addext subjectAltName=DNS:example.com \
  -keyout "$SSL_DIR/example.com/privkey.pem" -out "$SSL_DIR/example.com/fullchain.pem" >/dev/null 2>&1
 enable_https_for_conf_file example.com "$conf" 18443 > "$root/output" 2>&1
 assert_stream "$conf"
 modify_conf "${conf##*/}" <<< $'\n18444\n\n' > "$root/output" 2>&1
 conf="$CONF_DIR/example.com-18444.conf"
 assert_stream "$conf"
 grep -q 'listen 18444 ssl' "$conf"
 disable_https_for_conf_file example.com "$conf" > "$root/output" 2>&1
 assert_stream "$conf"
 disable_conf "${conf##*/}" > "$root/output" 2>&1
 conf="$conf.bak"
 cp "$conf" "$root/before"
 FAIL_RELOAD=1 run_menu_action modify_conf "${conf##*/}" <<< $'\n\n\n1' > "$root/output" 2>&1
 cmp "$conf" "$root/before"
 grep -q '操作未完成' "$root/output"
 modify_conf "${conf##*/}" <<< $'\n\n\n1' > "$root/output" 2>&1
 conf="$(find "$CONF_DIR" -name 'example.com-*.conf.bak' -print)"
 if grep -q 'proxy_buffering off;\|proxy_cache off;' "$conf"; then exit 1; fi
 [[ "$(conf_meta_get "$conf" "$field")" == normal ]]
 if [[ "$kind" == internal ]]; then selection=2; else selection=6; fi
 modify_conf "${conf##*/}" <<< $'\n\n\n'"$selection" > "$root/output" 2>&1
 assert_stream "$conf"
 [[ "$(conf_meta_get "$conf" "$field")" == streaming ]]
 # Edited/custom config must never be blindly rebuilt.
 nx_conf_query metadata-set "$conf" edited true > "$root/edited"
 mv "$root/edited" "$conf"
 cp "$conf" "$root/before"
 run_menu_action modify_conf "${conf##*/}" <<< $'\n\n\n1' > "$root/output" 2>&1
 cmp "$conf" "$root/before"
 grep -q '已阻止' "$root/output"
done
# Legacy internal template without mode metadata defaults to standard.
rm -f "$CONF_DIR"/*
build_proxy_conf example.com 18080 3000 "$CONF_DIR/example.com-18080.conf"
sed -i '/^# proxy_mode=/d' "$CONF_DIR/example.com-18080.conf"
modify_conf example.com-18080.conf <<< $'\n\n\n' > "$root/output" 2>&1
[[ "$(conf_meta_get "$CONF_DIR/example.com-18080.conf" proxy_mode)" == normal ]]
echo 'stream proxy real menu lifecycle: PASS'
