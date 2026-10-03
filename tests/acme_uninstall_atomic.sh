#!/usr/bin/env bash
# Test doubles are called indirectly by sourced lifecycle functions.
# shellcheck disable=SC2317
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/../nx.sh"
tmp="$(mktemp -d)"
trap 'nx_test_cleanup; rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
# shellcheck disable=SC2034
SUDO=''
SSL_DIR="$tmp/ssl"; CONF_DIR="$tmp/conf"; NGINX_MAIN_CONF="$tmp/nginx.conf"
# shellcheck disable=SC2034
DOMAIN_ONLY_STATE="$tmp/state"; EMAIL_CONF="$tmp/email"; DNS_CONF="$tmp/dns"
NX_PERIODIC_DIR="$tmp/periodic"
nx_acme_privileged_paths() { NX_ACME_DISPATCH="$tmp/dispatch"; NX_ACME_MANIFEST="$tmp/acme-current.domains"; }
# No service, package, system cron, or privileged file paths are touched.
crontab() { if [[ $1 == -l ]]; then cat "$tmp/cron"; else cat > "$tmp/cron"; fi; }
nx_acme_account_crontab() { if [[ $1 == -l ]]; then cat "$tmp/account-cron"; else cat > "$tmp/account-cron"; fi; }
nx_acme_check_account_identity() { :; }
reload_nginx_safe() {
  echo reload >> "$tmp/reloads"
  [[ ${FAIL_RELOAD:-0} != 1 ]] || return 1
}
ensure_websocket_map() { :; }
nx_access_migrate_state() { :; }
nx_access_sync_files() { :; }
setup() {
  rm -rf "$HOME" "$SSL_DIR" "$CONF_DIR" "$NX_PERIODIC_DIR"
  mkdir -p "$HOME/.acme.sh" "$SSL_DIR" "$CONF_DIR" "$NX_PERIODIC_DIR/daily"
  nx_acme_privileged_paths
  printf 'a.example\nb.example\n' > "$NX_ACME_MANIFEST"
  printf keep > "$NX_ACME_DISPATCH"
  printf secret > "$DNS_CONF"; chmod 600 "$DNS_CONF"
  printf email > "$EMAIL_CONF"
  printf 'events {}\nhttp { include %s/*.conf; }\n' "$CONF_DIR" > "$NGINX_MAIN_CONF"
  for domain in a.example b.example other.example; do
    mkdir -p "$SSL_DIR/$domain" "$HOME/.acme.sh/$domain"
    printf key > "$SSL_DIR/$domain/privkey.pem"; chmod 600 "$SSL_DIR/$domain/privkey.pem"
    printf cert > "$SSL_DIR/$domain/fullchain.pem"
    printf account > "$HOME/.acme.sh/$domain/$domain.conf"
  done
  cat > "$HOME/.acme.sh/acme.sh" <<'ACME'
#!/usr/bin/env bash
[[ ${FAIL_SECOND:-0} != 1 || $3 != b.example ]] || exit 1
printf changed > "$HOME/.acme.sh/account.conf"
ACME
  chmod 700 "$HOME/.acme.sh/acme.sh"
  printf original > "$HOME/.acme.sh/account.conf"
  printf '0 3 * * * %s cron\n0 4 * * * /other/.acme.sh/acme.sh --cron\n7 5 * * * backup\n' "$NX_ACME_DISPATCH" > "$tmp/cron"
  cp "$tmp/cron" "$tmp/original-cron"
  printf '0 2 * * * %s/.acme.sh/acme.sh --cron\n9 6 * * * account-backup\n' "$HOME" > "$tmp/account-cron"
  cp "$tmp/account-cron" "$tmp/original-account-cron"
  cp "$NX_ACME_MANIFEST" "$tmp/original-manifest"
  printf 'other.example\n' > "$tmp/acme-other.domains"
  printf '# original route\n' > "$CONF_DIR/route.conf"
  chmod 640 "$CONF_DIR/route.conf"
  printf '#!/bin/sh\n"%s/.acme.sh/acme.sh" --cron --home "%s/.acme.sh"\n' "$HOME" "$HOME" > "$NX_PERIODIC_DIR/daily/acme-renew"
  : > "$tmp/reloads"
}
assert_restored() {
  for domain in a.example b.example; do
    [[ $(cat "$SSL_DIR/$domain/privkey.pem") == key ]]
    [[ $(stat -c %a "$SSL_DIR/$domain/privkey.pem") == 600 ]]
    [[ -f "$HOME/.acme.sh/$domain/$domain.conf" ]]
  done
  [[ $(cat "$HOME/.acme.sh/account.conf") == original ]]
  [[ $(stat -c %a "$DNS_CONF") == 600 ]]
  [[ -f "$NX_PERIODIC_DIR/daily/acme-renew" && -f "$NX_ACME_DISPATCH" ]]
  cmp "$tmp/cron" "$tmp/original-cron"
  cmp "$tmp/account-cron" "$tmp/original-account-cron"
  cmp "$NX_ACME_MANIFEST" "$tmp/original-manifest"
  [[ $(cat "$tmp/acme-other.domains") == other.example ]]
  [[ $(cat "$SSL_DIR/other.example/privkey.pem") == key ]]
  [[ $(cat "$CONF_DIR/route.conf") == '# original route' ]]
  [[ $(stat -c %a "$CONF_DIR/route.conf") == 640 ]]
}
setup
# Last owned DNS certificate is used by a different site's alias. No mutation
# (including disabling schedules or invoking acme --remove) may precede refusal.
printf 'server { listen 443 ssl; server_name alias.example; ssl_certificate "%s/b.example/fullchain.pem"; ssl_certificate_key "%s/b.example/privkey.pem"; }\n' "$SSL_DIR" "$SSL_DIR" > "$CONF_DIR/alias.conf"
confirm() { return 0; }
if uninstall_acme_only; then exit 1; fi
assert_restored
if nx_delete_certificate b.example; then exit 1; fi
assert_restored
rm "$CONF_DIR/alias.conf"
# DNS-only single deletion must validate even with identical nginx config.
FAIL_RELOAD=1
if nx_delete_certificate a.example > "$tmp/failure" 2>&1; then exit 1; fi
[[ -s "$tmp/reloads" && -f "$SSL_DIR/a.example/fullchain.pem" ]]
assert_restored
backup=$(sed -n 's/.*备份保留：//p' "$tmp/failure" | tail -1)
[[ -d "$backup" ]]
rm -rf "$backup"
# DNS-only account removal changes no nginx config: validation must still run.
FAIL_RELOAD=1
if nx_acme_uninstall_account online > "$tmp/failure" 2>&1; then exit 1; fi
[[ -s "$tmp/reloads" ]]
assert_restored
backup=$(sed -n 's/.*备份保留：//p' "$tmp/failure" | tail -1)
[[ -d "$backup" ]]
rm -rf "$backup"
FAIL_RELOAD=0
# Failure on the second account operation restores the first plus global state.
export FAIL_SECOND=1
if nx_acme_uninstall_account online; then exit 1; fi
assert_restored
export FAIL_SECOND=0
# A manifest write which partially succeeds must roll back every deletion.
FAIL_RELOAD=0
saved_forget="$(declare -f nx_acme_forget_deployment)"
nx_acme_forget_deployment() { printf 'partial\n' > "$NX_ACME_MANIFEST"; return 1; }
if nx_delete_certificate a.example; then exit 1; fi
assert_restored
eval "$saved_forget"
# Exercise signals AFTER certificate bytes are deleted, during route rewriting.
saved_routes="$(declare -f nx_acme_sync_routes)"
for operation in single account; do
  for failure in return HUP INT TERM; do
    nx_acme_sync_routes() {
      printf 'partial route\n' > "$CONF_DIR/route.conf"
      rm -f "$CONF_DIR/.nx-acme-a.example.state"
      if [[ $failure == return ]]; then return 1; fi
      kill -s "$failure" "$BASHPID"
      return 1
    }
    touch "$CONF_DIR/.nx-acme-a.example.state"
    if [[ $operation == single ]]; then
      if nx_delete_certificate a.example; then exit 1; fi
    else
      if nx_acme_uninstall_account online; then exit 1; fi
    fi
    assert_restored
    [[ -f "$CONF_DIR/.nx-acme-a.example.state" ]]
  done
done
eval "$saved_routes"
# Missing account.conf must be restored as missing, not newly created by acme.
rm "$HOME/.acme.sh/account.conf"
nx_acme_forget_deployment() { return 1; }
if nx_delete_certificate a.example; then exit 1; fi
[[ ! -e "$HOME/.acme.sh/account.conf" ]]
eval "$saved_forget"
setup
# HTTP-01 cleanup after package removal must not even attempt nginx reload.
touch "$CONF_DIR/.nx-acme-a.example.state"
nx_acme_render_helper a.example > "$CONF_DIR/acme-challenge-a.example.conf"
: > "$tmp/reloads"
FAIL_RELOAD=1
# Exercise the actual all-uninstall entry: package removal is a safe stub.
uninstall_nginx_only() { touch "$tmp/package-removed"; }
check_cmd() { [[ $1 != nginx ]]; }
uninstall_script_only() { touch "$tmp/script-removed"; }
uninstall_all
[[ -f "$tmp/package-removed" && -f "$tmp/script-removed" ]]
[[ ! -s "$tmp/reloads" && ! -e "$HOME/.acme.sh" && ! -e "$SSL_DIR/a.example" ]]
[[ ! -e "$CONF_DIR/acme-challenge-a.example.conf" && ! -e "$CONF_DIR/.nx-acme-a.example.state" ]]
[[ -f "$SSL_DIR/other.example/privkey.pem" ]]
grep -q '/other/.acme.sh/acme.sh --cron' "$tmp/cron"
grep -q 'backup' "$tmp/cron"
grep -q 'account-backup' "$tmp/account-cron"
if grep -q 'acme.sh' "$tmp/account-cron"; then exit 1; fi
[[ ! -e "$NX_PERIODIC_DIR/daily/acme-renew" ]]
# A cancelled package phase must not enter offline cleanup.
rm "$tmp/script-removed"
check_cmd() { [[ $1 == nginx ]]; }
if uninstall_all; then exit 1; fi
[[ ! -e "$tmp/script-removed" ]]
echo 'ok: shared active references, DNS validation, whole-account rollback, explicit offline HTTP-01 cleanup'
