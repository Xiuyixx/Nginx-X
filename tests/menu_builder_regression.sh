#!/usr/bin/env bash
# shellcheck disable=SC2317 # functions are called through the real menu wrapper
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
source ./nx.sh
root="$(mktemp -d)"
trap 'nx_test_cleanup; rm -rf "$root"' EXIT
SUDO=""
CONF_DIR="$root/conf"; SSL_DIR="$root/ssl"; STATE_DIR="$root/state"
DOMAIN_ONLY_STATE="$root/policy"; NGINX_MAIN_CONF="$root/nginx.conf"
mkdir -p "$CONF_DIR" "$SSL_DIR" "$STATE_DIR"
require_nginx_installed() { :; }
is_port_used_os() { return 1; }
select_external_mode() { echo normal; }
confirm() { return 1; }
# A transaction must never be reached after failed rendering/allocation.
nx_transaction() { touch "$root/published"; return 0; }
fail() { echo "FAIL: $*" >&2; exit 1; }
run_menu_action add_external_url_proxy <<< $'example.com\n18080\nhttp://127.0.0.1:3000/#fragment' > "$root/output" 2>&1
[[ ! -e "$root/published" ]] || fail 'invalid external URL published'
! grep -q '配置已生效' "$root/output" || fail 'false success'
for action in add_reverse_proxy add_external_url_proxy; do
  (
    build_proxy_conf() { return 1; }
    build_external_proxy_conf() { return 1; }
    run_menu_action "$action" <<< $'example.com\n18080\nhttp://127.0.0.1:3000' > "$root/output" 2>&1
    if [[ "$action" == add_reverse_proxy ]]; then
      run_menu_action "$action" <<< $'example.com\n18080\n3000' > "$root/output" 2>&1
    fi
    [[ ! -e "$root/published" ]] || fail 'builder error published'
    ! grep -q '配置已生效' "$root/output" || fail 'builder false success'
  )
  (
    mktemp() { return 1; }
    build_proxy_conf() { touch "$root/rendered"; }
    build_external_proxy_conf() { touch "$root/rendered"; }
    if [[ "$action" == add_reverse_proxy ]]; then input=$'example.com\n18080\n3000'; else input=$'example.com\n18080\nhttp://127.0.0.1:3000'; fi
    run_menu_action "$action" <<< "$input" > "$root/output" 2>&1
    [[ ! -e "$root/rendered" && ! -e "$root/published" ]] || fail 'allocation failure continued'
  )
done
echo 'menu builder regression: PASS'
