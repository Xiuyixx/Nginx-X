#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317
# Configuration action 8 uses an explicit HTTPS submenu without bypassing the
# existing certificate, transform, CAS, or rollback implementation.
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
root="$NX_TEST_ENV_ROOT"
for entry in "$PWD/nx.sh" "$root/bundle"; do
  [[ "$entry" == "$PWD/nx.sh" ]] || bash tools/build-bundle.sh "$entry"
  (
    source "$entry"
    SUDO=''
    clear() { :; }
    require_nginx_installed() { :; }
    pause() { echo PAUSE; read -r _ || :; }
    site="$CONF_DIR/example.com-18080.conf"
    build_proxy_conf example.com 18080 3000 "$site" normal

    # 8 -> submenu -> 0 returns to the parent, whose next input is consumed.
    config_manage_menu <<< $'1\n8\n0\n6\n0\n0\n0' > "$root/out"
    grep -q 'HTTPS 状态：已关闭' "$root/out"
    grep -q '1) 开启 HTTPS' "$root/out"
    grep -q '2) 关闭 HTTPS' "$root/out"
    [[ $(grep -c '^PAUSE$' "$root/out") == 0 ]]
    grep -q '路径映射：' "$root/out"

    # Invalid input is safe and has exactly one result pause.
    config_file_action_menu "${site##*/}" <<< $'8\n9\n' > "$root/out"
    grep -q '无效输入' "$root/out"
    [[ $(grep -c '^PAUSE$' "$root/out") == 1 ]]

    # Repeating the current state is explicitly idempotent and pauses once.
    config_file_action_menu "${site##*/}" <<< $'8\n2\n' > "$root/out"
    grep -q 'HTTPS 已关闭，无需重复操作' "$root/out"
    [[ $(grep -c '^PAUSE$' "$root/out") == 1 ]]

    # Real certificate and transformation roundtrip; only reload is simulated.
    mkdir -p "$SSL_DIR/example.com"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com \
      -addext subjectAltName=DNS:example.com -keyout "$SSL_DIR/example.com/privkey.pem" \
      -out "$SSL_DIR/example.com/fullchain.pem" >/dev/null 2>&1
    reload_nginx_safe() { echo reload >> "$root/reloads"; }
    rm -f "$root/reloads"
    config_file_action_menu "${site##*/}" <<< $'8\n1\n\n8\n1\n\n8\n0\n0' > "$root/out"
    conf_https_enabled "$site"
    grep -q 'HTTPS 状态：已开启' "$root/out"
    grep -q 'HTTPS 已开启，无需重复操作' "$root/out"
    [[ $(grep -c '^PAUSE$' "$root/out") == 2 ]]
    [[ $(wc -l < "$root/reloads") == 1 ]]
    config_file_action_menu "${site##*/}" <<< $'8\n2\n\n0' > "$root/out"
    if conf_https_enabled "$site"; then echo 'FAIL: HTTPS remained enabled' >&2; exit 1; fi
    [[ $(grep -c '^PAUSE$' "$root/out") == 1 ]]
    cp -a "$site" "$root/before"
    attributes="$(stat -c '%u:%g:%a' "$site")"
    reload_nginx_safe() { echo reload >> "$root/reloads"; return 1; }
    config_file_action_menu "${site##*/}" <<< $'8\n1\n\n6\n0\n0' > "$root/out" 2>&1
    cmp "$site" "$root/before"
    [[ "$(stat -c '%u:%g:%a' "$site")" == "$attributes" ]]
    grep -q '操作未完成' "$root/out"
    grep -q '路径映射：' "$root/out"
    [[ $(grep -c '^PAUSE$' "$root/out") == 1 ]]
    # Missing certificate -> email EOF must return without attempting issuance.
    rm -rf "$SSL_DIR/example.com"
    config_file_action_menu "${site##*/}" <<< $'8\n1' > "$root/out"
    [[ $(grep -c '^PAUSE$' "$root/out") == 0 ]]
    cmp "$site" "$root/before"

    # Enable/disable dispatch keeps the existing core helpers and one pause.
    nx_site_https_enable() { echo enable >> "$root/dispatch"; }
    nx_site_https_disable() { echo disable >> "$root/dispatch"; }
    : > "$root/dispatch"
    config_file_action_menu "${site##*/}" <<< $'8\n1\n' > "$root/out"
    [[ $(cat "$root/dispatch") == enable ]]
    [[ $(grep -c '^PAUSE$' "$root/out") == 1 ]]
    config_file_action_menu "${site##*/}" <<< $'8\n2\n' > "$root/out"
    [[ $(cat "$root/dispatch") == $'enable\ndisable' ]]
    [[ $(grep -c '^PAUSE$' "$root/out") == 1 ]]

    # EOF and 0 return without a pause or parent input consumption.
    config_file_action_menu "${site##*/}" < /dev/null > "$root/out"
    [[ $(grep -c '^PAUSE$' "$root/out") == 0 ]]
    config_file_action_menu "${site##*/}" <<< 8 > "$root/out"
    [[ $(grep -c '^PAUSE$' "$root/out") == 0 ]]
    run_menu_action_paused nx_site_https_menu "$site" <<< 0 > "$root/out"
    [[ $(grep -c '^PAUSE$' "$root/out") == 0 ]]
  )
done
echo 'PASS: HTTPS submenu source/bundle status, navigation, idempotence, failure input and EOF'
