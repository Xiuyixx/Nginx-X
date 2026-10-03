#!/usr/bin/env bash
# Safe lifecycle boundaries are mocked; policy/route/menu code is production.
# Values/functions are consumed by sourced production code; printf wrapper
# forwards its caller's format, and injection fixture is deliberately literal.
# shellcheck disable=SC2317,SC2034,SC2059,SC2016
set -euo pipefail
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
export HOME="$root/home" NX_CONF_DIR="$root/conf" SSL_DIR="$root/ssl"
export STATE_DIR="$root/state" NGINX_MAIN_CONF="$root/nginx.conf"
export DOMAIN_ONLY_STATE="$NX_CONF_DIR/.nx-access-state"
mkdir -p "$HOME" "$NX_CONF_DIR" "$SSL_DIR" "$STATE_DIR"
# shellcheck disable=SC1091
source "$(dirname "$0")/../nx.sh"
SUDO=''
NX_PERIODIC_DIR="$root/periodic"
nx_acme_privileged_paths() { NX_ACME_MANIFEST="$root/acme-current.domains"; NX_ACME_DISPATCH="$root/dispatch"; }
nx_acme_check_account_identity() { :; }
nx_acme_forget_deployment() { sed -i "/^$1$/d" "$NX_ACME_MANIFEST"; }
crontab() { if [[ $1 == -l ]]; then cat "$root/cron"; else cat > "$root/cron"; fi; }
nx_acme_account_crontab() { crontab "$@"; }
clear() { :; }
pause() { :; }
confirm() { return 0; }
reload_nginx_safe() {
  printf 'reload\n' >> "$root/reloads"
  # Online validation observes the regenerated policy, never intermediate loss.
  grep -q 'nx-access-begin' "$CONF_DIR/retained.conf" || return 1
  grep -q 'nx-access-default' "$CONF_DIR/retained.conf" || return 1
  [[ ${FAIL_RELOAD:-0} != 1 ]]
}
setup() {
  rm -rf "$HOME/.acme.sh" "$CONF_DIR" "$SSL_DIR"
  mkdir -p "$HOME/.acme.sh" "$CONF_DIR" "$SSL_DIR/deleted.example" "$SSL_DIR/retained.example"
  nx_acme_privileged_paths
  printf 'deleted.example\n' > "$NX_ACME_MANIFEST"
  printf 'retained.example\n' > "$root/acme-other.domains"
  printf cert > "$SSL_DIR/deleted.example/fullchain.pem"
  printf key > "$SSL_DIR/deleted.example/privkey.pem"
  chmod 600 "$SSL_DIR/deleted.example/privkey.pem"
  printf cert > "$SSL_DIR/retained.example/fullchain.pem"
  printf 'events {}\nhttp { include %s/*.conf; }\n' "$CONF_DIR" > "$NGINX_MAIN_CONF"
  cat > "$CONF_DIR/retained.conf" <<'CONF'
# managed_by=Nginx-X
server {
 listen 80;
 server_name retained.example;
 location / { return 200 retained; }
}
# access_policy=strict
# access_default=0.0.0.0:80
CONF
  touch "$CONF_DIR/.nx-acme-retained.example.state" "$CONF_DIR/.nx-acme-deleted.example.state"
  nx_acme_render_helper deleted.example > "$CONF_DIR/acme-challenge-deleted.example.conf"
  nx_access_sync_files
  : > "$root/reloads"; : > "$root/cron"
  FAIL_RELOAD=0
}
assert_policy() {
  grep -q 'nx-access-begin' "$CONF_DIR/retained.conf"
  grep -q 'nx-access-default' "$CONF_DIR/retained.conf"
  grep -q 'location \^~ /.well-known/acme-challenge/' "$CONF_DIR/retained.conf"
  [[ -s "$SSL_DIR/retained.example/fullchain.pem" ]]
  [[ $(cat "$root/acme-other.domains") == retained.example ]]
}
# True certificate action menu, wrapped in the production conditional caller.
# Disabled/backup/comment-only references do not block removal.
setup
for suffix in bak save; do
  printf 'server { listen 443 ssl; ssl_certificate "%s/deleted.example/fullchain.pem"; }\n' "$SSL_DIR" > "$CONF_DIR/disabled.conf.$suffix"
done
printf '# ssl_certificate %s/deleted.example/fullchain.pem;\n' "$SSL_DIR" > "$CONF_DIR/comment.conf"
run_menu_action cert_list_action_menu deleted.example <<< 3 > "$root/menu.log" 2>&1
[[ ! -e "$SSL_DIR/deleted.example" ]]
grep -q '证书已删除' "$root/menu.log"
assert_policy
# Explicitly included disabled files ARE active; final helper and menu agree.
setup
printf 'server { listen 443 ssl; ssl_certificate "%s/deleted.example/fullchain.pem"; }\n' "$SSL_DIR" > "$CONF_DIR/disabled.conf.bak"
printf '\ninclude %s/disabled.conf.bak;\n' "$CONF_DIR" >> "$NGINX_MAIN_CONF"
run_menu_action cert_list_action_menu deleted.example <<< 3 > "$root/menu.log" 2>&1
[[ -s "$SSL_DIR/deleted.example/fullchain.pem" && ! -s "$root/reloads" ]]
grep -q '活动引用检查未通过' "$root/menu.log"
# Both existing-lock callers reconcile retained strict/default routes, including
# offline removal (disk policy preserved, no service attempt).
for operation in single account; do
  for mode in online offline; do
    setup
    if [[ $operation == single ]]; then
      NX_ACME_UNINSTALL_MODE="$mode" nx_delete_certificate deleted.example
    else
      nx_acme_uninstall_account "$mode"
    fi
    [[ ! -e "$SSL_DIR/deleted.example" ]]
    assert_policy
    if [[ $mode == offline ]]; then [[ ! -s "$root/reloads" ]]; else [[ -s "$root/reloads" ]]; fi
  done
done
# Inject access synchronization failure AFTER its actual policy writes, plus
# reload failure: snapshots restore retained config and deleted key byte/mode.
saved_access="$(declare -f nx_access_sync_files)"
eval "${saved_access/nx_access_sync_files/review_access_original}"
for operation in single account; do
  for failure in access reload; do
    setup
    cp -a "$CONF_DIR" "$root/before-conf"
    if [[ $failure == access ]]; then
      nx_access_sync_files() { review_access_original || return 1; return 1; }
    else
      eval "$saved_access"
      FAIL_RELOAD=1
    fi
    if [[ $operation == single ]]; then
      run_menu_action cert_list_action_menu deleted.example <<< 3 > "$root/failure.log" 2>&1
    else
      run_menu_action nx_acme_uninstall_account online > "$root/failure.log" 2>&1
    fi
    [[ $(cat "$SSL_DIR/deleted.example/privkey.pem") == key ]]
    [[ $(stat -c %a "$SSL_DIR/deleted.example/privkey.pem") == 600 ]]
    diff -r "$root/before-conf" "$CONF_DIR"
    if grep -q '证书已删除' "$root/failure.log"; then exit 1; fi
    grep -q '操作未完成' "$root/failure.log"
    backup="$(sed -n 's/.*备份保留：//p' "$root/failure.log" | tail -1)"
    [[ -z $backup ]] || rm -rf "$backup"
    rm -rf "$root/before-conf"
    eval "$saved_access"
  done
done
# Certificate-specific locks must reject aliases before route transforms write.
for operation in single account; do
  setup
  ln "$CONF_DIR/retained.conf" "$root/external-alias"
  chmod 640 "$root/external-alias"
  cp -a "$root/external-alias" "$root/alias-before"
  if [[ $operation == single ]]; then
    if nx_delete_certificate deleted.example; then exit 1; fi
  else
    if nx_acme_uninstall_account online; then exit 1; fi
  fi
  cmp "$root/external-alias" "$root/alias-before"
  [[ $(stat -c %a "$root/external-alias") == 640 ]]
  [[ -s "$SSL_DIR/deleted.example/privkey.pem" && ! -s "$root/reloads" ]]
  rm -f "$root/external-alias" "$root/alias-before"
done
# DNS save under the same conditional wrapper: every stage must propagate
# failure and leave old credentials byte-for-byte, without exporting new keys.
ensure_state_original="$(declare -f ensure_state_dir)"
for failure in directory mktemp write chmod rename; do
  mkdir -p "$STATE_DIR"
  printf 'DNS_PROVIDER=cf\nDNS_KEY1=old\nDNS_KEY2=old2\n' > "$DNS_CONF"
  chmod 600 "$DNS_CONF"
  cp "$DNS_CONF" "$root/dns-before"
  (
    case "$failure" in
      directory) ensure_state_dir() { return 1; } ;;
      mktemp) mktemp() { return 1; } ;;
      write) printf() { [[ ${1:-} != 'DNS_KEY1=%q\n' ]] || return 1; builtin printf "$@"; } ;;
      chmod) chmod() { return 1; } ;;
      rename) mv() { return 1; } ;;
    esac
    export CF_Token=unchanged
    run_menu_action setup_dns_api <<< $'1\nnew-token' > "$root/dns-failure.log" 2>&1
    [[ $CF_Token == unchanged ]]
    cmp "$root/dns-before" "$DNS_CONF"
    [[ $(stat -c %a "$DNS_CONF") == 600 ]]
    if grep -q '配置已保存\|配置完成' "$root/dns-failure.log"; then exit 1; fi
    grep -q '操作未完成' "$root/dns-failure.log"
    [[ -z $(find "$STATE_DIR" -name '.dns.conf.*' -print) ]]
  )
done
eval "$ensure_state_original"
# Literal shell syntax survives round-trip, and missing custom parents fail.
key='quote '\'' $(touch SHOULD_NOT_EXIST) `literal` "double"'
save_dns_conf cf "$key" 'two'
load_dns_conf
[[ $DNS_KEY1 == "$key" && ! -e SHOULD_NOT_EXIST ]]
[[ $(stat -c %a "$DNS_CONF") == 600 ]]
DNS_CONF="$root/missing/dns.conf"
if save_dns_conf cf token ''; then exit 1; fi
[[ ! -e "$DNS_CONF" ]]
echo 'ok: certificate menu active references, cross-account strict/default online/offline sync, rollback, atomic DNS failures'
