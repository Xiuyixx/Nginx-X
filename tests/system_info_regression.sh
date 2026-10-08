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
  crontab() {
    # Root probes use -l; non-root account probes add the read-only -u selector.
    if [[ "$*" != -l && "$*" != "-u $(id -un) -l" ]]; then
      touch "$T/mutation"; return 99
    fi
    return 1
  }
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
  grep -q '^4) 实时信息' "$T/menu"
  grep -q '^5) 更新脚本' "$T/menu"; grep -q '^6) 卸载' "$T/menu"
  grep -q '^7)' "$T/menu" && exit 1

  # Drive the actual main -> 4 -> original submenu choices -> return path.
  # Stub only host initialization and leaf actions; keep real menu dispatch,
  # panel and input handling. A clear marker verifies each complete redraw.
  (
    ensure_dirs() { :; }
    ensure_runtime_dependencies() { :; }
    ensure_websocket_map() { :; }
    nx_migrate_certificate_renewal() { :; }
    banner() { echo MAIN; }
    clear() { echo CLEAR; }
    pause() { echo UNEXPECTED_PAUSE; return 99; }
    require_nginx_installed() { echo UNEXPECTED_GATE; return 99; }
    show_nginx_realtime_status() { echo ACTION_REALTIME; }
    show_traffic_stats() { echo ACTION_TRAFFIC; }
    site_health_menu() { echo ACTION_HEALTH; }
    main <<< $'4\n1\n2\n3\n0\n0'
  ) > "$T/interaction"
  python3 - "$T/interaction" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
assert 'UNEXPECTED_' not in text and '\n7)' not in text
frames = text.split('CLEAR\n')[1:]
assert len(frames) == 4, text
for frame in frames:
    assert frame.index('系统信息') < frame.index('系统: Test OS') < frame.index('1) 实时信息')
    assert frame.index('1) 实时信息') < frame.index('2) 流量统计') < frame.index('3) 健康检查') < frame.index('0) 返回上一级')
    assert all(secret not in frame for secret in ('abcd', 'SECRET', 'LONG-KEY'))
for action in ('ACTION_REALTIME', 'ACTION_TRAFFIC', 'ACTION_HEALTH'):
    assert text.count(action) == 1, text
PY
  # A failed optional panel must not hide choices, consume input or pause.
  (
    clear() { echo CLEAR; }
    pause() { echo UNEXPECTED_PAUSE; return 99; }
    system_info_panel() { echo PANEL_FAILED; return 1; }
    show_nginx_realtime_status() { echo ACTION_REALTIME; }
    show_traffic_stats() { echo ACTION_TRAFFIC; }
    site_health_menu() { echo ACTION_HEALTH; }
    realtime_info_menu <<< $'1\n2\n3\n0'
  ) > "$T/failure"
  [[ "$(grep -c '^PANEL_FAILED' "$T/failure")" == 4 ]]
  for action in REALTIME TRAFFIC HEALTH; do grep -q "^ACTION_$action" "$T/failure"; done
  grep -q UNEXPECTED_PAUSE "$T/failure" && exit 1
  [[ ! -e "$T/pwned" && ! -e "$T/mutation" && "$before" == "$(sha256sum "$DNS_CONF")" ]]
)
done
echo 'PASS source/bundle main -> 4 panel-first redraws, original actions, failure fallback, no extra pause or menu 7, read-only hidden keys'
