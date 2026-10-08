#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/../nx.sh"
trap nx_test_cleanup EXIT
# shellcheck disable=SC2034
SUDO=''
export HOME="$NX_TEST_ENV_ROOT/home"
# shellcheck disable=SC2034
EMAIL_CONF="$NX_TEST_ENV_ROOT/email"; DNS_CONF="$NX_TEST_ENV_ROOT/dns"
# shellcheck disable=SC2034
nx_acme_privileged_paths() { NX_ACME_MANIFEST="$NX_TEST_ENV_ROOT/manifest"; NX_ACME_DISPATCH="$NX_TEST_ENV_ROOT/dispatcher"; }
nx_acme_privileged_paths
mkdir -p "$HOME/.acme.sh/b.example_ecc" "$NX_TEST_ENV_ROOT/custom"
printf cert > "$HOME/.acme.sh/b.example_ecc/fullchain.pem"
printf secret > "$DNS_CONF"
: > "$NX_ACME_MANIFEST"
# Any destructive operation is a test failure: the preflight must refuse.
# shellcheck disable=SC2317
disable_acme_cron() { echo touched > "$NX_TEST_ENV_ROOT/touched"; return 1; }
for location in direct include relative symlink; do
  printf 'events {} http { include %s/*.conf; }\n' "$CONF_DIR" > "$NGINX_MAIN_CONF"
  rm -f "$CONF_DIR"/*
  target="$HOME/.acme.sh/b.example_ecc/fullchain.pem"
  case "$location" in
    include) printf 'include %s/custom/active;\n' "$NX_TEST_ENV_ROOT" > "$CONF_DIR/site.conf"; site="$NX_TEST_ENV_ROOT/custom/active" ;;
    relative) target='home/.acme.sh/b.example_ecc/fullchain.pem'; site="$CONF_DIR/site.conf" ;;
    symlink) ln -sf "$HOME/.acme.sh/b.example_ecc/fullchain.pem" "$NX_TEST_ENV_ROOT/alias.pem"; target="$NX_TEST_ENV_ROOT/alias.pem"; site="$CONF_DIR/site.conf" ;;
    *) site="$CONF_DIR/site.conf" ;;
  esac
  printf 'server { ssl_certificate "%s"; }\n' "$target" > "$site"
  if nx_acme_uninstall_account online > "$NX_TEST_ENV_ROOT/diagnostic" 2>&1; then exit 1; fi
  grep -q 'active certificate reference' "$NX_TEST_ENV_ROOT/diagnostic"
  [[ ! -e "$NX_TEST_ENV_ROOT/touched" && -f "$target" || "$location" == relative ]]
  [[ -f "$HOME/.acme.sh/b.example_ecc/fullchain.pem" && $(cat "$DNS_CONF") == secret ]]
done
# A link inside the deletion tree pointing out is still a live reference.
printf cert > "$NX_TEST_ENV_ROOT/external.pem"
ln -s "$NX_TEST_ENV_ROOT/external.pem" "$HOME/.acme.sh/link.pem"
printf 'ssl_certificate "%s/.acme.sh/link.pem";\n' "$HOME" > "$CONF_DIR/site.conf"
if nx_acme_assert_paths_unreferenced "$HOME/.acme.sh"; then exit 1; fi
echo 'PASS: full account deletion-set references, includes, relative paths and aliases'
