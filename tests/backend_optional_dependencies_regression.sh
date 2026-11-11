#!/usr/bin/env bash
# shellcheck disable=SC2317,SC1090,SC2034 # source/bundle and injected callbacks
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
root="$(mktemp -d)"
trap 'nx_test_cleanup; rm -rf "$root"' EXIT
bash tools/build-bundle.sh "$root/bundle"
for entry in ./nx.sh "$root/bundle"; do
 (
  source "$entry"
  SUDO=''
  # Base runtime preparation must ignore absent optional firewall tools.
  check_cmd() { [[ "$1" != nft && "$1" != ss ]]; }
  detect_pkg_mgr() { echo apt; }
  nx_ensure_backend_dependencies() { echo unexpected > "$root/install"; return 99; }
  ensure_runtime_dependencies
  [[ ! -e "$root/install" ]]
  # Diagnostics remain read-only and use their existing fallback.
  nx_dependency_present() { [[ "$1" != nft && "$1" != ss ]]; }
  nx_backend_status "$CONF_DIR/site.conf" > "$root/status"
  [[ ! -e "$root/install" ]]
 )
 (
  source "$entry"
  SUDO=''
  nx_access_assert_managed_site() { :; }
  nx_access_site_policy() { echo strict; }
  uname() { echo Linux; }
  detect_pkg_mgr() { echo apt; }
  nx_ensure_backend_dependencies() { echo install >> "$root/events"; [[ ${FAIL_INSTALL:-0} == 0 ]]; }
  _nx_backend_engine() { printf '%s\n' "$1" >> "$root/events"; }
  confirm() { return 1; }
  rc=0; nx_backend_enable site.conf || rc=$?
  [[ $rc == 10 && ! -e "$root/events" ]]
  confirm() { return 0; }
  FAIL_INSTALL=1
  if nx_backend_enable site.conf; then exit 1; fi
  [[ $(cat "$root/events") == install ]]
  : > "$root/events"
  FAIL_INSTALL=0
  nx_backend_enable site.conf
  [[ $(cat "$root/events") == $'install\nenable' ]]
  : > "$root/events"
  uname() { echo Darwin; }
  if nx_backend_enable site.conf; then exit 1; fi
  [[ ! -s "$root/events" ]]
  uname() { echo Linux; }
  detect_pkg_mgr() { echo opkg; }
  nx_dependency_present() { return 1; }
  if nx_backend_enable site.conf; then exit 1; fi
  [[ ! -s "$root/events" ]]
  # The combined entry uses the same opt-in dependency gate before the
  # transaction; failed installation cannot mutate entry policy.
  if [[ $EUID == 0 ]]; then
   detect_pkg_mgr() { echo apt; }
   nx_transaction() { echo transaction >> "$root/events"; }
   FAIL_INSTALL=1
   if nx_domain_enable "$CONF_DIR/site.conf"; then exit 1; fi
   [[ $(cat "$root/events") == install ]]
   : > "$root/events"
   FAIL_INSTALL=0
   nx_domain_enable "$CONF_DIR/site.conf"
   [[ $(cat "$root/events") == $'install\ntransaction' ]]
  fi
  rm -f "$root/events"
 )
done
echo 'PASS: optional nft/ss absent in base runtime, explicit enable consent/install/failure ordering, unsupported platform refusal; source/bundle'
