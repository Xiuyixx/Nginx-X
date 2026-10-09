#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2317,SC2034
set -euo pipefail
source "$(dirname "$0")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
source ./nx.sh
SUDO=''
root="$NX_TEST_ENV_ROOT"
export NX_BACKEND_STATE_DIR="$root/backend"
reload_nginx_safe() { :; }
ipv6_available() { return 1; }
site="$CONF_DIR/cas.example.conf"
for action in modify delete rename replace; do
 build_proxy_conf cas.example 18080 3000 "$site"
 chmod 640 "$site"
 run_editor() {
  [[ $(stat -c %a "$1") == 600 ]]
  case "$action" in
   modify) sed 's/3000/4000/g' "$site" > "$root/new"; apply_conf_with_rollback "$root/new" "$site" "$site" ;;
   delete) nx_transaction nx_remove_conf "$site" ;;
   rename) nx_transaction nx_move_conf "$site" "$site.bak" ;;
   replace) cp -a "$site" "$root/replaced"; mv "$root/replaced" "$site" ;;
  esac
  cp -a "$CONF_DIR" "$root/expected"
  printf '\n# user edit\n' >> "$1"
 }
 if edit_conf_manual cas.example.conf > "$root/result" 2>&1; then echo "FAIL: stale $action committed"; exit 1; fi
 diff -r "$root/expected" "$CONF_DIR"
 grep -q '冲突' "$root/result"
 retained=$(grep -oE '/tmp/nginxx-edit-[A-Za-z0-9]+/edit.conf' "$root/result" | tail -1)
 [[ -f "$retained" && $(stat -c %a "$retained") == 600 && $(stat -c %a "$(dirname "$retained")") == 700 ]]
 grep -q '# user edit' "$retained"
 rm -rf "$(dirname "$retained")" "$root/expected"
 rm -f "$site.bak"
done
run_editor() { printf '\n# success\n' >> "$1"; }
edit_conf_manual cas.example.conf
grep -q '# success' "$site"
[[ $(stat -c %a "$site") == 640 ]]
run_editor() { chmod 644 "$1"; return 1; }
if edit_conf_manual cas.example.conf > "$root/failed-editor" 2>&1; then exit 1; fi
retained=$(grep -oE '/tmp/nginxx-edit-[A-Za-z0-9]+/edit.conf' "$root/failed-editor" | tail -1)
[[ $(stat -c %a "$retained") == 600 ]]
rm -rf "$(dirname "$retained")"
# A no-op HTTPS transform must not report success after concurrent change.
build_proxy_conf cas.example 18080 3000 "$site"
nx_https_transform() { cat "$2"; printf '\n# concurrent HTTPS edit\n' >> "$site"; }
if nx_https_apply disable cas.example "$site" > "$root/noop" 2>&1; then exit 1; fi
grep -q '冲突' "$root/noop"
grep -q 'concurrent HTTPS edit' "$site"
echo 'PASS: editor CAS rejects content/delete/rename/inode replacement and preserves private edits'
