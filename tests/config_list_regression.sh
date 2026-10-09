#!/usr/bin/env bash
# shellcheck disable=SC2317 # menu callbacks
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'nx_test_cleanup; rm -rf "$T"' EXIT
bash "$ROOT/tools/build-bundle.sh" "$T/nx"
for entry in "$ROOT/nx.sh" "$T/nx"; do
 (
  # shellcheck disable=SC1090
  source "$entry"
  # shellcheck disable=SC2034
  SUDO=''
  rm -f "$CONF_DIR"/* "$DOMAIN_ONLY_STATE" "$STATE_DIR/domain-only.conf"
  site() { printf '# managed_by=Nginx-X\n%s\n' "$2" > "$CONF_DIR/$1"; }
  site a.conf '# access_policy=strict
server { listen [::]:443 ssl; listen 0.0.0.0:443 ssl; listen 80; listen [::]:80; server_name x.xiuyi17.dpdns.org; }'
  site b.conf.bak '# access_policy=open
server { listen 8080; server_name example.com; }'
  print_conf_list > "$T/list"
  cat > "$T/expected" <<'EXPECTED'
可管理配置列表：
  1) [启用] x.xiuyi17.dpdns.org
     HTTPS | 端口 80/443 | 仅域名访问

  2) [停用] example.com
     HTTP | 端口 8080 | 不限域名
EXPECTED
  diff -u "$T/expected" "$T/list"
  site c.conf '# access_policy=inherit
server { listen 10000; listen localhost:90; listen "[::1]:90"; server_name example.com; }'
  site d.conf 'server { listen 8081; }'
  site e.conf 'server { listen unix:/tmp/list.sock; server_name unix.test; }'
  site f.conf 'server { listen 81; listen unix:/tmp/list.sock ssl; server_name mixed.test; }'
  site g.conf 'server { listen nonsense; server_name invalid.test; }'
  site h.conf 'server {'
  site i.conf '# access_policy=
server { listen 8082; server_name empty.test; }'
  site j.conf 'server { server_name no-listen.test; }'
  site k.conf 'server { listen 8083; server_name ""; }'
  site l.conf '# access_policy=strict
# access_policy=open
server { listen 8084; server_name duplicate-policy.test; }'
  for inherited in 0 1 invalid; do
    printf 'DOMAIN_ONLY=%s\n' "$inherited" > "$DOMAIN_ONLY_STATE"
    print_conf_list > "$T/list" 2> "$T/errors"
    case "$inherited" in 0) effective=不限域名 ;; 1) effective=仅域名访问 ;; *) effective=域名限制未知 ;; esac
    grep -Fxq "     HTTP | 端口 90/10000 | $effective" "$T/list"
    grep -Fxq '  3) [启用] 未知域名' "$T/list"
    grep -Fxq '  4) [启用] unix.test' "$T/list"
    grep -Fxq "     HTTP | 端口 未知 | $effective" "$T/list"
    grep -Fxq "     HTTPS | 端口 81/未知 | $effective" "$T/list"
    grep -Fxq '  8) [启用] empty.test' "$T/list"
    grep -Fxq '     HTTP | 端口 8082 | 域名限制未知（无效策略）' "$T/list"
    grep -Fxq '  7) [启用] 未知域名' "$T/list"
    grep -Fxq '     未知协议 | 端口 未知 | 域名限制未知（无效策略）' "$T/list"
    grep -Fxq '  10) [启用] 未知域名' "$T/list"
    grep -Fxq '  11) [启用] 未知域名' "$T/list"
    [[ ${#FILES[@]} == 12 && ${FILES[1]} == c.conf && ${FILES[11]} == b.conf.bak ]]
  done
  # Missing state retains the existing effective-policy fallback; bad legacy
  # data is explicitly unknown. No health checks or mutations are invoked.
  rm "$DOMAIN_ONLY_STATE"
  printf 'DOMAIN_ONLY=broken\n' > "$STATE_DIR/domain-only.conf"
  print_conf_list > "$T/list" 2>/dev/null
  grep -Fxq '     HTTP | 端口 90/10000 | 域名限制未知' "$T/list"
  rm "$STATE_DIR/domain-only.conf"
  print_conf_list > "$T/list" 2>/dev/null
  grep -Fxq '     HTTP | 端口 90/10000 | 不限域名' "$T/list"
  # Exercise the actual numeric menu selection for duplicate domains and a
  # damaged row in between; the existing action menu still receives filenames.
  require_nginx_installed() { :; }
  clear() { :; }
  config_file_action_menu() { printf '%s\n' "$1" >> "$T/selected"; }
  : > "$T/selected"
  config_manage_menu <<< $'2\n12\n0' > "$T/menu" 2>/dev/null
  printf 'c.conf\nb.conf.bak\n' > "$T/expected"
  diff -u "$T/expected" "$T/selected"
 )
done
echo 'config list regression: PASS (source + bundle)'
