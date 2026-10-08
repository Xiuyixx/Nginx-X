#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/../nx.sh"
trap nx_test_cleanup EXIT
export HOME="$NX_TEST_ENV_ROOT/home"
mkdir -p "$HOME/.acme.sh"
# Shell payloads are literal adversarial fixtures, never executed.
# shellcheck disable=SC2016
for tail in '>/dev/null; /usr/bin/backup' '>/dev/null&&backup' '>/dev/null||backup' '|backup' '&backup' '$(backup)' '`backup`' ';backup' '>/dev/null 2>&1;backup' '--home $(backup)' '%backup' '> >(backup)' '>/tmp/important'; do
  printf '0 3 * * * %s/.acme.sh/acme.sh --cron %s\n' "$HOME" "$tail" > "$NX_TEST_ENV_ROOT/input"
  nx_acme_cron_filter remove < "$NX_TEST_ENV_ROOT/input" > "$NX_TEST_ENV_ROOT/output"
  cmp "$NX_TEST_ENV_ROOT/input" "$NX_TEST_ENV_ROOT/output"
  if nx_acme_cron_filter probe < "$NX_TEST_ENV_ROOT/input"; then exit 1; fi
  { echo '#!/bin/sh'; cut -d ' ' -f 6- "$NX_TEST_ENV_ROOT/input"; } > "$NX_TEST_ENV_ROOT/periodic"
  if nx_acme_periodic_owned "$NX_TEST_ENV_ROOT/periodic"; then exit 1; fi
done
for tail in '' '>/dev/null' '>/dev/null 2>&1' '>/dev/null 2>/dev/null'; do
  printf '0 3 1 */2 * "%s/.acme.sh"/acme.sh --cron --home "%s/.acme.sh" %s\n' "$HOME" "$HOME" "$tail" > "$NX_TEST_ENV_ROOT/input"
  nx_acme_cron_filter remove < "$NX_TEST_ENV_ROOT/input" > "$NX_TEST_ENV_ROOT/output"
  [[ ! -s "$NX_TEST_ENV_ROOT/output" ]]
  nx_acme_cron_filter probe < "$NX_TEST_ENV_ROOT/input"
  nx_acme_cron_filter daily < "$NX_TEST_ENV_ROOT/input" | grep -q '^0 3 \* \* \* '
done
echo 'PASS: conservative full-command cron/periodic ownership and legacy migration'
