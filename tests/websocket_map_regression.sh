#!/usr/bin/env bash
# Nginx variable literals and dynamic fixture globals are intentional.
# shellcheck disable=SC2016,SC2034
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090,SC1091
source "${NX_TEST_SOURCE:-$ROOT/nx.sh}"
SUDO=""
# Isolate disk preparation; never call host service managers.
NX_IN_TRANSACTION=1
nx_write_conf() { install -m 0644 "$1" "$2"; }
failed=0
check() { if "$@"; then echo "ok: $case_name"; else echo "FAIL: $case_name" >&2; failed=$((failed+1)); fi; }
reset_case() { rm -rf "${CONF_DIR:?}"/*; mkdir -p "$CONF_DIR"; }
needs_map() {
  ensure_websocket_map >/dev/null || return 1
  grep -q '^    map \$http_upgrade \$connection_upgrade {' "$NGINX_MAIN_CONF"
}
for case_name in comment quoted other-target compact; do
  reset_case
  case "$case_name" in
    comment) printf '# map $http_upgrade $connection_upgrade { ignored }\nevents{}\nhttp { }\n' > "$NGINX_MAIN_CONF" ;;
    quoted) printf 'events{}\nhttp { log_format fake "map $http_upgrade $connection_upgrade { fake }"; }\n' > "$NGINX_MAIN_CONF" ;;
    other-target) printf 'events{}\nhttp { map $http_upgrade $other { default close; } }\n' > "$NGINX_MAIN_CONF" ;;
    compact) printf 'events{}http{server{listen 18080;}}\n' > "$NGINX_MAIN_CONF" ;;
  esac
  check needs_map
done
case_name=nested-include-custom-map
reset_case
mkdir -p "$NX_TEST_ENV_ROOT/includes"
printf 'events{}http{include includes/first.conf;}\n' > "$NGINX_MAIN_CONF"
printf 'include includes/second.conf;\n' > "$NX_TEST_ENV_ROOT/includes/first.conf"
printf 'map "$http_upgrade" $connection_upgrade { default custom; "" close; }\n' > "$NX_TEST_ENV_ROOT/includes/second.conf"
cp "$NGINX_MAIN_CONF" "$NX_TEST_ENV_ROOT/before"
custom_preserved() { ensure_websocket_map >/dev/null && cmp -s "$NGINX_MAIN_CONF" "$NX_TEST_ENV_ROOT/before" && [[ ! -e "$CONF_DIR/00-websocket-map.conf" ]]; }
check custom_preserved
case_name=actual-http-include
reset_case
printf 'events{}http{include "%s/*.conf";}\n' "$CONF_DIR" > "$NGINX_MAIN_CONF"
file_created() { ensure_websocket_map >/dev/null && [[ -s "$CONF_DIR/00-websocket-map.conf" ]]; }
check file_created
case_name=root-only-include
reset_case
printf 'include "%s/*.conf";events{}http{}\n' "$CONF_DIR" > "$NGINX_MAIN_CONF"
check needs_map
case_name=server-include-not-http
reset_case
printf 'events{}http{server{include "%s/*.conf";}}\n' "$CONF_DIR" > "$NGINX_MAIN_CONF"
check needs_map
case_name=custom-map-no-transaction
reset_case
printf 'events{}http{map $http_upgrade $connection_upgrade{default custom;}}\n' > "$NGINX_MAIN_CONF"
cp "$NGINX_MAIN_CONF" "$NX_TEST_ENV_ROOT/before"
NX_IN_TRANSACTION=0
nx_transaction() { echo unexpected-transaction >&2; return 1; }
check custom_preserved
NX_IN_TRANSACTION=1
case_name=include-cycle-fails-closed
reset_case
printf 'events{}http{include nginx.conf;}\n' > "$NGINX_MAIN_CONF"
cp "$NGINX_MAIN_CONF" "$NX_TEST_ENV_ROOT/before"
fails_unchanged() { ! ensure_websocket_map >/dev/null 2>&1 && cmp -s "$NGINX_MAIN_CONF" "$NX_TEST_ENV_ROOT/before"; }
check fails_unchanged
case_name=existing-map-file-is-not-proof
reset_case
printf 'events{}http{include "%s/*.conf";}\n' "$CONF_DIR" > "$NGINX_MAIN_CONF"
printf '# map $http_upgrade $connection_upgrade is just a comment\n' > "$CONF_DIR/00-websocket-map.conf"
check needs_map
case_name=unrelated-map-source-collision
reset_case
printf 'events{}http{map $host $connection_upgrade{default close;}}\n' > "$NGINX_MAIN_CONF"
cp "$NGINX_MAIN_CONF" "$NX_TEST_ENV_ROOT/before"
check fails_unchanged
[[ "$failed" == 0 ]]
