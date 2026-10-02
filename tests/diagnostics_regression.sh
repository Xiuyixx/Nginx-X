#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2218 # function overridden after testing original
set -euo pipefail
cd "$(dirname "$0")/.."
source ./nx.sh
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cat > "$T/site.conf" <<'EOF'
server { listen 127.0.0.2:18443 ssl; listen [::1]:18443 ssl; server_name main.example alias.example; }
EOF
cat > "$T/log" <<'EOF'
nx1 alias.example 1048576 18443 https main.example
nx1 main.example 1048576 18443 https main.example
nx1 main.example 99 80 http main.example
EOF
nx_traffic_rows "$T/log" "$T/site.conf" > "$T/out"
grep -q '请求: 2 | 下行: 2.00' "$T/out"
printf 'nx1 other.example 0 80 http other.example\n' > "$T/log"
nx_traffic_rows "$T/log" "$T/site.conf" | grep -q '请求: 0'
printf 'combined nonsense\n' > "$T/log"
nx_traffic_rows "$T/log" "$T/site.conf" | grep -q '请求: N/A'
: > "$T/log"
nx_traffic_rows "$T/log" "$T/site.conf" | grep -q '请求: N/A'
# Endpoint validation and timeout contract, including valid zero counters.
curl() {
  printf '%s\n' "$*" > "$T/curl"
  cat "$T/body"
}
printf 'Active connections: 0\nserver accepts handled requests\n 0 0 0\nReading: 0 Writing: 0 Waiting: 0\n' > "$T/body"
[[ "$(nx_stub_status)" == '0 0 0 0 0 0 0' ]]
grep -q -- '--connect-timeout 1 --max-time 2' "$T/curl"
printf 'not nginx\n' > "$T/body"
if nx_stub_status; then exit 1; fi
printf '200|127.0.0.2|https://main.example:18443|0' > "$T/body"
health_probe_url https://main.example:18443 'main.example:18443:127.0.0.2' >/dev/null
grep -q -- '--resolve main.example:18443:127.0.0.2' "$T/curl"
if grep -q -- ' -k\| -L' "$T/curl"; then exit 1; fi
if health_probe_label 200 20 0 >/dev/null; then exit 1; fi
if health_probe_label 200 0 28 >/dev/null; then exit 1; fi
health_probe_label 200 0 0 >/dev/null
health_probe_url() { printf '%s\n' "$*" >> "$T/probes"; echo '200|127.0.0.2||0|0'; }
timeout() { return 1; }
getent() { :; }
health_check_conf_file "$T/site.conf" > "$T/out"
grep -q 'main.example:18443:127.0.0.2' "$T/probes"
grep -q 'main.example:18443:\[::1\]' "$T/probes"
grep -q '公网/CDN' "$T/out"
grep -q '本机直连' "$T/out"
bash tools/build-bundle.sh "$T/bundle"
bash -c 'source "$1"; declare -F nx_stub_status nx_traffic_rows health_probe_url >/dev/null' _ "$T/bundle"
echo 'diagnostics regression: OK'
# Batch interface must avoid per-file parser calls once shared parser supports it.
(
  nx_conf_query() {
    [[ "$1" == traffic ]] || exit 9
    printf 'SITE|site.conf\nKEY|site.conf|alias.example|18443\n'
  }
  printf 'nx1 alias.example 0 18443 https alias.example\n' > "$T/log"
  nx_traffic_rows "$T/log" "$T/site.conf" | grep -q '请求: 1'
)
