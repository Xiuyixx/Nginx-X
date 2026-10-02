#!/usr/bin/env bash
# shellcheck disable=SC2317
set -euo pipefail
cd "$(dirname "$0")/.."
source ./nx.sh
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
# All package/service/account operations below are explicit no-op stubs.
# Exercise real confirmations and composite control flow, not helper stand-ins.
SUDO=''
detect_pkg_mgr() { echo apt; }
check_cmd() { [[ $1 == systemctl ]]; }
systemctl() { touch "$root/stopped"; }
apt-get() { touch "$root/removed"; }
nx_acme_owned_domains() { echo example.com; }
nx_acme_uninstall_account() { touch "$root/account"; }
uninstall_script_only() { touch "$root/script"; }
for cancel in nginx first-acme second-acme; do
  confirm() {
    case "$cancel:$1" in
      'nginx:确认继续卸载 Nginx？'|'first-acme:确认继续卸载 Acme？'|'second-acme:这是高风险操作，是否再次确认卸载 Acme？') return 1 ;;
      *) return 0 ;;
    esac
  }
  uninstall_all > "$root/output" 2>&1
  [[ ! -e "$root/account" && ! -e "$root/script" ]]
  if [[ $cancel == nginx ]]; then [[ ! -e "$root/stopped" && ! -e "$root/removed" ]]; fi
done
confirm() { return 0; }
uninstall_all > "$root/output" 2>&1
[[ -e "$root/account" && -e "$root/script" ]]
echo 'PASS: whole uninstall stops normally at each cancelled phase'
