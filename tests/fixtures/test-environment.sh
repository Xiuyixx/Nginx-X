#!/usr/bin/env bash
# Source before nx.sh: no default product path may reference the host system.
# shellcheck disable=SC2034
NX_TEST_ENV_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/nginxx-test-env-XXXXXX")" || return 1
export NX_CONF_DIR="$NX_TEST_ENV_ROOT/conf" SSL_DIR="$NX_TEST_ENV_ROOT/ssl"
export STATE_DIR="$NX_TEST_ENV_ROOT/state" NGINX_MAIN_CONF="$NX_TEST_ENV_ROOT/nginx.conf"
unset DOMAIN_ONLY_STATE
# Product derives shared policy from the overridden CONF_DIR after source.
mkdir -p "$NX_CONF_DIR" "$SSL_DIR" "$STATE_DIR" || return 1
for nx_test_path in "$NX_CONF_DIR" "$SSL_DIR" "$STATE_DIR" "$NGINX_MAIN_CONF"; do
  [[ "$nx_test_path" == "$NX_TEST_ENV_ROOT/"* ]] || return 1
done
nx_test_cleanup() { rm -rf "$NX_TEST_ENV_ROOT"; }
trap nx_test_cleanup EXIT

# Quit/kill requests are asynchronous: wait before deleting a live prefix.
nx_test_wait_pidfile() {
  python3 - "$1" <<'PYWAIT'
import pathlib, sys, time
p = pathlib.Path(sys.argv[1])
for _ in range(250):
    if not p.exists(): break
    time.sleep(.02)
else: raise SystemExit('isolated nginx did not remove its pidfile')
PYWAIT
}
