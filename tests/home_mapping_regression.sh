#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016,SC2218,SC1091
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
source ./nx.sh
root="$NX_TEST_ENV_ROOT"
SUDO=''
export NX_BACKEND_STATE_DIR="$root/backend" NX_BACKEND_UNIT_DIR="$root/units" NX_BACKEND_LIBEXEC_DIR="$root/libexec"
ipv6_available() { return 1; }
reload_nginx_safe() { echo reload >> "$root/reloads"; }
is_port_used_os() { return 1; }
site="$CONF_DIR/example.com-18080.conf"
build_proxy_conf example.com 18080 3000 "$site"
chmod 640 "$site"
attributes="$(stat -c '%u:%g:%a' "$site")"
for path in /management.html /admin/index.html /a_b-1/file.txt /admin/; do nx_home_validate_path "$path"; done
for path in / '' //evil.example/a /a//b /./a /../a /a/.. /%2e%2e /%252f /a?x=y /a#f 'https://evil/a' '/$host' '/a;return 200;' '/a{b}' '/a\\b' '/a"b' '/a b' $'/a\nb' '/a&b' '/a+b'; do
 if nx_home_validate_path "$path" >/dev/null 2>&1; then echo "unsafe path: $path"; exit 1; fi
done
nx_home_menu "$site" <<< $'1\n/management.html'
[[ "$(nx_home_status "$site")" == /management.html ]]
[[ "$(grep -c 'location = /' "$site")" == 1 ]]
[[ "$(stat -c '%u:%g:%a' "$site")" == "$attributes" ]]
cp "$site" "$root/mapped"
count="$(wc -l < "$root/reloads")"
nx_home_set "$site" /management.html
cmp "$site" "$root/mapped"
[[ "$(wc -l < "$root/reloads")" == "$count" ]]
nx_home_menu "$site" <<< 0
cmp "$site" "$root/mapped"
nx_home_set "$site" /admin.html
[[ "$(nx_home_status "$site")" == /admin.html ]]
# Production modify rebuild, preserving mapping/mode and actual path identity.
modify_conf "$(basename "$site")" <<< $'\n\n3001\n'
[[ "$(nx_home_status "$site")" == /admin.html ]]
grep -q 'proxy_pass http://127.0.0.1:3001;' "$site"
[[ "$(stat -c '%u:%g:%a' "$site")" == "$attributes" ]]
disable_conf "$(basename "$site")"
[[ "$(nx_home_status "$site.bak")" == /admin.html ]]
modify_conf "$(basename "$site").bak" <<< $'renamed.example\n18081\n\n\n'
site="$CONF_DIR/renamed.example-18081.conf"
[[ ! -e "$site" && "$(nx_home_status "$site.bak")" == /admin.html ]]
enable_conf "$(basename "$site").bak"
[[ "$(nx_home_status "$site")" == /admin.html ]]
nx_home_menu "$site" <<< 2
[[ -z "$(nx_home_status "$site")" ]]
if grep -q nx-home-map "$site"; then exit 1; fi
cp "$site" "$root/unmapped"
count="$(wc -l < "$root/reloads")"
nx_home_set "$site" ''
cmp "$site" "$root/unmapped"
[[ "$(wc -l < "$root/reloads")" == "$count" ]]
# Manual exact root locations (including compact/quoted forms) never overwritten.
for rule in 'location = / { rewrite ^ /management.html last; }' 'location = "/" { return 200; }' 'include hidden.conf;' 'rewrite ^ / last;' 'error_page 404 /;' 'location /api { rewrite ^ / last; }'; do
 cp "$root/unmapped" "$site"
 sed -i "/server_name /a\    $rule" "$site"
 cp "$site" "$root/conflict"
 if nx_home_set "$site" /management.html >/dev/null 2>&1; then echo "unsafe routing: $rule"; exit 1; fi
 cmp "$site" "$root/conflict"
done
cp "$root/unmapped" "$site"
nx_home_set "$site" /management.html
# Metadata without its owned block must not be silently erased or adopted.
cp "$root/unmapped" "$site"
printf '\n# nx_home_path=/management.html\n' >> "$site"
cp "$site" "$root/mismatch"
for operation in home-set home-strip home-status; do
 if nx_conf_query "$operation" "$site" '' > /dev/null 2>&1; then exit 1; fi
 cmp "$site" "$root/mismatch"
done
# A custom server if mentioning Host still cannot hide a rewrite/redirect.
cp "$root/unmapped" "$site"
sed -i '/server_name /a\    if ($host = example.com) { rewrite ^ / last; }' "$site"
cp "$site" "$root/custom-if"
if nx_home_set "$site" /management.html >/dev/null 2>&1; then exit 1; fi
cmp "$site" "$root/custom-if"
# Multiple business servers are ambiguous and remain byte-for-byte untouched.
cp "$root/unmapped" "$site"
cat "$root/unmapped" >> "$site"
cp "$site" "$root/multiple"
if nx_home_set "$site" /management.html >/dev/null 2>&1; then exit 1; fi
cmp "$site" "$root/multiple"
cp "$root/unmapped" "$site"
nx_home_set "$site" /management.html
# Changed managed block is never erased, even by disable.
sed -i '/rewrite \^ \/management.html/a\        add_header X-Custom keep;' "$site"
cp "$site" "$root/custom"
if nx_home_set "$site" '' >/dev/null 2>&1; then exit 1; fi
cmp "$site" "$root/custom"
cp "$root/unmapped" "$site"
nx_home_set "$site" /management.html
cp "$site" "$root/before-failure"
# Real menu conditional wrapper: failure remains visible, rollback byte exact.
reload_nginx_safe() { return 1; }
run_menu_action nx_home_set "$site" /other.html > "$root/failure" 2>&1
cmp "$site" "$root/before-failure"
grep -q '操作未完成' "$root/failure"
[[ "$(stat -c '%u:%g:%a' "$site")" == "$attributes" ]]
# Menu dispatch and the installed bundle use the same function and numbering.
clear() { :; }
pause() { :; }
nx_home_menu() { echo home >> "$root/dispatch"; }
nx_site_https_toggle() { echo tls >> "$root/dispatch"; }
health_check_conf_file() { echo health >> "$root/dispatch"; }
config_file_action_menu "$(basename "$site")" <<< $'7\n8\n9\n0' > "$root/menu"
[[ "$(cat "$root/dispatch")" == $'home\ntls\nhealth' ]]
grep -q '7) 首页路径映射' "$root/menu"
grep -q '8) HTTPS 开关' "$root/menu"
grep -q '9) 站点健康检查' "$root/menu"
bash tools/build-bundle.sh "$root/bundle"
source "$root/bundle"
reload_nginx_safe() { :; }
nx_home_set "$site" /bundle.html
[[ "$(nx_home_status "$site")" == /bundle.html ]]
echo 'PASS: homepage validation, lifecycle rebuild/rename/enable, ownership, idempotence, conflicts, menu, bundle and rollback'
