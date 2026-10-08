#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
# shellcheck disable=SC1091
source "$(dirname "$0")/../nx.sh"
trap nx_test_cleanup EXIT
# shellcheck disable=SC2034
SUDO=''
# Real flock, cross-process state, and actual route reconciler; no host writes.
for domain in a.example b.example; do
  path="$(nx_acme_lease_path "$domain")"
  mkfifo "$NX_TEST_ENV_ROOT/$domain.gate"
  (
    exec 9<"$path"
    flock -x 9
    touch "$NX_TEST_ENV_ROOT/$domain.ready"
    read -r _ < "$NX_TEST_ENV_ROOT/$domain.gate"
  ) &
  pid=$!
  if [[ "$domain" == a.example ]]; then apid=$pid; else bpid=$pid; fi
  while [[ ! -f "$NX_TEST_ENV_ROOT/$domain.ready" ]]; do sleep .01; done
  touch "$CONF_DIR/.nx-acme-$domain.state"
  nx_acme_render_helper "$domain" > "$CONF_DIR/acme-challenge-$domain.conf"
done
nx_acme_sync_routes
[[ -f "$CONF_DIR/acme-challenge-a.example.conf" && -f "$CONF_DIR/acme-challenge-b.example.conf" ]]
# Normal completion only reclaims the now idle unsuccessful domain.
echo finish > "$NX_TEST_ENV_ROOT/a.example.gate"
wait "$apid"
nx_acme_sync_routes
[[ ! -f "$CONF_DIR/acme-challenge-a.example.conf" && -f "$CONF_DIR/acme-challenge-b.example.conf" ]]
# Crash releases its lease without requiring a stale PID or expiration timer.
kill -KILL "$bpid"
wait "$bpid" 2>/dev/null || true
nx_acme_sync_routes
[[ ! -f "$CONF_DIR/acme-challenge-b.example.conf" ]]
# Lock inode remains stable for contenders already waiting on it.
[[ -f "$SSL_DIR/.http01-leases/a.example" && -f "$SSL_DIR/.http01-leases/b.example" ]]
echo 'PASS: simultaneous leases, normal cleanup and crash reclamation'
