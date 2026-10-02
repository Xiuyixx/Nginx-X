#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/../nx.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
# shellcheck disable=SC2034
SUDO=''
SSL_DIR="$tmp/ssl"; CONF_DIR="$tmp/conf"; DOMAIN_ONLY_STATE="$tmp/policy"
EMAIL_CONF="$tmp/email"; DNS_CONF="$tmp/dns"; NX_PERIODIC_DIR="$tmp/periodic"
mkdir -p "$HOME/.acme.sh" "$SSL_DIR" "$CONF_DIR" "$NX_PERIODIC_DIR/daily" "$NX_PERIODIC_DIR/monthly"
printf keep > "$DOMAIN_ONLY_STATE"
printf secret > "$DNS_CONF"
printf email > "$EMAIL_CONF"
printf '0 3 * * * "%s/.acme.sh/acme.sh" --cron --home "%s/.acme.sh"\n0 4 * * * /other/.acme.sh/acme.sh --cron --home /other/.acme.sh\n7 5 * * * backup\n' "$HOME" "$HOME" > "$tmp/cron"
for period in daily monthly; do
  printf '#!/bin/sh\n"%s/.acme.sh"/acme.sh --cron --home "%s/.acme.sh"\n' "$HOME" "$HOME" > "$NX_PERIODIC_DIR/$period/acme-renew"
done
confirm() { return 0; }
nx_transaction() { "$@"; }
crontab() {
  if [[ "$1" == -l ]]; then
    if [[ ${FAIL_READ:-0} == 1 ]]; then echo 'permission denied' >&2; return 6; fi
    cat "$tmp/cron"
  else
    [[ ${FAIL_CRON:-0} == 0 ]] || return 9
    cat > "$tmp/cron"
  fi
}
FAIL_READ=1
if uninstall_acme_only; then exit 1; fi
[[ -d "$HOME/.acme.sh" && -f "$DNS_CONF" && -d "$SSL_DIR" ]]
FAIL_READ=0
FAIL_CRON=1
if uninstall_acme_only; then exit 1; fi
[[ -d "$HOME/.acme.sh" && -f "$DNS_CONF" && -d "$SSL_DIR" ]]
FAIL_CRON=0
uninstall_acme_only
[[ ! -e "$HOME/.acme.sh" && ! -e "$SSL_DIR" && ! -e "$DNS_CONF" && ! -e "$EMAIL_CONF" ]]
[[ "$(cat "$DOMAIN_ONLY_STATE")" == keep ]]
[[ ! -e "$NX_PERIODIC_DIR/daily/acme-renew" && ! -e "$NX_PERIODIC_DIR/monthly/acme-renew" ]]
grep -Fxq '0 4 * * * /other/.acme.sh/acme.sh --cron --home /other/.acme.sh' "$tmp/cron"
grep -Fxq '7 5 * * * backup' "$tmp/cron"
echo 'ok: uninstall owner parsing, daily/monthly cleanup, failure propagation, unrelated cron and access state preservation'
