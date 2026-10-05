#!/usr/bin/env bash
# Real packets/rules only. Service-manager shim records registration, not reboot.
# Opt-in creates mount/PID/network namespaces AND a private read-only host rootfs.
# shellcheck disable=SC1090,SC1091,SC2034,SC2317
set -euo pipefail
if [[ ${NX_BACKEND_ISOLATED:-0} != 1 ]]; then
  echo 'SKIP: backend network proof requires NX_BACKEND_ISOLATED=1 (root + namespaces)'
  exit 0
fi
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ${1:-} != --inside ]]; then
  [[ $EUID == 0 ]] || { echo 'ERROR: isolated proof requires root' >&2; exit 1; }
  for tool in unshare mount chroot ip nft ss nsenter python3 curl; do command -v "$tool" >/dev/null; done
  NGINX_BIN="${NGINX_BIN:-$(command -v nginx || true)}"
  [[ -x "$NGINX_BIN" && -f "$REPO/lib/backend.sh" ]] || {
    echo 'ERROR: real nginx and lib/backend.sh required' >&2; exit 1;
  }
  # Opt-in must fail, not silently skip, if privileged CI lost capabilities.
  unshare --mount --net --pid --fork true
  COPY="$(mktemp -d /tmp/nginxx-backend-proof-XXXXXX)"
  trap 'rm -rf "$COPY"' EXIT
  mkdir "$COPY/rootfs" "$COPY/repo"
  cp -a "$REPO/." "$COPY/repo/"
  cp "$NGINX_BIN" "$COPY/nginx"
  unshare --mount --net --pid --fork bash -s -- "$COPY" <<'NS'
set -euo pipefail
copy="$1"; r="$copy/rootfs"
mount --make-rprivate /
# No writable host directory is exposed to the test or product code.
for path in usr bin sbin lib lib64 etc var; do
  [[ -e /$path ]] || continue
  mkdir -p "$r/$path"
  mount --bind "/$path" "$r/$path"
  mount -o remount,bind,ro "$r/$path"
done
mkdir -p "$r"/{tmp,run,proc,dev,work,root}
mount -t tmpfs tmpfs "$r/tmp"
mount -t tmpfs tmpfs "$r/run"
mount -t tmpfs tmpfs "$r/root"
mount -t proc proc "$r/proc"
mount -t tmpfs tmpfs "$r/dev"
ln -s /proc/self/fd "$r/dev/fd"
ln -s /proc/self/fd/0 "$r/dev/stdin"
ln -s /proc/self/fd/1 "$r/dev/stdout"
ln -s /proc/self/fd/2 "$r/dev/stderr"
for device in null zero random urandom; do
  touch "$r/dev/$device"; mount --bind "/dev/$device" "$r/dev/$device"
done
# /etc remains read-only except these disposable service/project paths.
for path in etc/systemd/system etc/nginx usr/local var/lib var/log; do
  [[ -d "$r/$path" ]] || { echo "ERROR: missing rootfs target $path" >&2; exit 1; }
  mount -t tmpfs tmpfs "$r/$path"
done
mount --bind "$copy/repo" "$r/work"
mount -o remount,bind,ro "$r/work"
cp "$copy/nginx" "$r/tmp/nginx"
exec chroot "$r" /bin/bash /work/tests/backend_protection_isolated.sh --inside
NS
  exit $?
fi
[[ $$ == 1 && -d /work/lib && -x /tmp/nginx ]] || {
  echo 'ERROR: private PID-1 rootfs required' >&2; exit 1;
}
export PATH=/tmp/shim:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 022
chmod 0755 /etc/nginx /etc/systemd/system /usr/local /var/lib /var/log
mkdir -p /tmp/shim /run/systemd/system /usr/local/libexec /etc/nginx/conf.d /var/lib/nginxx
# Only systemd is simulated. nft, ss, ip, nginx and HTTP are real binaries.
cat > /tmp/shim/systemctl <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> /tmp/systemctl.log
case "$1" in
  is-active) echo inactive; exit 3 ;;
  is-enabled) echo disabled; exit 1 ;;
  enable) if [[ -e /tmp/fail-systemctl ]]; then rm -f /tmp/fail-systemctl; exit 1; fi ;;
  *) exit 0 ;;
esac
SHIM
chmod +x /tmp/shim/systemctl
mkdir -p /usr/local/bin
cp /tmp/shim/systemctl /usr/local/bin/systemctl
cp /tmp/nginx /usr/local/bin/nginx
export NX_CONF_DIR=/etc/nginx/conf.d STATE_DIR=/tmp/state NGINX_MAIN_CONF=/etc/nginx/nginx.conf
mkdir -p "$STATE_DIR"
source /work/nx.sh
# Answer only the engine's explicit opt-in confirmation; no network probe mocks.
confirm() { return 0; }
# During parallel development source the new module explicitly if nx.sh has not
# been wired yet. This is still the real implementation, not a test stub.
declare -F nx_backend_enable >/dev/null || source /work/lib/backend.sh
NGINX_BIN=/tmp/nginx
ip link set lo up
unshare --net sleep 10000 & peer=$!
unshare --net sleep 10000 & docker=$!
cleanup() {
  [[ ! -s /tmp/nginx.pid ]] || "$NGINX_BIN" -c "$NGINX_MAIN_CONF" -s quit || true
  kill "$peer" "$docker" "${backend:-}" "${docker_backend:-}" 2>/dev/null || true
}
trap cleanup EXIT
for pid in "$peer" "$docker"; do
  for _ in {1..100}; do
    [[ "$(readlink "/proc/$pid/ns/net")" != "$(readlink /proc/self/ns/net)" ]] && break
    sleep .02
  done
  nsenter -t "$pid" -n ip link set lo up
done
ip link add wan type veth peer name client
ip link set client netns "$peer"
ip addr add 192.0.2.1/24 dev wan
ip -6 addr add 2001:db8:1::1/64 dev wan nodad
ip link set wan up
nsenter -t "$peer" -n ip addr add 192.0.2.2/24 dev client
nsenter -t "$peer" -n ip -6 addr add 2001:db8:1::2/64 dev client nodad
nsenter -t "$peer" -n ip link set client up
ip link add bridgeproof type veth peer name container
ip link set container netns "$docker"
ip addr add 198.51.100.1/24 dev bridgeproof
ip link set bridgeproof up
nsenter -t "$docker" -n ip addr add 198.51.100.2/24 dev container
nsenter -t "$docker" -n ip link set container up
nsenter -t "$docker" -n ip route add default via 198.51.100.1
printf 1 > /proc/sys/net/ipv4/ip_forward
cat > /tmp/backend.py <<'PY'
import http.server, socket, sys
class Server(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body=b'backend-proof\n'
        self.send_response(200); self.end_headers(); self.wfile.write(body)
    def log_message(self, *args): pass
Server(('::', int(sys.argv[1])), Handler).serve_forever()
PY
python3 /tmp/backend.py 18317 & backend=$!
nsenter -t "$docker" -n python3 /tmp/backend.py 18318 & docker_backend=$!
cat > "$NGINX_MAIN_CONF" <<'NGINX'
pid /tmp/nginx.pid; error_log /tmp/nginx.error; events {} http {
access_log off; client_body_temp_path /tmp/body; proxy_temp_path /tmp/proxy;
fastcgi_temp_path /tmp/fastcgi; uwsgi_temp_path /tmp/uwsgi; scgi_temp_path /tmp/scgi;
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
include /etc/nginx/conf.d/*.conf;
}
NGINX
reload_nginx_safe() {
  "$NGINX_BIN" -t -c "$NGINX_MAIN_CONF" || return 1
  [[ ! -s /tmp/nginx.pid ]] || "$NGINX_BIN" -c "$NGINX_MAIN_CONF" -s reload
}
build_proxy_conf proof.example 18080 18317 "$NX_CONF_DIR/proof.conf"
nx_access_set_policy "$NX_CONF_DIR/proof.conf" strict
"$NGINX_BIN" -c "$NGINX_MAIN_CONF"
site="$NX_CONF_DIR/proof.conf"
external() { nsenter -t "$peer" -n curl --noproxy '*' -fsS --connect-timeout 1 --max-time 2 "$1"; }
local_ok() {
  [[ "$(curl --noproxy '*' -fsS --max-time 2 http://127.0.0.1:18080 -H 'Host: proof.example')" == backend-proof ]]
}
blocked() { if external "$1" >/dev/null 2>&1; then echo "ERROR: unexpectedly reachable $1" >&2; exit 1; fi; }
refuse() { if "$@"; then echo "ERROR: unexpectedly accepted $*" >&2; exit 1; fi; }
for _ in {1..100}; do
  curl --noproxy '*' -fsS http://127.0.0.1:18317 >/dev/null 2>&1 && break
  sleep .03
done
[[ "$(external http://192.0.2.1:18317)" == backend-proof ]]
[[ "$(external 'http://[2001:db8:1::1]:18317')" == backend-proof ]]
# Independent existing rules must survive every product operation.
nft -f - <<'NFT'
table inet proof_preserved {
 chain input {
  type filter hook input priority 10; policy accept;
  tcp dport 19999 counter accept
 }
}
table ip proof_docker {
 chain prerouting {
  type nat hook prerouting priority dstnat; policy accept;
  iifname "wan" tcp dport 18317 dnat to 198.51.100.2:18318
 }
}
NFT
nft -s list table inet proof_preserved > /tmp/preserved
nft -s list table ip proof_docker > /tmp/docker.nft
[[ "$(external http://192.0.2.1:18317)" == backend-proof ]]
echo 'PASS: baseline IPv4/IPv6 INPUT and real veth/DNAT FORWARD backend reachable'
nx_backend_enable "$site"
nx_backend_status "$site"
blocked http://192.0.2.1:18317
blocked 'http://[2001:db8:1::1]:18317'
# Also prove native IPv4 INPUT, independent of Docker's DNAT route.
nft delete table ip proof_docker
blocked http://192.0.2.1:18317
nft -f /tmp/docker.nft
local_ok
rc=0
curl --noproxy '*' -sS --max-time 2 http://127.0.0.1:18080 -H 'Host: wrong.example' >/tmp/wrong 2>/dev/null || rc=$?
[[ $rc == 52 && ! -s /tmp/wrong ]]
echo 'PASS: native INPUT v4/v6 and pre-DNAT v4 blocked; local nginx exact Host works; wrong Host is real 444'
nft -s list ruleset >/tmp/enabled.rules
nx_backend_enable "$site"
nft -s list ruleset >/tmp/repeated.rules
cmp /tmp/enabled.rules /tmp/repeated.rules
# Live drift must be visible and veto real configuration transactions; explicit enable repairs.
for drift in chain table; do
  if [[ "$drift" == chain ]]; then
    nft flush chain inet nginxx_backend_guard prerouting
  else
    nft delete table inet nginxx_backend_guard
  fi
  refuse nx_backend_status "$site"
  refuse nx_transaction true
  nx_backend_enable "$site"
  blocked http://192.0.2.1:18317
  blocked 'http://[2001:db8:1::1]:18317'
done
# Real transaction changes to protected files roll back byte-for-byte.
cp "$site" /tmp/protected-original
change_protected() { sed -i 's/127.0.0.1:18317/127.0.0.1:18999/' "$site"; }
refuse nx_transaction change_protected
cmp "$site" /tmp/protected-original
chmod 0666 "$site"
refuse nx_backend_enable "$site"
chmod 0644 "$site"
chown 65534 "$site"
refuse nx_backend_enable "$site"
chown 0 "$site"
echo 'PASS: live drift status/real transaction veto/repair, byte-exact rollback and unsafe site permissions'
# A second site's reference keeps the same port protected.
build_proxy_conf shared.example 18081 18317 "$NX_CONF_DIR/shared.conf"
nx_access_set_policy "$NX_CONF_DIR/shared.conf" strict
nx_backend_enable "$NX_CONF_DIR/shared.conf"
nx_backend_disable "$site"
blocked http://192.0.2.1:18317
nx_backend_disable "$NX_CONF_DIR/shared.conf"
[[ "$(external http://192.0.2.1:18317)" == backend-proof ]]
[[ "$(external 'http://[2001:db8:1::1]:18317')" == backend-proof ]]
nx_backend_disable "$site"
echo 'PASS: repeated enable/disable and shared-port reference; disable restores both families'
# Unknown/no-listener and privileged SSH target must never be protected.
build_proxy_conf unknown.example 18082 18999 "$NX_CONF_DIR/unknown.conf"
nx_access_set_policy "$NX_CONF_DIR/unknown.conf" strict
refuse nx_backend_enable "$NX_CONF_DIR/unknown.conf"
build_proxy_conf ssh.example 18083 22 "$NX_CONF_DIR/ssh.conf"
nx_access_set_policy "$NX_CONF_DIR/ssh.conf" strict
refuse nx_backend_enable "$NX_CONF_DIR/ssh.conf"
# Service-registration fault must roll back actual nft rules and exposure.
nft -s list ruleset >/tmp/before-failure
: > /tmp/fail-systemctl
refuse nx_backend_enable "$site"
rm -f /tmp/fail-systemctl
nft -s list ruleset >/tmp/after-failure
cmp /tmp/before-failure /tmp/after-failure
[[ "$(external http://192.0.2.1:18317)" == backend-proof ]]
echo 'PASS: SSH/unknown refusal and actual-rule rollback after service failure'
nx_backend_enable "$site"
# Reject a staged edit of the protected site; unchanged snapshot is accepted.
mkdir -p /tmp/snapshot
cp "$NX_CONF_DIR"/*.conf /tmp/snapshot/
nx_backend_guard_snapshot /tmp/snapshot
sed -i 's/127.0.0.1:18317/127.0.0.1:18999/' /tmp/snapshot/proof.conf
refuse nx_backend_guard_snapshot /tmp/snapshot
refuse nx_backend_uninstall_guard
# Boot replay: invoke precisely the installed unit's ExecStart in this namespace.
# Removing only the product table models rules lost on boot, not a reboot.
unit="$(grep -l 'nginxx\|Nginx-X' /etc/systemd/system/*.service | head -1)"
[[ -n "$unit" ]]
execstart="$(sed -n 's/^ExecStart=//p' "$unit")"
[[ -n "$execstart" && "$execstart" != *'%'* ]]
table="$(nft list tables | awk '$3 ~ /nginxx|nginx_x|nx_backend/ { print $2 " " $3 }')"
[[ -n "$table" && "$(wc -l <<< "$table")" == 1 ]]
read -r family name <<< "$table"
nft delete table "$family" "$name"
[[ "$(external http://192.0.2.1:18317)" == backend-proof ]]
# Unit uses trusted generated absolute paths; bash parses its ExecStart quoting.
bash -c "$execstart"
blocked http://192.0.2.1:18317
blocked 'http://[2001:db8:1::1]:18317'
local_ok
echo 'PASS: installed boot ExecStart actually replays nft protection after table loss (systemd reboot NOT tested)'
nx_backend_disable "$site"
nx_backend_uninstall_guard
nft -s list table inet proof_preserved >/tmp/preserved-after
cmp /tmp/preserved /tmp/preserved-after
[[ "$(external http://192.0.2.1:18317)" == backend-proof ]]
[[ "$(external 'http://[2001:db8:1::1]:18317')" == backend-proof ]]
echo 'PASS: independent nft table preserved; all actual traffic restored; no host firewall/service mutation'
