#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034,SC2317
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "$0")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
root="$NX_TEST_ENV_ROOT"
bash tools/build-bundle.sh "$root/bundle"
for entry in "$PWD/nx.sh" "$root/bundle"; do
 (
 source "$entry"
 SUDO=''
 require_nginx_installed() { :; }
 reload_nginx_safe() { echo reload >> "$root/reloads"; }
 is_port_used_os() { return 1; }
 ipv6_available() { return 1; }
 for kind in internal external; do
  for action in update delete rename replace; do
   rm -f "$CONF_DIR"/* "$root/reloads"
   site="$CONF_DIR/cas.example-18080.conf"
   if [[ "$kind" == internal ]]; then
    build_proxy_conf cas.example 18080 3000 "$site" streaming
   else
    build_external_proxy_conf cas.example 18080 http://127.0.0.1:3000 streaming "$site"
   fi
   chmod 640 "$site"
   # Another writer acts while the first wizard is collecting its input.
   select_external_mode() {
    case "$action" in
     update) sed 's/3000/4000/g' "$site" > "$root/new"; apply_conf_with_rollback "$root/new" "$site" "$site" >/dev/null ;;
     delete) nx_transaction nx_remove_conf "$site" >/dev/null ;;
     rename) nx_transaction nx_move_conf "$site" "$site.bak" >/dev/null ;;
     replace) cp -a "$site" "$root/new"; mv "$root/new" "$site" ;;
    esac
    cp -a "$CONF_DIR" "$root/expected"
    : > "$root/reloads"
    echo streaming
   }
   if modify_conf "${site##*/}" <<< $'\n\n\n' > "$root/out" 2>&1; then
    echo "stale $kind/$action committed"; exit 1
   fi
   grep -q '冲突' "$root/out"
   diff -r "$root/expected" "$CONF_DIR"
   [[ ! -s "$root/reloads" ]]
   rm -rf "$root/expected"
  done
  rm -f "$CONF_DIR"/*
  if [[ "$kind" == internal ]]; then
   build_proxy_conf cas.example 18080 3000 "$site" streaming
  else
   build_external_proxy_conf cas.example 18080 http://127.0.0.1:3000 streaming "$site"
  fi
  chmod 640 "$site"
  select_external_mode() { echo streaming; }
  modify_conf "${site##*/}" <<< $'\n\n\n' > "$root/out" 2>&1
  [[ $(stat -c %a "$site") == 640 ]]
  grep -q 'client_max_body_size 64m;' "$site"
  cp "$site" "$root/before"
  if modify_conf "${site##*/}" < /dev/null > "$root/out" 2>&1; then exit 1; fi
  cmp "$site" "$root/before"
 done
 )
done
echo 'PASS: source/bundle internal/external wizard CAS rejects update/delete/rename/replacement without reload; success and EOF preserved'
