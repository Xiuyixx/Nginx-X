#!/usr/bin/env bash
# Dynamic source and production callbacks assign state and invoke mocks indirectly.
# shellcheck disable=SC1090,SC2016,SC2034,SC2153,SC2251,SC2317
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
root="$NX_TEST_ENV_ROOT"
bash tools/build-bundle.sh "$root/bundle"

for entry in ./nx.sh "$root/bundle"; do
  (
    source "$entry"
    SUDO=''
    valid_port 1
    valid_port 65535
    valid_port 0 && exit 1
    valid_port 00080 && exit 1
    valid_port 08 && exit 1
    valid_port 65536 && exit 1
    valid_port 18446744073709551696 && exit 1
    valid_ipv4_host 192.168.1.10
    valid_ipv4_host 192.168.001.010 && exit 1
    valid_ipv4_host 192.168.1.08 && exit 1
    valid_ipv4_host 256.1.1.1 && exit 1

    email_payload="\$(touch $root/email-pwned)"
    printf 'ACME_EMAIL=%s\n' "$email_payload" > "$EMAIL_CONF"
    chmod 600 "$EMAIL_CONF"
    load_email
    [[ "$ACME_EMAIL" == "$email_payload" ]]
    [[ ! -e "$root/email-pwned" ]]

    mkdir -p "$(dirname "$DNS_CONF")"
    dns_payload="\$(touch $root/dns-pwned)"
    printf 'DNS_PROVIDER=cf\nDNS_KEY1=%s\n' "$dns_payload" > "$DNS_CONF"
    chmod 600 "$DNS_CONF"
    load_dns_conf
    [[ "$DNS_KEY1" == "$dns_payload" ]]
    [[ ! -e "$root/dns-pwned" ]]

    # Empty values, legacy quoted state and UTF-8 credentials round-trip.
    save_dns_conf cf token ''
    load_dns_conf
    [[ "$DNS_PROVIDER" == cf && "$DNS_KEY1" == token && -z "$DNS_KEY2" ]]
    printf 'DNS_PROVIDER="cf"\nDNS_KEY1="legacy-token"\nDNS_KEY2=""\n' > "$DNS_CONF"
    chmod 600 "$DNS_CONF"
    load_dns_conf
    [[ "$DNS_PROVIDER" == cf && "$DNS_KEY1" == legacy-token && -z "$DNS_KEY2" ]]
    unicode_key='中文密钥'
    LC_ALL=C save_dns_conf he "$unicode_key" second
    load_dns_conf
    [[ "$DNS_KEY1" == "$unicode_key" ]]

    # Unsafe state cannot be treated as absent configuration or overwriteable
    # input. Failed export must report failure without replacing the environment.
    printf 'DNS_PROVIDER=cf\nDNS_KEY1=stale\n' > "$DNS_CONF"
    chmod 644 "$DNS_CONF"
    CF_Token=stale-token
    if export_dns_env; then exit 1; fi
    [[ "$CF_Token" == stale-token ]]
    printf 'ACME_EMAIL=old@example.com\n' > "$EMAIL_CONF"
    chmod 644 "$EMAIL_CONF"
    if ensure_email_interactive <<< 'new@example.com'; then exit 1; fi
    [[ "$(cat "$EMAIL_CONF")" == 'ACME_EMAIL=old@example.com' ]]

    rm -f "$CONF_DIR"/* "$CONF_DIR"/.[!.]*
    printf '# managed_by=Nginx-X\n# domain=Example.com\n# listen_port=18080\nserver { listen 18080; server_name Example.com; }\n' > "$CONF_DIR/example.com-18080.conf.bak"
    if nx_assert_new_target "$CONF_DIR/Example.com-18080.conf"; then exit 1; fi

    # Use a complete native template and require success; a refused edit
    # cannot count as evidence that the disabled state was preserved.
    rm -f "$CONF_DIR"/*
    ipv6_available() { return 1; }
    is_port_used_os() { return 1; }
    reload_nginx_safe() { echo reload >> "$root/reloads"; }
    for suffix in old disabled; do
      build_proxy_conf example.com 18081 3000 "$CONF_DIR/example.com-18081.conf.$suffix"
      modify_conf "example.com-18081.conf.$suffix" <<< $'\n18082\n\n1\n' > "$root/disabled-edit" 2>&1
      [[ -f "$CONF_DIR/example.com-18082.conf.bak" ]]
      [[ ! -e "$CONF_DIR/example.com-18082.conf" && ! -e "$CONF_DIR/example.com-18081.conf.$suffix" ]]
      rm -f "$CONF_DIR"/*
    done
  )
done
echo 'ok: decimal input bounds, non-executing state parsing, and normalized site identity validation'
