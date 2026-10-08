#!/usr/bin/env bash
# shellcheck disable=SC2317
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
T="$(mktemp -d)"
trap 'nx_test_cleanup; rm -rf "$T"' EXIT
root="$(cd "$(dirname "$0")/.." && pwd)"
bash "$root/tools/build-bundle.sh" "$T/bundle"
for entry in "$root/nx.sh" "$T/bundle"; do
(
  # shellcheck source=nx.sh
  source "$entry"
  HOME="$T/home"; mkdir -p "$HOME"
  # shellcheck disable=SC2034
  SUDO=""
  # Any unexpected mutating probe must fail the test, not touch the host.
  ensure_dirs() { touch "$T/mutation"; return 99; }
  ensure_state_dir() { touch "$T/mutation"; return 99; }
  ensure_runtime_dependencies() { touch "$T/mutation"; return 99; }
  nx_migrate_certificate_renewal() { touch "$T/mutation"; return 99; }
  load_dns_conf() { touch "$T/mutation"; return 99; }
  nginx_local_version() { echo 1.26.3; }
  pgrep() { return 1; }
  crontab() { [[ "$*" == -l ]] || { touch "$T/mutation"; return 99; }; return 1; }
  # shellcheck disable=SC2034
  NX_PERIODIC_DIR="$T/periodic"
  NX_OS_RELEASE="$T/os-release"
  printf 'PRETTY_NAME="Test OS"\n' > "$NX_OS_RELEASE"
  mkdir -p "$CONF_DIR" "$SSL_DIR/example" "$(dirname "$DNS_CONF")"
  touch "$CONF_DIR/site.conf" "$CONF_DIR/disabled.conf.bak" "$SSL_DIR/example/fullchain.pem"
  printf 'DNS_PROVIDER=cf\nDNS_KEY1=abcd\nDNS_KEY2=SECRET-LONG-KEY\ntouch %s/pwned\n' "$T" > "$DNS_CONF"
  before="$(sha256sum "$DNS_CONF")"
  system_info_panel > "$T/panel"
  grep -q '系统: Test OS' "$T/panel"
  grep -q '已启用站点配置数: 1' "$T/panel"
  grep -q 'DNS API 服务商: cf' "$T/panel"
  grep -q 'acme 账户级自动续期:' "$T/panel"
  if grep -qE 'abcd|SECRET|LONG-KEY' "$T/panel"; then exit 1; fi
  [[ ! -e "$T/pwned" && ! -e "$T/mutation" && "$before" == "$(sha256sum "$DNS_CONF")" ]]
  main_menu > "$T/menu"
  grep -q '^5) 更新脚本' "$T/menu"; grep -q '^6) 卸载' "$T/menu"; grep -q '^7) 系统信息' "$T/menu"
)
done
echo 'PASS read-only source/bundle panel, malicious state not executed, short/long keys fully hidden and stable menu numbering'
