#!/usr/bin/env bash
# shellcheck disable=SC2317 # fault injection functions run inside helpers
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
source ./nx.sh
root="$(mktemp -d)"
trap 'nx_test_cleanup; rm -rf "$root"' EXIT
bash tools/build-bundle.sh "$root/bundle"
for implementation in ./nx.sh "$root/bundle"; do
 (
  # shellcheck disable=SC1090
  source "$implementation"
  uname() { echo Linux; }
  # Mapping tests replace installation, so privilege validation is mocked too.
  sudo() { [[ "$*" == -v ]]; }
  for manager in apt dnf yum apk; do
   for absent in nft ss both none; do
    nx_dependency_present() {
     [[ "$1" == sudo || -e "$root/ready" || "$absent" == none || ( "$absent" != both && "$1" != "$absent" ) ]]
    }
    nx_install_backend_packages() { printf '%s\n' "$*" > "$root/packages"; touch "$root/ready"; }
    rm -f "$root/ready" "$root/packages"
    nx_ensure_backend_dependencies "$manager"
    case "$absent:$manager" in
     none:*) [[ ! -e "$root/packages" ]] ;;
     nft:*) [[ $(cat "$root/packages") == "$manager nftables" ]] ;;
     ss:dnf|ss:yum) [[ $(cat "$root/packages") == "$manager iproute" ]] ;;
     ss:*) [[ $(cat "$root/packages") == "$manager iproute2" ]] ;;
     both:dnf|both:yum) [[ $(cat "$root/packages") == "$manager nftables iproute" ]] ;;
     both:*) [[ $(cat "$root/packages") == "$manager nftables iproute2" ]] ;;
    esac
   done
  done
  nx_dependency_present() { return 1; }
  nx_install_backend_packages() { return 37; }
  if nx_ensure_backend_dependencies apt; then exit 1; fi
  nx_install_backend_packages() { return 0; }
  if nx_ensure_backend_dependencies apt; then exit 1; fi
  nx_install_backend_packages() { echo 'unexpected installation' >&2; exit 90; }
  nx_ensure_backend_dependencies opkg
  uname() { echo Darwin; }
  nx_ensure_backend_dependencies apt
 )
done
# Source/help/build never run dependencies or create installation paths.
mkdir "$root/mock"
for cmd in apt-get dnf yum apk sudo systemctl nft; do
 printf '#!/bin/sh\necho unexpected-%s >&2; exit 91\n' "$cmd" > "$root/mock/$cmd"
 chmod +x "$root/mock/$cmd"
done
PATH="$root/mock:$PATH" TARGET_BIN="$root/not-installed" bash -c 'source "$1/install.sh"; source "$1/nx.sh"' _ "$PWD"
PATH="$root/mock:$PATH" bash install.sh --help >/dev/null
PATH="$root/mock:$PATH" bash nx.sh --help >/dev/null
PATH="$root/mock:$PATH" bash "$root/bundle" --help >/dev/null
[[ ! -e "$root/not-installed" ]]
echo 'PASS backend dependency command/package mappings, idempotence, partial missing, failure, source/help/bundle boundaries'
