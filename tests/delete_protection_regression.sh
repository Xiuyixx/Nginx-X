#!/usr/bin/env bash
# shellcheck disable=SC2317 # mocks invoked indirectly by dynamically sourced delete_conf
# Explicit preflight retains the documented protected-site lifecycle veto.
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'nx_test_cleanup; rm -rf "$T"' EXIT
bash "$ROOT/tools/build-bundle.sh" "$T/bundle"
for entry in "$ROOT/nx.sh" "$T/bundle"; do
(
  # shellcheck disable=SC1090
  source "$entry"
  CONF_DIR="$T/conf"
  NX_BACKEND_STATE_DIR="$T/backend"
  mkdir -p "$CONF_DIR" "$NX_BACKEND_STATE_DIR"
  printf original > "$CONF_DIR/site.conf"
  printf shared > "$CONF_DIR/other.conf"
  fixture_backend='{"sites": {"site": {"ports": [8317]}}}'
  nx_backend_status() { printf '%s\n' "$fixture_backend"; }
  confirm() { touch "$T/confirmed"; return 0; }
  nx_transaction() { touch "$T/transaction"; rm "$2"; }
  if delete_conf site.conf > "$T/result" 2>&1; then exit 1; fi
  grep -q '仍启用后端保护' "$T/result"
  [[ $(cat "$CONF_DIR/site.conf") == original && $(cat "$CONF_DIR/other.conf") == shared ]]
  [[ ! -e "$T/confirmed" && ! -e "$T/transaction" ]]
  nx_backend_status() { return 1; }
  if delete_conf site.conf > "$T/result" 2>&1; then exit 1; fi
  grep -q '无法确认' "$T/result"
  [[ ! -e "$T/transaction" ]]
  nx_backend_status() { echo '{"sites": {}}'; }
  confirm() { return 1; }
  delete_conf site.conf
  [[ -f "$CONF_DIR/site.conf" && ! -e "$T/transaction" ]]
  confirm() { return 0; }
  delete_conf site.conf
  [[ ! -e "$CONF_DIR/site.conf" && -f "$CONF_DIR/other.conf" && -e "$T/transaction" ]]
  rm "$T/transaction"
)
done
echo 'PASS: source/bundle protected-delete preflight, unknown status, cancellation and unprotected deletion'
