#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2034 # injected read-only probes and transaction mocks
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
source ./nx.sh
T="$(mktemp -d)"
trap 'nx_test_cleanup; rm -rf "$T"' EXIT
bash tools/build-bundle.sh "$T/bundle"
for implementation in ./nx.sh "$T/bundle"; do
 (
  # shellcheck disable=SC1090
  source "$implementation"
  cat > "$T/internal.conf" <<'SITE'
# managed_by=Nginx-X
# backend_port=8317
server { listen 18080; server_name example.test; location / { proxy_pass http://127.0.0.1:8317; } }
SITE
  # Any attempt to mutate or apply configuration is a test failure.
  nx_transaction() { echo 'unexpected transaction' >&2; exit 90; }
  reload_nginx_safe() { echo 'unexpected reload' >&2; exit 91; }
  check_cmd() { [[ "$1" == "$tool" ]]; }
  ss() { [[ "$fail" == 0 ]] || return 1; printf '%s\n' "$fixture_table"; }
  netstat() { [[ "$fail" == 0 ]] || return 1; printf '%s\n' "$fixture_table"; }
  tool=ss; fail=0
  for endpoint in '0.0.0.0:8317' '*:8317' '[::]:8317' ':::8317' '192.0.2.1:8317' '[2001:db8::1]:8317'; do
   fixture_table="State Recv-Q Send-Q Local Address:Port Peer Address:Port
LISTEN 0 128 $endpoint 0.0.0.0:*"
   health_backend_listener_notice "$T/internal.conf" > "$T/out"
   grep -q '后端监听风险 8317' "$T/out"
   grep -q '防火墙及外网可达性未知' "$T/out"
  done
  for endpoint in '127.0.0.1:8317' '127.0.0.2:8317' '[::1]:8317' '[0:0:0:0:0:0:0:1]:8317' '[::ffff:127.0.0.1]:8317'; do
   fixture_table="LISTEN 0 128 $endpoint *:*"
   health_backend_listener_notice "$T/internal.conf" > "$T/out"
   grep -q '仅回环' "$T/out"
   if grep -q '风险' "$T/out"; then exit 1; fi
  done
  fixture_table=$'LISTEN 0 128 127.0.0.1:8317 *:*\nLISTEN 0 128 [::]:8317 [::]:*'
  health_backend_listener_notice "$T/internal.conf" | grep -q '风险'
  fixture_table='LISTEN 0 128 0.0.0.0:18317 *:*'
  health_backend_listener_notice "$T/internal.conf" | grep -q '未发现'
  tool=netstat
  fixture_table='tcp6 0 0 :::8317 :::* LISTEN'
  health_backend_listener_notice "$T/internal.conf" | grep -q '风险'
  fixture_table='tcp 0 0 127.0.0.1:8317 0.0.0.0:* LISTEN'
  health_backend_listener_notice "$T/internal.conf" | grep -q '仅回环'
  # Both native tools failed and fallback is unavailable: unknown, not safe.
  fail=1
  python3() {
   if [[ "$1" == '-' && "$#" == 1 ]]; then return 127; fi
   command python3 "$@"
  }
  health_backend_listener_notice "$T/internal.conf" > "$T/out"
  grep -q '未知' "$T/out"
  if grep -q '风险\|仅回环' "$T/out"; then exit 1; fi
  # A successful command with unrecognized output is also unknown, not safe.
  fail=0; fixture_table='unsupported socket table format'
  health_backend_listener_notice "$T/internal.conf" | grep -q '未知'
  unset -f python3
  fail=0; tool=ss; fixture_table='LISTEN 0 128 unparseable:8317 *:*'
  health_backend_listener_notice "$T/internal.conf" | grep -q '未知'
  # External URL with credentials is not eligible, nor are mismatched metadata.
  # Use a delimiter absent from the URL.
  sed 's|http://127.0.0.1:8317|http://user:privatepassword@origin.test:8317/path?token=privatetoken|' "$T/internal.conf" > "$T/external.conf"
  [[ -z "$(health_backend_listener_notice "$T/external.conf" 2>&1)" ]]
  sed 's/backend_port=8317/backend_port=8318/' "$T/internal.conf" > "$T/mismatch.conf"
  [[ -z "$(health_backend_listener_notice "$T/mismatch.conf")" ]]
  # Real health-check entry integrates the notice without changing probe status.
  tool=ss; fixture_table='LISTEN 0 128 0.0.0.0:8317 *:*'
  health_probe_url() { echo '200|127.0.0.1||0|0'; }
  timeout() { return 1; }
  health_check_conf_file "$T/internal.conf" > "$T/out"
  grep -q '后端监听风险 8317' "$T/out"
  if grep -q 'privatepassword\|privatetoken' "$T/out"; then exit 1; fi
  CONF_DIR="$T"
  nx_site_access_menu "$T/internal.conf" <<< 0 > "$T/out"
  grep -q '阻止 IP 访问不等于隐藏真实 IP' "$T/out"
  grep -q '应用鉴权必须保留' "$T/out"
  nx_access_set_policy() { [[ "$2" == strict ]]; }
  confirm() { return 0; }
  nx_site_access_advanced_menu "$T/internal.conf" <<< 1 > "$T/out"
  grep -q '仅 Nginx 入口已开启' "$T/out"
  grep -q '后端直连未保护' "$T/out"
  nx_access_set_policy() { return 1; }
  if nx_site_access_advanced_menu "$T/internal.conf" <<< 1 > "$T/out"; then exit 1; fi
  if grep -q '仅 Nginx 入口已开启' "$T/out"; then exit 1; fi
 )
done
# Exercise the exact proc fallback Python with in-memory proc fixtures (no
# writable /proc or extra production override). Both address families required.
python3 - "$PWD/lib/diagnostics.sh" <<'PYPROC'
import contextlib, io, ipaddress, pathlib, sys, unittest.mock
source = pathlib.Path(sys.argv[1]).read_text()
code = source.split("<<'PYLISTEN'\n", 1)[1].split("\nPYLISTEN", 1)[0]
def encoded(address):
    import ipaddress
    raw = ipaddress.ip_address(address).packed
    return b"".join(int.from_bytes(raw[i:i+4], 'big').to_bytes(4, sys.byteorder)
                    for i in range(0, len(raw), 4)).hex().upper()
def table(addresses):
    return "header\n" + "".join("0: " + encoded(addr) + ":207D 00000000:0000 " + state + "\n"
                                 for addr, state in addresses)
def run(tcp, tcp6, fail=False):
    def read(path):
        if fail and str(path).endswith('tcp6'): raise PermissionError()
        return tcp6 if str(path).endswith('tcp6') else tcp
    out = io.StringIO()
    try:
        with unittest.mock.patch.object(pathlib.Path, 'read_text', read), contextlib.redirect_stdout(out):
            exec(compile(code, '<production-proc-parser>', 'exec'), {})
    except SystemExit as error:
        assert error.code == 1
        return None
    return out.getvalue().splitlines()
def normalize(endpoints):
    return [(str(ipaddress.ip_address(host.strip('[]'))), int(port))
            for host, port in (endpoint.rsplit(':', 1) for endpoint in endpoints)]
assert normalize(run(table([('0.0.0.0','0A'),('127.0.0.1','0A'),('192.0.2.1','01')]),
           table([('::','0A'),('::1','0A'),('::ffff:127.0.0.1','0A')]))) == normalize([
    '0.0.0.0:8317','127.0.0.1:8317','[::]:8317','[::1]:8317','[::ffff:7f00:1]:8317'])
assert run(table([('192.0.2.1','0A')]),table([('2001:db8::1','0A')])) == [
    '192.0.2.1:8317','[2001:db8::1]:8317']
assert run('header\n', 'header\n', True) is None
assert run('header\nmalformed\n', 'header\n') is None
print('ok: production proc TCP/TCP6 native endian, LISTEN filtering and unavailable/malformed tables')
PYPROC
echo 'ok: read-only internal backend IPv4/IPv6 risk, loopback, unknown, redaction and menu scope (source/bundle)'
