#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/../nx.sh"
root="$(mktemp -d)"
trap 'nx_test_cleanup; rm -rf "$root"' EXIT
# shellcheck disable=SC2034
SUDO=""
SSL_DIR="$root/ssl"
CONF_DIR="$root/conf"
export DOMAIN_ONLY_STATE="$CONF_DIR/.nx-access-state"
export NGINX_MAIN_CONF="$root/nginx.conf"
mkdir -p "$SSL_DIR" "$CONF_DIR"
# Override the acme home only in this isolated test process.
export HOME="$root/home"
mkdir -p "$HOME/.acme.sh"
export ACME_LOG="$root/acme.log"
cat > "$HOME/.acme.sh/acme.sh" <<'MOCK'
#!/bin/bash
printf '%s\n' "$@" >> "$ACME_LOG"
[[ "${FAIL_ISSUE:-0}:$1" != 1:--issue ]] || exit 8
[[ "${FAIL_DEPLOY:-0}:$1" != 1:--install-cert ]] || exit 9
while (($#)); do
 case "$1" in --key-file) cp "$HOME/key" "$2"; shift ;; --fullchain-file) cp "$HOME/chain" "$2"; shift ;; esac
 shift
done
MOCK
chmod +x "$HOME/.acme.sh/acme.sh"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com \
  -keyout "$HOME/key" -out "$HOME/chain" >/dev/null 2>&1
# Unit boundaries are explicit: privileged path/identity/publication proofs run
# in acme_identity_isolated.sh under real root and a password-sudo account.
nx_acme_check_account_identity() { :; }
nx_acme_prepare_webroot() { :; }
# shellcheck disable=SC2034
nx_acme_privileged_paths() { NX_ACME_DISPATCH="$root/dispatcher"; NX_ACME_MANIFEST="$root/manifest"; }
nx_acme_prepare_dispatch() {
  nx_acme_privileged_paths
  cat > "$NX_ACME_DISPATCH" <<DISPATCH
#!/bin/bash
if [[ \$1 == install ]]; then
 mkdir -p "$HOME/.acme.sh/nginxx-deploy/example.com"
 "$HOME/.acme.sh/acme.sh" --install-cert -d example.com \$(test ! -d "$HOME/.acme.sh/example.com_ecc" || echo --ecc) --key-file "$HOME/.acme.sh/nginxx-deploy/example.com/privkey.pem" --fullchain-file "$HOME/.acme.sh/nginxx-deploy/example.com/fullchain.pem" --reloadcmd ':' || exit \$?
 printf 'example.com\n' > "$root/manifest"
fi
mkdir -p "$SSL_DIR/example.com"
cp "$HOME/.acme.sh/nginxx-deploy/example.com/"*.pem "$SSL_DIR/example.com/"
DISPATCH
  chmod 0700 "$NX_ACME_DISPATCH"
}
nx_acme_register_domain() { printf '%s\n' "$1" > "$root/manifest"; }
nx_acme_account_crontab() { crontab "$@"; }
# shellcheck disable=SC2034
load_email() { ACME_EMAIL=test@example.com; }
has_dns_config() { return 0; }
get_dns_issue_args() { echo '--dns dns_cf'; }
# shellcheck disable=SC2317
export_dns_env() { :; }
export FAIL_ISSUE=1
if _issue_cert_dns example.com; then exit 1; fi
if grep -q -- --install-cert "$ACME_LOG"; then exit 1; fi
export FAIL_ISSUE=0 FAIL_DEPLOY=1
if _issue_cert_dns example.com; then exit 1; fi
[[ ! -e "$root/cron" ]]
export FAIL_DEPLOY=0
crontab() { if [[ "$1" == -l ]]; then cat "$root/cron" 2>/dev/null; else cat > "$root/cron"; fi; }
printf '7 4 * * * unrelated\n0 3 1 */2 * %s/.acme.sh/acme.sh --cron --home %s/.acme.sh >/dev/null\n' "$HOME" "$HOME" > "$root/cron"
_issue_cert_dns example.com
grep -Fq -- --reloadcmd "$ACME_LOG"
grep -q '^0 3 \* \* \* ' "$root/cron"
grep -q '^7 4 \* \* \* unrelated$' "$root/cron"
ensure_acme_cron
[[ "$(grep -c 'dispatcher cron' "$root/cron")" == 1 ]]
apply_conf_with_rollback() { cp "$1" "$2"; }
nx_transaction() { "$@"; }
reload_nginx_safe() { :; }
precheck_http01() { :; }
cat > "$CONF_DIR/unrelated.conf" <<'CONF'
server { listen 127.0.0.1:80; server_name notexample.com; location / { return 200 okay; } }
CONF
_issue_cert_http example.com
[[ -f "$CONF_DIR/acme-challenge-example.com.conf" ]]
# Exact names and compact address listeners: do not create duplicate helpers.
rm "$CONF_DIR/acme-challenge-example.com.conf"
cat > "$CONF_DIR/site.conf" <<'CONF'
server { listen 127.0.0.1:80; server_name example.com; return 301 https://$host$request_uri; }
CONF
ensure_acme_location_for_domain_conf example.com
grep -Fq 'location / { return 301' "$CONF_DIR/site.conf"
grep -Fq 'location ^~ /.well-known/acme-challenge/' "$CONF_DIR/site.conf"
[[ -z "$(ensure_http_challenge_server example.com)" ]]
ensure_websocket_map() { :; }
if build_external_proxy_conf example.com 8080 http://127.0.0.1 normal "$root/bad" 0 '' '' '"; add_header Evil yes; #'; then exit 1; fi
[[ ! -e "$root/bad" ]]
# Loading long provider names must export the canonical plugin credentials.
unset -f export_dns_env
saved_fixtures="$(declare -f nx_acme_check_account_identity nx_acme_prepare_webroot nx_acme_privileged_paths nx_acme_prepare_dispatch nx_acme_register_domain nx_acme_account_crontab)"
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/certificates.sh"
eval "$saved_fixtures"
ensure_state_dir() { :; }
DNS_CONF="$root/dns.conf"
printf 'DNS_PROVIDER=cloudflare\nDNS_KEY1=test-token\n' > "$DNS_CONF"
export_dns_env
# shellcheck disable=SC2154
[[ "$DNS_PROVIDER" == cf && "$CF_Token" == test-token ]]
# Legacy monthly periodic job migrates alongside the daily crontab.
NX_PERIODIC_DIR="$root/periodic"
mkdir -p "$NX_PERIODIC_DIR/monthly"
printf '#!/bin/sh\n%s/.acme.sh/acme.sh --cron --home %s/.acme.sh >/dev/null\n' "$HOME" "$HOME" > "$NX_PERIODIC_DIR/monthly/acme-renew"
ensure_acme_cron
[[ ! -f "$NX_PERIODIC_DIR/monthly/acme-renew" ]]
echo 'certificate audit regressions passed' 
# Quoted acme install cron syntax is recognized; duplicate same-account jobs
# collapse while another home and comments remain byte-for-byte.
printf '7 4 * * * unrelated\n0 3 1 */2 * "%s/.acme.sh"/acme.sh --cron --home "%s/.acme.sh" >/dev/null\n0 4 * * * "%s/.acme.sh/acme.sh" --cron --home "%s/.acme.sh"\n0 5 * * * /other/.acme.sh/acme.sh --cron --home /other/.acme.sh\n' "$HOME" "$HOME" "$HOME" "$HOME" > "$root/cron"
ensure_acme_cron
cp "$root/cron" "$root/cron-before"
ensure_acme_cron
cmp "$root/cron" "$root/cron-before"
[[ "$(grep -c 'cron' "$root/cron")" == 2 ]]
disable_acme_cron
grep -q '^0 5 .* /other/' "$root/cron"
if has_acme_cron_task; then exit 1; fi
# Existing ACME deploy destinations migrate to protected staging on startup;
# unrelated destinations and certificates without an installed key are ignored.
mkdir -p "$HOME/.acme.sh/example.com_ecc" "$HOME/.acme.sh/other.example"
printf "Le_RealKeyPath='%s/example.com/privkey.pem'\nLe_RealFullChainPath='%s/example.com/fullchain.pem'\n" "$SSL_DIR" "$SSL_DIR" > "$HOME/.acme.sh/example.com_ecc/example.com.conf"
printf "Le_RealKeyPath='/other/key.pem'\n" > "$HOME/.acme.sh/other.example/other.example.conf"
: > "$ACME_LOG"
nx_migrate_certificate_renewal
grep -qx -- --ecc "$ACME_LOG"
grep -qx -- --reloadcmd "$ACME_LOG"
[[ "$(grep -c -- --install-cert "$ACME_LOG")" == 1 ]]
# Mock acme.sh persists the staging destinations, making migration idempotent.
printf "Le_RealKeyPath='%s/.acme.sh/nginxx-deploy/example.com/privkey.pem'\nLe_RealFullChainPath='%s/.acme.sh/nginxx-deploy/example.com/fullchain.pem'\n" "$HOME" "$HOME" > "$HOME/.acme.sh/example.com_ecc/example.com.conf"
: > "$ACME_LOG"
nx_migrate_certificate_renewal
[[ ! -s "$ACME_LOG" ]]
if has_acme_cron_task; then exit 1; fi
echo 'ok: quoted cron identity, deduplication, removal, existing ECC migration and idempotence'
# An arbitrary file at the helper name must never suppress the HTTP redirect.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com \
  -keyout "$SSL_DIR/example.com/privkey.pem" -out "$SSL_DIR/example.com/fullchain.pem" >/dev/null 2>&1
build_proxy_conf example.com 18080 3000 "$root/plain-site"
printf 'server { listen 8080; server_name other.example; }\n' > "$CONF_DIR/acme-challenge-example.com.conf"
if nx_https_transform enable "$root/plain-site" example.com "$SSL_DIR" 18443 > "$root/tls" 2> "$root/refusal"; then exit 1; fi
grep -q 'existing ACME helper' "$root/refusal"
rm "$CONF_DIR/acme-challenge-example.com.conf" "$CONF_DIR/site.conf"
ensure_http_challenge_server example.com >/dev/null
nx_https_transform enable "$root/plain-site" example.com "$SSL_DIR" 18443 > "$root/tls"
[[ "$(grep -c '^server {' "$root/tls")" == 2 ]]
echo 'ok: existing challenge helper identity is validated'
