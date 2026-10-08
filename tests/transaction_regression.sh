#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/nx.sh"
T="$(mktemp -d)"
trap 'nx_test_cleanup; rm -rf "$T"' EXIT
CONF_DIR="$T/conf"
STATE_DIR="$T/state"
DOMAIN_ONLY_STATE="$STATE_DIR/domain-only.conf"
SSL_DIR="$T/ssl"
# Never snapshot or restore the runner's installed nginx.conf in this fixture.
NGINX_MAIN_CONF="$T/nginx.conf"
# shellcheck disable=SC2034
SUDO=""
mkdir -p "$CONF_DIR" "$STATE_DIR" "$SSL_DIR"
printf 0 > "$T/reloads"
fail_reload=0
fail_sync=0
reload_nginx_safe() { printf '%s\n' "$(( $(cat "$T/reloads") + 1 ))" > "$T/reloads"; (( fail_reload == 0 )); }
nx_access_sync_files() {
  printf '# derived\n' > "$CONF_DIR/00-nx-domain-only.conf"
  (( fail_sync == 0 ))
}
confirm() { return 0; }
cat > "$CONF_DIR/site.conf" <<'EOF'
# managed_by=Nginx-X
# domain=site.example
server {
 listen 18080;
 server_name site.example;
 location / { return 200 'unchanged'; }
}
EOF
cp "$CONF_DIR/site.conf" "$T/original"
printf 'DOMAIN_ONLY=1\n' > "$DOMAIN_ONLY_STATE"
printf '# original derived\n' > "$CONF_DIR/00-nx-domain-only.conf"
assert_restored() {
  cmp "$T/original" "$CONF_DIR/site.conf"
  [[ ! -e "$CONF_DIR/site.conf.bak" ]]
  [[ "$(cat "$CONF_DIR/00-nx-domain-only.conf")" == '# original derived' ]]
  [[ "$(cat "$DOMAIN_ONLY_STATE")" == 'DOMAIN_ONLY=1' ]]
}
fail_reload=1
for action in disable_conf delete_conf; do
  if "$action" site.conf >/dev/null 2>&1; then echo "$action hid reload failure" >&2; exit 1; fi
  assert_restored
done
run_editor() { printf '\n# edited\n' >> "$1"; }
if edit_conf_manual site.conf >/dev/null 2>&1; then exit 1; fi
assert_restored
cp "$T/original" "$T/new"
printf '\n# replacement\n' >> "$T/new"
if apply_conf_with_rollback "$T/new" "$CONF_DIR/new.conf" "$CONF_DIR/site.conf" >/dev/null 2>&1; then exit 1; fi
assert_restored
[[ ! -e "$CONF_DIR/new.conf" ]]
fail_reload=0
fail_sync=1
before="$(cat "$T/reloads")"
if disable_conf site.conf >/dev/null 2>&1; then echo 'sync error hidden' >&2; exit 1; fi
assert_restored
# Only rollback reload occurs; no new configuration is activated before sync.
[[ "$(cat "$T/reloads")" == "$((before+1))" ]]
fail_sync=0
disable_conf site.conf >/dev/null
fail_reload=1
if enable_conf site.conf.bak >/dev/null 2>&1; then exit 1; fi
[[ -f "$CONF_DIR/site.conf.bak" && ! -e "$CONF_DIR/site.conf" ]]
fail_reload=0
enable_conf site.conf.bak >/dev/null
apply_conf_with_rollback "$T/new" "$CONF_DIR/new.conf" "$CONF_DIR/site.conf" >/dev/null
[[ ! -e "$CONF_DIR/site.conf" && -f "$CONF_DIR/new.conf" ]]
[[ "$(stat -c '%a' "$CONF_DIR/new.conf")" == 644 ]]
# Existing destination must never be overwritten by a rename.
cp "$T/original" "$CONF_DIR/site.conf"
if apply_conf_with_rollback "$T/new" "$CONF_DIR/new.conf" "$CONF_DIR/site.conf" >/dev/null 2>&1; then exit 1; fi
cmp "$T/original" "$CONF_DIR/site.conf"
echo 'ok: transaction failures and rename rollback'
# A template modification must retain an explicit access policy.
printf '\n# access_policy=strict\n' >> "$CONF_DIR/site.conf"
apply_conf_with_rollback "$T/new" "$CONF_DIR/replaced.conf" "$CONF_DIR/site.conf" >/dev/null
grep -q '^# access_policy=strict$' "$CONF_DIR/replaced.conf"
# The interactive template editor must propagate failed apply and preserve a
# disabled source without briefly activating it during a successful edit.
cat > "$CONF_DIR/modify.example-18080.conf.bak" <<'SITE'
# managed_by=Nginx-X
# domain=modify.example
# listen_port=18080
# backend_port=3000
server {
 listen 18080;
 server_name modify.example;
 location / { proxy_pass http://127.0.0.1:3000; }
}
SITE
is_port_used_os() { return 1; }
ipv6_available() { return 1; }
cp "$CONF_DIR/modify.example-18080.conf.bak" "$T/modify-before"
fail_reload=1
if modify_conf modify.example-18080.conf.bak <<< $'\n\n\n' >/dev/null 2>&1; then echo 'modify hid reload failure' >&2; exit 1; fi
cmp "$T/modify-before" "$CONF_DIR/modify.example-18080.conf.bak"
fail_reload=0
modify_conf modify.example-18080.conf.bak <<< $'\n\n\n' >/dev/null
[[ -f "$CONF_DIR/modify.example-18080.conf.bak" && ! -e "$CONF_DIR/modify.example-18080.conf" ]]
echo 'ok: interactive modify failure propagation and disabled status'
# Builders only render. A missing WebSocket map is included in the same final
# apply; map and site both disappear on failure, with one rollback reload.
NGINX_MAIN_CONF="$T/nginx.conf"
printf 'events {}\nhttp {\n include %s/*.conf; # conf.d\n}\n' "$CONF_DIR" > "$NGINX_MAIN_CONF"
rm -f "$CONF_DIR/00-websocket-map.conf"
before="$(cat "$T/reloads")"
build_proxy_conf map.example 18099 3000 "$T/map-site"
[[ ! -e "$CONF_DIR/00-websocket-map.conf" ]]
[[ "$(cat "$T/reloads")" == "$before" ]]
apply_conf_with_rollback "$T/map-site" "$CONF_DIR/map.conf"
[[ -f "$CONF_DIR/00-websocket-map.conf" ]]
[[ "$(cat "$T/reloads")" == "$((before+1))" ]]
rm "$CONF_DIR/map.conf" "$CONF_DIR/00-websocket-map.conf"
fail_reload=1
if apply_conf_with_rollback "$T/map-site" "$CONF_DIR/map.conf"; then exit 1; fi
[[ ! -e "$CONF_DIR/map.conf" && ! -e "$CONF_DIR/00-websocket-map.conf" ]]
echo 'ok: render has no side effects, map and site share one transaction'
# Directory locking works without permission to create an adjacent lock file.
# The directory owner may mutate sites but cannot write the protected parent.
if [[ $(id -u) == 0 ]] && command -v runuser >/dev/null 2>&1; then
  mkdir "$T/protected"
  chmod 755 "$T" "$T/protected"
  mkdir "$T/protected/conf"
  chown nobody "$T/protected/conf"
  cat > "$T/lock-test" <<'LOCK'
set -euo pipefail
source "$1/nx.sh"
CONF_DIR="$2/protected/conf"
DOMAIN_ONLY_STATE="$CONF_DIR/.nx-access-state"
NGINX_MAIN_CONF="$2/protected/absent-main"
SUDO=''
nx_access_sync_files() { :; }
reload_nginx_safe() { :; }
nx_transaction touch "$CONF_DIR/owned"
LOCK
  chmod 644 "$T/lock-test"
  # Root home is normally private; copy the sources to an accessible fixture.
  mkdir "$T/source"
  cp "$ROOT/nx.sh" "$T/source/"
  cp -r "$ROOT/lib" "$T/source/"
  runuser -u nobody -- bash "$T/lock-test" "$T/source" "$T"
  [[ -f "$T/protected/conf/owned" && ! -e "$T/protected/conf.nx-lock" ]]
  echo 'ok: unprivileged caller locks directory beneath protected parent'
fi
