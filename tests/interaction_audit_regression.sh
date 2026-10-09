#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2317,SC2034
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
root="$NX_TEST_ENV_ROOT"
bash tools/build-bundle.sh "$root/bundle"
fail=0
for entry in "$PWD/nx.sh" "$root/bundle"; do
 for scenario in modify-eof dns-key-eof dns-issue-failure health-missing dns-empty numeric-overflow access-cancel cert-cancel uninstall-cancel; do
  if bash -s -- "$entry" "$scenario" "$root" > "$root/$scenario.out" 2>&1 <<'SH'
source "$1"
scenario="$2"; root="$3"
SUDO=''
clear() { :; }
pause() { echo PAUSE; read -r _ || return 0; }
require_nginx_installed() { :; }
is_port_used_os() { return 1; }
require_template_rebuild_safe() { :; }
reload_nginx_safe() { echo MUTATED; }
apply_conf_with_rollback() { echo MUTATED; }
site="$CONF_DIR/example.com-18080.conf"
build_proxy_conf example.com 18080 3000 "$site" normal
case "$scenario" in
 modify-eof)
  run_menu_action modify_conf "${site##*/}" < /dev/null > "$root/result"
  ! grep -q MUTATED "$root/result" ;;
 dns-key-eof)
  save_dns_conf() { echo SAVED; }
  run_menu_action setup_dns_api <<< $'2\nid' > "$root/result"
  ! grep -q SAVED "$root/result" ;;
 dns-issue-failure)
  load_email() { ACME_EMAIL=test@example.com; }
  _issue_cert_dns() { echo ISSUE_FAILED; return 1; }
  cert_menu <<< $'4\nexample.com\n\n0' > "$root/result"
  grep -q ISSUE_FAILED "$root/result"
  [[ $(grep -c PAUSE "$root/result") == 1 ]] ;;
 health-missing)
  require_nginx_installed() { echo MISSING; return 1; }
  system_info_panel() { :; }
  realtime_info_menu <<< $'3\n\n0' > "$root/result"
  [[ $(grep -c PAUSE "$root/result") == 1 ]] ;;
 dns-empty)
  NX_RESOLV_CONF="$root/resolv"; printf '# no nameservers\n' > "$NX_RESOLV_CONF"
  dns_setup_menu <<< 0 > "$root/result" ;;
 numeric-overflow)
  config_manage_menu <<< $'18446744073709551617\n\n0' > "$root/result"
  ! grep -q '配置操作：' "$root/result" ;;
 cert-cancel)
  has_acme_cron_task() { return 1; }
  nx_acme_assert_unreferenced() { :; }
  cert_list_action_menu example.com <<< $'2\nn' > "$root/result"
  ! grep -q PAUSE "$root/result"
  cert_list_action_menu example.com <<< $'3\nn' > "$root/result"
  ! grep -q PAUSE "$root/result" ;;
 uninstall-cancel)
  nx_backend_uninstall_guard() { :; }
  uninstall_menu <<< $'1\nn\n0' > "$root/result"
  ! grep -q PAUSE "$root/result" ;;
 access-cancel)
  nx_backend_status() { echo '{"sites": {}}'; }
  config_file_action_menu "${site##*/}" <<< $'7\n1\nn\n6\n0\n0' > "$root/result"
  ! grep -q PAUSE "$root/result"
  grep -q '路径映射：' "$root/result" ;;
esac
SH
  then echo "PASS: $(basename "$entry") $scenario"
  else echo "FAIL: $(basename "$entry") $scenario"; cat "$root/$scenario.out"; fail=1
  fi
 done
done
exit "$fail"
