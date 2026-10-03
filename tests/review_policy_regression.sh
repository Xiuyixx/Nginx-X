#!/usr/bin/env bash
# Real transaction + conditional menu wrappers, with all disk paths isolated.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export NX_CONF_DIR="$T/conf" STATE_DIR="$T/state" SSL_DIR="$T/ssl"
export NGINX_MAIN_CONF="$T/nginx.conf" DOMAIN_ONLY_STATE="$T/conf/.nx-access-state"
mkdir -p "$NX_CONF_DIR" "$STATE_DIR" "$SSL_DIR"
# shellcheck disable=SC1091
source "$ROOT/nx.sh"
SUDO=''
for path in "$CONF_DIR" "$STATE_DIR" "$SSL_DIR" "$NGINX_MAIN_CONF" "$DOMAIN_ONLY_STATE"; do [[ "$path" == "$T/"* ]]; done
printf 'DOMAIN_ONLY=0\n' > "$DOMAIN_ONLY_STATE"
printf 0 > "$T/reloads"
fail_reload=0
reload_nginx_safe() { echo "$(( $(cat "$T/reloads") + 1 ))" > "$T/reloads"; (( fail_reload == 0 )); }
warn() { printf '%s\n' "$*" >> "$T/warnings"; }
site="$CONF_DIR/site.conf"
make_site() {
  printf '# managed_by=Nginx-X\nserver { %s server_name a.test; return 200; }\n' "$1" > "$site"
  [[ -z "${2:-}" ]] || printf '# access_default=%s\n' "$2" >> "$site"
}
apply_listens() {
  printf '# managed_by=Nginx-X\nserver { %s server_name a.test; return 200; }\n' "$1" > "$T/new"
  apply_conf_with_rollback "$T/new" "$site" "$site"
}
make_site 'listen 127.0.0.1:18080; listen [::1]:18080;' '127.0.0.1:18080'
apply_listens 'listen [::1]:18080; listen 127.0.0.1:18080;'
[[ "$(conf_meta_get "$site" access_default)" == '127.0.0.1:18080' ]]
grep -q '127.0.0.1:18080 default_server' "$site"
if grep -q '\[::1\]:18080 default_server' "$site"; then exit 1; fi
apply_listens 'listen [::1]:18081; listen 127.0.0.1:18081;'
[[ "$(conf_meta_get "$site" access_default)" == '127.0.0.1:18081' ]]
# Surviving exact socket wins over a newly introduced same-address socket.
apply_listens 'listen 127.0.0.1:18082; listen 127.0.0.1:18081; listen [::1]:18081;'
[[ "$(conf_meta_get "$site" access_default)" == '127.0.0.1:18081' ]]
cp -a "$site" "$T/before"
if apply_listens 'listen 127.0.0.1:18083; listen 127.0.0.1:18084; listen [::1]:18081;'; then echo 'ambiguous migration accepted' >&2; exit 1; fi
cmp "$site" "$T/before"
# Listener removal cannot jump to another address/family.
apply_listens 'listen [::1]:18081;'
[[ -z "$(conf_meta_get "$site" access_default)" ]]
# Duplicate policy metadata fails with mutations already made: true rollback.
make_site 'listen 18080;' '0.0.0.0:18080'
printf '# access_default=0.0.0.0:18081\n' >> "$site"
cp -a "$site" "$T/before"
mutate() { printf 'callback\n' > "$CONF_DIR/callback"; }
if nx_transaction mutate; then echo 'duplicate metadata accepted' >&2; exit 1; fi
cmp "$site" "$T/before"
[[ ! -e "$CONF_DIR/callback" ]]
# run_menu_action intentionally consumes status; its warning is the observable
# failure signal. Nested setters/parsers must still fail and preserve bytes.
: > "$T/warnings"
run_menu_action nx_site_access_menu "$site" <<< 2
[[ -s "$T/warnings" ]]
cmp "$site" "$T/before"
: > "$T/warnings"
run_menu_action nx_default_site_menu "$site" <<< c
[[ -s "$T/warnings" ]]
cmp "$site" "$T/before"
# Existing owner/mode survive a successful preservative policy write and a
# service failure rollback through the actual site menu conditional.
make_site 'listen 18080;'
chmod 640 "$site"
owner="$(stat -c '%u:%g' "$site")"
nx_access_set_policy "$site" strict
[[ "$(stat -c '%a:%u:%g' "$site")" == "640:$owner" ]]
cp -a "$site" "$T/before"
fail_reload=1
: > "$T/warnings"
run_menu_action nx_site_access_menu "$site" <<< 2
[[ -s "$T/warnings" ]]
cmp "$site" "$T/before"
[[ "$(stat -c '%a:%u:%g' "$site")" == "640:$owner" ]]
fail_reload=0
# Reject hardlinks before callback, including hidden/disabled config files,
# primary nginx.conf, symlink-resolved primary targets, and shared state.
for kind in site disabled hidden main main_symlink state; do
  make_site 'listen 18080;'
  printf 'events {}\nhttp {}\n' > "$T/external"
  chmod 640 "$T/external"
  cp -a "$T/external" "$T/external-before"
  case "$kind" in
    site) rm "$site"; ln "$T/external" "$site"; linked="$site" ;;
    disabled) linked="$CONF_DIR/disabled.conf.bak"; ln "$T/external" "$linked" ;;
    hidden) linked="$CONF_DIR/.derived"; ln "$T/external" "$linked" ;;
    main) linked="$NGINX_MAIN_CONF"; ln "$T/external" "$linked" ;;
    main_symlink) linked="$T/main-target"; ln "$T/external" "$linked"; ln -s "$linked" "$NGINX_MAIN_CONF" ;;
    state) rm "$DOMAIN_ONLY_STATE"; linked="$DOMAIN_ONLY_STATE"; ln "$T/external" "$linked" ;;
  esac
  before_reloads="$(cat "$T/reloads")"
  if nx_transaction mutate; then echo "hardlink $kind accepted" >&2; exit 1; fi
  cmp "$T/external" "$T/external-before"
  [[ "$(stat -c '%a' "$T/external")" == 640 && ! -e "$CONF_DIR/callback" ]]
  [[ "$(cat "$T/reloads")" == "$before_reloads" ]]
  rm -f "$linked" "$NGINX_MAIN_CONF" "$site"
  printf 'DOMAIN_ONLY=0\n' > "$DOMAIN_ONLY_STATE"
done
echo 'ok: socket identity migration, parser/menu rollback, hardlink boundaries and owner/mode'
