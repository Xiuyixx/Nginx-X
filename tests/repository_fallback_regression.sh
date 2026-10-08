#!/usr/bin/env bash
# shellcheck disable=SC2317
# Mocks are invoked by the sourced repository implementation.
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
# shellcheck source=nx.sh
source "$(dirname "$0")/../nx.sh"
T="$(mktemp -d)"
trap 'nx_test_cleanup; rm -rf "$T"' EXIT
SUDO=""
NX_APT_SOURCE="$T/nginx.list" NX_RPM_SOURCE="$T/nginx.repo" NX_REPO_KEY="$T/key"
export GNUPGHOME="$T/gpg"
mkdir -m 700 "$GNUPGHOME"
# Deterministic fake key/parser for transaction tests; real fingerprint parsing
# is tested separately below without fetching network or touching host keys.
nx_repo_fetch() {
  printf '%s\n' "$1" >> "$T/fetches"
  case "$1" in
    */Release) printf 'Origin: nginx\nSHA256:\n abc 1 Packages\n' > "$2" ;;
    */repomd.xml) printf '<repomd xmlns="http://linux.duke.edu/metadata/repo"><data type="primary"/></repomd>' > "$2" ;;
    *) printf 'fake trusted key\n' > "$2" ;;
  esac
}
nx_repo_validate_key() { [[ ${KEY_FAIL:-0} != 1 ]]; }
gpg() {
  local out=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == -o ]]; then out="$2"; shift; fi
    shift
  done
  [[ -n "$out" ]] || return 1
  printf 'key\n' > "$out"
  [[ ${GPG_FAIL:-0} != 1 ]]
}
# All package operations are mocks; log isolated options and force failures.
apt-get() {
  printf '%s\n' "$*" >> "$T/packages"
  [[ "$*" == *"Dir::Etc::sourcelist=$NX_APT_SOURCE"* && "$*" == *'Dir::Etc::sourceparts=-'* ]] || return 99
  if [[ ${FAIL:-0} == all ]]; then return 1; fi
  if [[ ${FAIL:-0} == refresh && "$*" == *update* ]] && grep -q 'nginx.org' "$NX_APT_SOURCE"; then return 1; fi
  if [[ ${FAIL:-0} == download && "$*" == *install* ]] && grep -q 'nginx.org' "$NX_APT_SOURCE"; then return 1; fi
}
yum() {
  printf '%s\n' "$*" >> "$T/packages"
  [[ ${FAIL:-0} != all ]] || return 1
  if [[ ${FAIL:-0} == download && "$*" == *install* ]] && grep -q 'nginx.org' "$NX_RPM_SOURCE"; then return 1; fi
  if [[ ${FAIL:-0} != download && "$*" == *makecache* ]] && grep -q 'nginx.org' "$NX_RPM_SOURCE"; then return 1; fi
}
for FAIL in refresh download; do
  nx_install_repository apt ubuntu noble '' ''
  grep -q 'mirrors.ustc.edu.cn/nginx/ubuntu' "$NX_APT_SOURCE"
done
printf 'old source\n' > "$NX_APT_SOURCE"; chmod 640 "$NX_APT_SOURCE"
printf 'old key\n' > "$NX_REPO_KEY"; chmod 600 "$NX_REPO_KEY"
cp -p "$NX_APT_SOURCE" "$T/source.before"; cp -p "$NX_REPO_KEY" "$T/key.before"
FAIL=all
if nx_install_repository apt debian bookworm '' ''; then exit 1; fi
cmp "$NX_APT_SOURCE" "$T/source.before"; cmp "$NX_REPO_KEY" "$T/key.before"
[[ $(stat -c %a "$NX_APT_SOURCE") == 640 && $(stat -c %a "$NX_REPO_KEY") == 600 ]]
rm "$NX_APT_SOURCE" "$NX_REPO_KEY"
if nx_install_repository apt ubuntu noble '' ''; then exit 1; fi
[[ ! -e "$NX_APT_SOURCE" && ! -e "$NX_REPO_KEY" ]]
FAIL=0 GPG_FAIL=1
if nx_install_repository apt ubuntu noble '' ''; then exit 1; fi
[[ ! -e "$NX_APT_SOURCE" && ! -e "$NX_REPO_KEY" ]]
GPG_FAIL=0 KEY_FAIL=1
if nx_install_repository apt ubuntu noble '' ''; then exit 1; fi
[[ ! -e "$NX_REPO_KEY" ]]
KEY_FAIL=0
nx_install_repository apt ubuntu noble '' ''
nx_install_repository apt ubuntu noble '' ''
ln -s "$T/key" "$T/link"; NX_REPO_KEY="$T/link"
if nx_install_repository apt ubuntu noble '' ''; then exit 1; fi
NX_REPO_KEY="$T/rpm-key"
nx_install_repository yum centos '' 9 x86_64
FAIL=download
dnf() { yum "$@"; }
nx_install_repository dnf rocky '' 9 x86_64
FAIL=0
grep -q 'gpgcheck=1' "$NX_RPM_SOURCE"
grep -q "gpgkey=file://$NX_REPO_KEY" "$NX_RPM_SOURCE"
printf old > "$NX_RPM_SOURCE"; printf oldkey > "$NX_REPO_KEY"
FAIL=all
if nx_install_repository yum centos '' 9 x86_64; then exit 1; fi
[[ $(cat "$NX_RPM_SOURCE") == old && $(cat "$NX_REPO_KEY") == oldkey ]]
if nx_install_repository apt alpine noble '' ''; then exit 1; fi
if nx_install_repository yum fedora '' 40 x86_64; then exit 1; fi
printf '<html>directory listing</html>' > "$T/meta"
if nx_repo_metadata_valid apt "$T/meta"; then exit 1; fi
if nx_repo_metadata_valid yum "$T/meta"; then exit 1; fi
# Real validator function + controlled gpg colon records proves allowlist logic.
# shellcheck source=lib/repositories.sh
source "$(dirname "$0")/../lib/repositories.sh"
gpg() { printf 'pub::::::::::\nfpr:::::::::%s:\n' "$FINGERPRINT"; [[ ${EXTRA:-0} != 1 ]] || printf 'pub::::::::::\nfpr:::::::::BADKEY:\n'; }
FINGERPRINT=8540A6F18833A80E9C1653A42FD21310B49F6B46
nx_repo_validate_key "$T/key" "$T/gpg"
EXTRA=1
if nx_repo_validate_key "$T/key" "$T/gpg"; then exit 1; fi
EXTRA=0 FINGERPRINT=BADKEY
if nx_repo_validate_key "$T/key" "$T/gpg"; then exit 1; fi
printf 'deb https://mirrors.example/nginx/ubuntu noble nginx\n' > "$NX_APT_SOURCE"
printf 'arbitrary' > "$NX_RPM_SOURCE"
if nx_using_official_repository; then exit 1; fi
printf 'deb https://mirrors.ustc.edu.cn/nginx/ubuntu noble nginx\n' > "$NX_APT_SOURCE"
nx_using_official_repository
# Publishing must never nest into a directory or follow a link.
printf staged > "$T/ready"; mkdir "$T/directory"
if nx_repo_publish "$T/ready" "$T/directory"; then exit 1; fi
[[ -z $(find "$T/directory" -type f) ]]
# Real entry skips package bootstrap when tools exist, even with a bad old source.
(
  ensure_runtime_dependencies() { :; }
  ensure_dirs() { :; }
  detect_os_id() { echo ubuntu; }
  detect_pkg_mgr() { echo apt; }
  check_cmd() { [[ "$1" != nginx && "$1" != systemctl && "$1" != rc-service ]]; }
  lsb_release() { echo noble; }
  apt-get() { touch "$T/unexpected-bootstrap"; return 1; }
  nx_install_repository() { touch "$T/entry-reached"; return 1; }
  if install_nginx_official; then exit 1; fi
  [[ -e "$T/entry-reached" && ! -e "$T/unexpected-bootstrap" ]]
)
echo 'PASS repository fallback, package failure, rollback, modes, key retry, trust anchors and metadata'
