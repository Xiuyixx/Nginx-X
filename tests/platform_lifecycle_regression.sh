#!/usr/bin/env bash
# shellcheck disable=SC2317 # injected functions called through sourced menus
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
source ./nx.sh
root="$(mktemp -d)"
trap 'nx_test_cleanup; rm -rf "$root"' EXIT
SUDO=""
fail() { echo "FAIL: $*" >&2; exit 1; }
# Real menu wrapper suppresses errexit inside actions: these must still stop.
(
  ensure_runtime_dependencies() { :; }
  check_cmd() { return 1; }
  install_nginx_official() { return 1; }
  auto_import_after_install() { touch "$root/imported"; }
  run_menu_action install_or_upgrade_nginx
)
[[ ! -e "$root/imported" ]] || fail 'import after failed install'
(
  check_cmd() { [[ "$1" == nginx ]]; }
  nginx_local_version() { echo 1.0; }
  nginx_latest_version_online() { echo 99.0; }
  cp() { return 1; }
  detect_pkg_mgr() { touch "$root/package-after-backup"; echo apt; }
  run_menu_action upgrade_nginx_smart
)
[[ ! -e "$root/package-after-backup" ]] || fail 'backup failure ignored'
for failure in stop package; do
 (
  confirm() { return 0; }
  detect_pkg_mgr() { echo apt; }
  check_cmd() { [[ "$1" == systemctl ]]; }
  systemctl() { [[ "$failure" != stop ]]; }
  apt-get() { touch "$root/package-$failure"; return 1; }
  rm() { touch "$root/deleted"; }
  run_menu_action uninstall_nginx_only
 )
done
[[ ! -e "$root/package-stop" && -e "$root/package-package" && ! -e "$root/deleted" ]] || fail 'uninstall continued'
valid_dns_address 2001:4860:4860::8888
valid_dns_address 8.8.8.8
for value in '999.1.1.1' '1.1.1.1;id' '::xyz' $'1.1.1.1\nsearch evil'; do
  if valid_dns_address "$value"; then fail 'invalid DNS accepted'; fi
done
printf 'original\n' > "$root/managed"
ln -s managed "$root/resolv.conf"
(
 install_managed_file() { return 1; }
 if write_system_dns "$root/resolv.conf" 1.1.1.1; then fail 'DNS failure success'; fi
)
[[ -L "$root/resolv.conf" && "$(cat "$root/managed")" == original ]] || fail 'DNS symlink lost'
write_system_dns "$root/resolv.conf" 1.1.1.1 2606:4700:4700::1111
[[ ! -L "$root/resolv.conf" && "$(cat "$root/managed")" == original ]] || fail 'DNS target modified'
[[ "$(sample_rate 5242880 0 5 1048576)" == 1.00 ]] || fail 'rate'
[[ "$(sample_rate 50 0 2.5)" == 20.00 ]] || fail 'qps'
[[ "$(sample_rate 0 50 2.5)" == 0.00 ]] || fail 'counter reset'
# Custom installed identity must ignore another PATH nx, including under sudo.
mkdir -p "$root/source/lib" "$root/source/tools" "$root/bin" "$root/other"
cp nx.sh install.sh "$root/source/"
cp lib/*.sh "$root/source/lib/"
cp tools/build-bundle.sh "$root/source/tools/"
mkdir -p "$root/mock"
printf '#!/bin/sh\nexec "$@"\n' > "$root/mock/sudo"
chmod +x "$root/mock/sudo"
PATH="$root/mock:$PATH" TARGET_BIN="$root/bin/nx" bash "$root/source/install.sh" --no-run >/dev/null
printf 'unrelated\n' > "$root/other/nx"
PATH="$root/other:$PATH" bash -c 'source "$1"; [[ "$(installed_script_target)" == "$1" && "$NX_INSTALLED_REPO" == "$2" ]]; SUDO=""; if update_script; then exit 1; fi' _ "$root/bin/nx" "$root/source" "$root/git-called"
[[ ! -e "$root/git-called" && -f "$root/source/nx.sh" ]] || fail 'unknown repository changed'
# Update via a sudo wrapper with a secure PATH; target identity is not PATH nx.
mkdir -p "$root/source/.git"
cat > "$root/mock/git" <<'MOCKGIT'
#!/bin/sh
case "$*" in *remote*) echo https://github.com/Xiuyixx/Nginx-X.git;; *pull*) exit 0;; *) exit 1;; esac
MOCKGIT
cat > "$root/mock/sudo" <<'MOCKSUDO'
#!/bin/sh
PATH="$(dirname "$0"):/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
[ "${1:-}" != -v ] || exit 0
[ "${1:-}" != -n ] || shift
exec "$@"
MOCKSUDO
for tool in nft ss; do
 printf '#!/bin/sh\nexit 0\n' > "$root/mock/$tool"
 chmod +x "$root/mock/$tool"
done
chmod +x "$root/mock/git" "$root/mock/sudo"
# Worker commands must be executable fixtures, not parent-only shell functions.
PATH="$root/mock:$root/other:$PATH" bash -c 'source "$1"; SUDO=sudo; mock_git="$2"; sudo(){ if [[ "$1" == git ]]; then shift; "$mock_git" "$@"; else command sudo "$@"; fi; }; update_script' _ "$root/bin/nx" "$root/mock/git"
[[ -f "$root/bin/nx" && "$(cat "$root/other/nx")" == unrelated ]] || fail 'secure PATH update identity'
printf 'DOMAIN_ONLY=1\n' > "$root/shared-policy"
DOMAIN_ONLY_STATE="$root/shared-policy" PATH="$root/other:$PATH" bash -c 'source "$1"; SUDO=""; confirm(){ return 0; }; uninstall_script_only' _ "$root/bin/nx" >/dev/null
grep -qx DOMAIN_ONLY=1 "$root/shared-policy"
[[ ! -e "$root/bin/nx" && -f "$root/other/nx" ]] || fail 'uninstall identity'
# Failed publication preserves the old executable and removes unique staging files.
printf 'old executable\n' > "$root/bin/nx"
cat > "$root/mock/install" <<'MOCKINSTALL'
#!/bin/sh
exit 1
MOCKINSTALL
chmod +x "$root/mock/install"
if PATH="$root/mock:$PATH" TARGET_BIN="$root/bin/nx" bash "$root/source/install.sh" --no-run; then fail 'install failure accepted'; fi
[[ "$(cat "$root/bin/nx")" == 'old executable' ]] || fail 'old executable replaced'
if compgen -G "$root/bin/nx.stage.*" >/dev/null; then fail 'staging leaked'; fi
rm "$root/mock/install"
# Existing nginx installation with missing Python is repaired before use.
(
  check_cmd() { [[ "$1" != python3 || -e "$root/python-ready" ]]; }
  sudo() { if [[ "$1" == -v ]]; then return 0; fi; "$@"; }
  detect_pkg_mgr() { echo apt; }
  apt-get() { [[ "$1" != install ]] || touch "$root/python-ready"; }
  ensure_runtime_dependencies
)
[[ -e "$root/python-ready" ]] || fail 'runtime dependency migration'
# Exercise the actual DNS menu with an isolated override and a failed writer.
(
  export NX_RESOLV_CONF="$root/menu-resolv"
  printf 'nameserver 9.9.9.9\n' > "$NX_RESOLV_CONF"
  clear() { :; }; pause() { :; }; check_cmd() { return 1; }
  install_managed_file() { return 1; }
  run_menu_action dns_setup_menu <<< $'1\n0' > "$root/dns-output"
)
[[ "$(cat "$root/menu-resolv")" == 'nameserver 9.9.9.9' ]] || fail 'menu DNS lost'
if grep -q 'DNS 已更新为' "$root/dns-output"; then fail 'false DNS success'; fi
echo 'ok: lifecycle failures, DNS rollback, rates, custom installed identity'
