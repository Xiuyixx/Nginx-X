#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
export NX_CONF_DIR="$T/conf" STATE_DIR="$T/admin-a" NGINX_MAIN_CONF="$T/nginx.conf"
mkdir -p "$NX_CONF_DIR" "$STATE_DIR" "$T/admin-b"
# shellcheck disable=SC1091
source "$ROOT/nx.sh"
SUDO=''
reload_nginx_safe() { echo reload >> "$T/reloads"; [[ ! -f "$T/fail" ]]; }
domain_only_warn_exposed_ports() { :; }
cat > "$CONF_DIR/site.conf" <<'SITE'
# managed_by=Nginx-X
server { listen 18080; server_name legacy.test; return 200; }
SITE
printf 'DOMAIN_ONLY=1\n' > "$STATE_DIR/domain-only.conf"
# Deployed guard, but root/admin-b has never had personal state.
nx_access_sync_files
STATE_DIR="$T/admin-b"
domain_only_sync
[[ "$DOMAIN_ONLY_STATE" == "$CONF_DIR/.nx-access-state" ]]
grep -qx DOMAIN_ONLY=1 "$DOMAIN_ONLY_STATE"
grep -q nx-access-begin "$CONF_DIR/site.conf"
STATE_DIR="$T/admin-a"
domain_only_disable
STATE_DIR="$T/admin-b"
domain_only_sync
if grep -q nx-access-begin "$CONF_DIR/site.conf"; then exit 1; fi
# State is never sourced, and malformed shared data blocks mutation.
# shellcheck disable=SC2016
printf 'DOMAIN_ONLY=$(touch %s/pwned)\n' "$T" > "$DOMAIN_ONLY_STATE"
if domain_only_sync >/dev/null 2>&1; then exit 1; fi
[[ ! -e "$T/pwned" ]]
printf 'DOMAIN_ONLY=0\n' > "$DOMAIN_ONLY_STATE"
# Main symlink and target both survive failed map injection.
printf 'events {}\nhttp {\n}\n' > "$T/main-target"
ln -s "$T/main-target" "$NGINX_MAIN_CONF"
cp "$T/main-target" "$T/before"
touch "$T/fail"
if ensure_websocket_map >/dev/null 2>&1; then exit 1; fi
[[ -L "$NGINX_MAIN_CONF" ]]
cmp "$T/main-target" "$T/before"
rm "$T/fail"
ensure_websocket_map >/dev/null
before="$(wc -l < "$T/reloads")"
ensure_websocket_map
ensure_websocket_map
domain_only_sync
[[ "$(wc -l < "$T/reloads")" == "$before" ]]
# Real mutation must still validate/reload once.
nx_access_set_policy "$CONF_DIR/site.conf" strict
[[ "$(wc -l < "$T/reloads")" == "$((before+1))" ]]
# Compact TLS and inheritance use the same structural parser as inspection.
printf 'server { listen 18443 ssl; server_name tls.test; ssl_certificate "a.pem"; ssl_certificate_key "b.pem"; }\n' > "$T/tls"
ensure_ssl_directives_present "$T/tls"
printf 'server { listen 18443 ssl; server_name tls.test; }\n' > "$T/tls"
if ensure_ssl_directives_present "$T/tls" >/dev/null 2>&1; then exit 1; fi
printf 'events {} http { ssl_certificate "a.pem"; ssl_certificate_key "b.pem"; }\n' > "$T/main-target"
ensure_ssl_directives_present "$T/tls"
# Batch list uses one Python process for all 50 sites.
rm "$CONF_DIR/site.conf"
for i in {1..50}; do
  printf '# managed_by=Nginx-X\nserver { listen %s; server_name site%s.test; return 200; }\n' "$((18000+i))" "$i" > "$CONF_DIR/site$i.conf"
done
python3() { echo python >> "$T/parsers"; command python3 "$@"; }
start=$SECONDS
print_conf_list > "$T/list"
[[ "$(wc -l < "$T/parsers")" == 1 ]]
[[ "$(grep -c 'site[0-9]*.test' "$T/list")" == 50 ]]
printf 'PASS: shared policy, migration, symlink rollback, no-op, compact TLS; 50-site list %ss, one parser\n' "$((SECONDS-start))"
# Lifecycle integration runs before site removal and shares its rollback.
nx_acme_before_site_remove() {
  [[ -f "$1" ]] || return 1
  printf '# challenge helper\n' > "$CONF_DIR/acme-challenge-test.conf"
  [[ ! -f "$T/hook-fail" ]]
}
touch "$T/hook-fail"
if disable_conf site1.conf >/dev/null 2>&1; then exit 1; fi
[[ -f "$CONF_DIR/site1.conf" && ! -e "$CONF_DIR/acme-challenge-test.conf" ]]
rm "$T/hook-fail"
disable_conf site1.conf >/dev/null
[[ -f "$CONF_DIR/site1.conf.bak" && -f "$CONF_DIR/acme-challenge-test.conf" ]]
confirm() { return 0; }
delete_conf site2.conf >/dev/null
[[ ! -f "$CONF_DIR/site2.conf" ]]
echo 'PASS: challenge lifecycle hook runs before removal and rolls back on failure'
