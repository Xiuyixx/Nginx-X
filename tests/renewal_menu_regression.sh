#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2317,SC2034
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
root="$NX_TEST_ENV_ROOT"

for entry in "$PWD/nx.sh" "$root/bundle"; do
  [[ "$entry" == "$PWD/nx.sh" ]] || bash tools/build-bundle.sh "$entry"
  (
    source "$entry"
    clear() { :; }
    pause() { echo PAUSE; read -r _ || :; }
    SUDO=''
    HOME="$root/home"; mkdir -p "$HOME/.acme.sh"
    NX_PERIODIC_DIR="$root/periodic"
    nx_acme_privileged_paths() { NX_ACME_DISPATCH="$root/dispatch"; }
    crontab() {
      [[ "$1" == -l ]] || { echo UNEXPECTED_WRITE >> "$root/effects"; return 1; }
      [[ ${READ_FAIL:-0} == 0 ]] || { echo denied >&2; return 6; }
      cat "$root/cron"
    }
    nx_acme_account_crontab() { crontab "$@"; }
    : > "$root/cron"
    [[ $(nx_acme_renewal_status) == 已关闭* ]]
    READ_FAIL=1
    [[ $(nx_acme_renewal_status) == 未知* ]]
    READ_FAIL=0
    printf '0 3 * * * %s/dispatch cron\n' "$root" > "$root/cron"
    [[ $(nx_acme_renewal_status) == 已开启 ]]
    printf '0 3 * * * "%s/.acme.sh/acme.sh" --cron\n' "$HOME" > "$root/cron"
    [[ $(nx_acme_renewal_status) == 已开启 ]]
    printf '0 3 * * * /other/acme.sh --cron\n' > "$root/cron"
    [[ $(nx_acme_renewal_status) == 已关闭* ]]
    state=unknown
    nx_acme_renewal_status() { printf '%s\n' "$state"; }
    enable_acme_cron() { echo ENABLE >> "$root/effects"; }
    disable_acme_cron() { echo DISABLE >> "$root/effects"; }
    : > "$root/effects"

    state='未知（无法读取续期调度）'
    rc=0; nx_acme_renewal_menu <<< 0 > "$root/out" || rc=$?
    [[ $rc == 10 ]]
    grep -q '未知（无法读取续期调度）' "$root/out"
    [[ ! -s "$root/effects" ]]

    nx_acme_renewal_menu <<< $'1\ny' > "$root/out"
    grep -q '影响当前 ACME 账户下的全部证书' "$root/out"
    [[ "$(cat "$root/effects")" == ENABLE ]]
    rc=0; nx_acme_renewal_menu <<< $'2\nn' > "$root/out" || rc=$?
    [[ $rc == 10 ]]
    [[ "$(cat "$root/effects")" == ENABLE ]]

    for state in 已开启 已关闭 未知; do
      : > "$root/effects"
      cert_list_action_menu example.com <<< $'2\n1\ny\n\n2\n1\ny\n\n2\n2\ny\n\n2\n2\ny\n\n0' > "$root/out"
      [[ $(cat "$root/effects") == $'ENABLE\nENABLE\nDISABLE\nDISABLE' ]]
      [[ $(grep -c '^PAUSE$' "$root/out") == 4 ]]
      for input in $'2\n0\n0' $'2\n1\nn\n0' $'2\n2\nn\n0' 2; do
        : > "$root/effects"
        cert_list_action_menu example.com <<< "$input" > "$root/out"
        [[ ! -s "$root/effects" && $(grep -c '^PAUSE$' "$root/out") == 0 ]]
      done
    done
    : > "$root/effects"
    cert_list_action_menu example.com <<< $'2\nbad\n\n0' > "$root/out"
    [[ ! -s "$root/effects" && $(grep -c '^PAUSE$' "$root/out") == 1 ]]
    enable_acme_cron() { return 1; }
    cert_list_action_menu example.com <<< $'2\n1\ny\n\n0' > "$root/out"
    [[ ! -s "$root/effects" && $(grep -c '^PAUSE$' "$root/out") == 1 ]]
    grep -q 操作未完成 "$root/out"

    # The certificate-menu alias must never turn enable into disable.
    site="$CONF_DIR/example.com-18080.conf"
    build_proxy_conf example.com 18080 3000 "$site" normal
    conf_https_enabled() { return 0; }
    disable_https_for_conf_file() { echo WRONG_DISABLE >> "$root/effects"; }
    enable_https_for_domain <<< 1 > "$root/out"
    [[ ! -s "$root/effects" ]]
    grep -q 无需重复操作 "$root/out"

    # The certificate action wrapper preserves one result pause while the
    # submenu's 0/EOF navigation remains pause-free and does not mutate state.
    : > "$root/effects"
    cert_list_action_menu example.com <<< $'2\n0\n0' > "$root/out"
    [[ $(grep -c '^PAUSE$' "$root/out") == 0 ]]
    [[ ! -s "$root/effects" ]]
    cert_list_action_menu example.com < /dev/null > "$root/out"
    [[ $(grep -c '^PAUSE$' "$root/out") == 0 ]]
  )
done
echo 'PASS: account-level renewal menu status, explicit actions, cancel and EOF (source/bundle)'
