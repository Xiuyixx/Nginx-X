#!/usr/bin/env bash
# Migration and last-site removal regression for the old DOMAIN_ONLY state file.
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
source ./nx.sh
# ssl_reject_handshake first appeared in 1.19.4. Keep boundary mocks local
# to a subshell so later checks use the actual installed version.
(
 nginx_local_version() { echo "$gate_version"; }
 for gate_version in '' 1.18.0 '1.18.0 (Ubuntu)' 1.19.3 '1.19.3 (Ubuntu)'; do
  if nginx_supports_ssl_reject_handshake; then exit 1; fi
 done
 for gate_version in 1.19.4 '1.19.4 (Ubuntu)' 1.20.0 1.22.1; do
  nginx_supports_ssl_reject_handshake
 done
)
root="$(mktemp -d)"
trap 'nx_test_cleanup; rm -rf "$root"' EXIT
CONF_DIR="$root/conf"; STATE_DIR="$root/state"; DOMAIN_ONLY_STATE="$STATE_DIR/domain-only.conf"
# shellcheck disable=SC2034
SUDO=''
mkdir -p "$CONF_DIR" "$STATE_DIR"
reload_nginx_safe() { return 0; }
printf 'DOMAIN_ONLY=1\n' > "$DOMAIN_ONLY_STATE"
cat > "$CONF_DIR/site.conf" <<'SITE'
# managed_by=Nginx-X
server {
 listen 127.0.0.1:18088;
 listen [::1]:18088;
 server_name a.example;
 location / { return 200; }
}
SITE
domain_only_sync
grep -q '127.0.0.1:18088 default_server' "$(domain_only_conf_path)"
grep -q '\[::1\]:18088 default_server' "$(domain_only_conf_path)"
if grep -q '\[::\]:' "$(domain_only_conf_path)"; then exit 1; fi
grep -q nx-access-begin "$CONF_DIR/site.conf"
disable_conf site.conf
[[ ! -f "$(domain_only_conf_path)" ]]
[[ "$(cat "$DOMAIN_ONLY_STATE")" == DOMAIN_ONLY=1 ]]
enable_conf site.conf.bak
[[ -f "$(domain_only_conf_path)" ]]
confirm() { return 0; }
delete_conf site.conf
[[ ! -f "$(domain_only_conf_path)" ]]
# State is data, not shell code.
printf 'DOMAIN_ONLY=1\ntouch %s/unwanted\n' "$root" > "$DOMAIN_ONLY_STATE"
domain_only_state_is_enabled
[[ ! -e "$root/unwanted" ]]
echo 'ok: legacy migration and final listener cleanup'
# Parser leaves unquoted braced nginx variables intact.
cat > "$CONF_DIR/variable.conf" <<'SITE'
# managed_by=Nginx-X
server { listen 18089; server_name var.example; location / { proxy_set_header X-Test ${request_uri}; } }
SITE
nx_access_sync_files
# shellcheck disable=SC2016
grep -Fq '${request_uri}' "$CONF_DIR/variable.conf"
