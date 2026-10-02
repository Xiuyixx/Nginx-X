#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/../nx.sh"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
# shellcheck disable=SC2034
SUDO=""
SSL_DIR="$root/ssl"
CONF_DIR="$root/conf"
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
 case "$1" in --key-file|--fullchain-file) printf certificate > "$2"; shift ;; esac
 shift
done
MOCK
chmod +x "$HOME/.acme.sh/acme.sh"
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
[[ -x "$HOME/.acme.sh/nginxx-reload" ]]
sh -n "$HOME/.acme.sh/nginxx-reload"
# Exercise every persisted hook branch without inheriting host uid, PATH,
# systemd state, or init scripts. Only environment paths are substituted.
mkdir "$root/bin" "$root/systemd"
cat > "$root/bin/id" <<'MOCK'
#!/bin/sh
printf '%s\n' "${HOOK_UID:-0}"
MOCK
cat > "$root/bin/sudo" <<'MOCK'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "$HOOK_LOG"
[ "$1" = -n ] || exit 90
[ "${SUDO_FAIL:-0}" = 0 ] || exit "$SUDO_FAIL"
shift
HOOK_UID=0
export HOOK_UID
exec "$@"
MOCK
cat > "$root/bin/nginx" <<'MOCK'
#!/bin/sh
printf 'nginx %s\n' "$*" >> "$HOOK_LOG"
case "$*" in
    -t) exit "${HOOK_FAIL:-0}" ;;
    '-s reload') exit "${RELOAD_FAIL:-0}" ;;
    *) exit 91 ;;
esac
MOCK
cat > "$root/service-mock" <<'MOCK'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "$HOOK_LOG"
exit "${RELOAD_FAIL:-0}"
MOCK
chmod +x "$root/bin/"* "$root/service-mock"
sed -e "s|^PATH=.*|PATH=$root/bin|" \
    -e "s|/run/systemd/system|$root/systemd|g" \
    -e "s|/etc/init.d/nginx|$root/init-nginx|g" \
    "$HOME/.acme.sh/nginxx-reload" > "$root/hook"
chmod +x "$root/hook"
export HOOK_LOG="$root/hook.log" HOOK_UID=0 HOOK_FAIL=0 RELOAD_FAIL=0 SUDO_FAIL=0
for service in systemd openrc sysv direct; do
    rm -f "$root/bin/systemctl" "$root/bin/rc-service" "$root/init-nginx"
    case "$service" in
        systemd) cp "$root/service-mock" "$root/bin/systemctl"; expected='systemctl reload nginx' ;;
        openrc) cp "$root/service-mock" "$root/bin/rc-service"; expected='rc-service nginx reload' ;;
        sysv) cp "$root/service-mock" "$root/init-nginx"; expected='init-nginx reload' ;;
        direct) expected='nginx -s reload' ;;
    esac
    # shellcheck disable=SC2043
    for HOOK_UID in 0; do
        export HOOK_UID
        : > "$HOOK_LOG"
        export HOOK_FAIL=7 RELOAD_FAIL=0
        status=0; "$root/hook" || status=$?
        [[ "$status" == 7 ]]
        [[ "$(grep -vc '^sudo ' "$HOOK_LOG")" == 1 ]]
        grep -qx 'nginx -t' "$HOOK_LOG"
        for RELOAD_FAIL in 8 0; do
            : > "$HOOK_LOG"
            export HOOK_FAIL=0 RELOAD_FAIL
            status=0; "$root/hook" || status=$?
            [[ "$status" == "$RELOAD_FAIL" ]]
            printf 'nginx -t\n%s\n' "$expected" > "$root/expected"
            sed '/^sudo /d' "$HOOK_LOG" > "$root/actual"
            cmp "$root/expected" "$root/actual"
            if [[ "$HOOK_UID" == 1000 ]]; then
                grep -Fxq "sudo -n $root/hook" "$HOOK_LOG"
            else
                if grep -q '^sudo ' "$HOOK_LOG"; then exit 1; fi
            fi
        done
    done
done
: > "$HOOK_LOG"
export HOOK_UID=1000 SUDO_FAIL=9
status=0; "$root/hook" || status=$?
[[ "$status" == 1 && ! -s "$HOOK_LOG" ]]
unset HOOK_UID SUDO_FAIL
grep -q '^nginx -t || exit' "$HOME/.acme.sh/nginxx-reload"
grep -q '^0 3 \* \* \* ' "$root/cron"
grep -q '^7 4 \* \* \* unrelated$' "$root/cron"
ensure_acme_cron
[[ "$(grep -c -- --cron "$root/cron")" == 1 ]]
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
# shellcheck disable=SC1091
source "$(dirname "$0")/../lib/certificates.sh"
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
[[ "$(grep -c -- --cron "$root/cron")" == 2 ]]
disable_acme_cron
grep -q '^0 5 .* /other/' "$root/cron"
if has_acme_cron_task; then exit 1; fi
# Existing acme deploy destinations receive a persisted reload hook on startup;
# unrelated destinations and certificates without an installed key are ignored.
mkdir -p "$HOME/.acme.sh/example.com_ecc" "$HOME/.acme.sh/other.example"
printf "Le_RealKeyPath='%s/example.com/privkey.pem'\nLe_RealFullChainPath='%s/example.com/fullchain.pem'\n" "$SSL_DIR" "$SSL_DIR" > "$HOME/.acme.sh/example.com_ecc/example.com.conf"
printf "Le_RealKeyPath='/other/key.pem'\n" > "$HOME/.acme.sh/other.example/other.example.conf"
: > "$ACME_LOG"
nx_migrate_certificate_renewal
grep -qx -- --ecc "$ACME_LOG"
grep -qx -- --reloadcmd "$ACME_LOG"
[[ "$(grep -c -- --install-cert "$ACME_LOG")" == 1 ]]
# Simulate acme.sh persistence; a second startup performs no deployment.
python3 - "$HOME/.acme.sh/example.com_ecc/example.com.conf" "$HOME/.acme.sh/nginxx-reload" <<'PY'
import sys,base64
cmd="'"+sys.argv[2]+"'"
with open(sys.argv[1],'a') as f:
    f.write("Le_ReloadCmd='__ACME_BASE64__START_"+base64.b64encode(cmd.encode()).decode()+"__ACME_BASE64__END_'\n")
PY
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
