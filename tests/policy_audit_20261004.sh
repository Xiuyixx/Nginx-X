#!/usr/bin/env bash
# Runs only in a disposable private mount/network namespace, on a repository copy.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" != --isolated ]]; then
  if [[ $EUID != 0 ]] || ! command -v unshare >/dev/null || ! command -v ip >/dev/null; then
    echo 'SKIP: policy audit requires root, unshare and ip for private namespaces'; exit 0
  fi
  if ! unshare --mount --net --fork true 2>/dev/null; then
    echo 'SKIP: private mount/network namespaces unavailable (container capabilities)'; exit 0
  fi
  NGINX_BIN="${NGINX_BIN:-$(command -v nginx || true)}"
  [[ -x "$NGINX_BIN" ]] || { echo 'SKIP: set NGINX_BIN'; exit 0; }
  COPY="$(mktemp -d /tmp/nginxx-policy-copy-XXXXXX)"
  trap 'rm -rf "$COPY"' EXIT
  cp -a "$REPO" "$COPY/repo"
  cp "$NGINX_BIN" "$COPY/nginx"
  unshare --mount --net --fork bash -s -- "$COPY" <<'NS'
set -euo pipefail
copy="$1"
mount --make-rprivate /
for path in /etc /root /usr /var /run /tmp; do
  mount --bind "$path" "$path"; mount -o remount,bind,ro "$path"
done
mount --bind "$copy" "$copy"; mount -o remount,bind,rw "$copy"
mount -t tmpfs tmpfs /run
mkdir /run/policy-copy; mount --bind "$copy" /run/policy-copy
mount -t tmpfs tmpfs /tmp
ip link set lo up
export NGINX_BIN=/run/policy-copy/nginx
bash /run/policy-copy/repo/tests/policy_audit_20261004.sh --isolated
NS
  exit $?
fi
[[ "$(readlink /proc/self/ns/net)" != "$(readlink /proc/1/ns/net)" ]] || {
  echo 'Refusing audit outside private network namespace' >&2; exit 1;
}
T="$(mktemp -d)"; chmod 755 "$T"
export NX_CONF_DIR="$T/conf" STATE_DIR="$T/state" SSL_DIR="$T/ssl" NGINX_MAIN_CONF="$T/nginx.conf"
mkdir -p "$NX_CONF_DIR" "$STATE_DIR" "$SSL_DIR"
# shellcheck disable=SC1091
source "$REPO/nx.sh"
# shellcheck disable=SC2034
SUDO=''
cleanup() {
  if [[ -s "$T/pid" ]]; then
    "$NGINX_BIN" -p "$T" -c "$NGINX_MAIN_CONF" -s quit
    for _ in {1..100}; do [[ -e "$T/pid" ]] || break; sleep .02; done
    [[ ! -e "$T/pid" ]] || return 1
  fi
  rm -rf "$T"
}
trap cleanup EXIT
cat > "$NGINX_MAIN_CONF" <<EOF
pid $T/pid; error_log $T/error; events {} http { access_log off;
client_body_temp_path $T/body; proxy_temp_path $T/proxy; fastcgi_temp_path $T/fastcgi;
uwsgi_temp_path $T/uwsgi; scgi_temp_path $T/scgi;
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }
include $CONF_DIR/*.conf; }
EOF
# shellcheck disable=SC2317
reload_nginx_safe() {
  "$NGINX_BIN" -t -p "$T" -c "$NGINX_MAIN_CONF" || return 1
  [[ ! -s "$T/pid" ]] || "$NGINX_BIN" -p "$T" -c "$NGINX_MAIN_CONF" -s reload
}
printf 'server { listen 127.0.0.1:18880; server_name acme-challenge-user.example; return 200 "private-site"; }\n' > "$T/import"
import_single_conf "$T/import"
site="$CONF_DIR/acme-challenge-user.example-18880.conf"
nx_site_access_menu "$site" <<< 1
list_managed_conf_files 0 | grep -Fx "$site"
grep -q nx-access-begin "$site"
# Creation uses the real template + real transaction, not imported metadata.
build_proxy_conf acme-challenge-created.example 18881 3000 "$T/created"
nx_transaction nx_add_conf "$T/created" "$CONF_DIR/acme-challenge-created.example-18881.conf"
nx_access_set_policy "$CONF_DIR/acme-challenge-created.example-18881.conf" strict
list_managed_conf_files 0 | grep -Fx "$CONF_DIR/acme-challenge-created.example-18881.conf"
# Exact legacy helper shape, not a prefix wildcard, defines helper ownership.
{ echo '# managed_by=Nginx-X'; nx_acme_render_helper helper.example; } > "$CONF_DIR/acme-challenge-helper.example.conf"
if list_managed_conf_files 0 | grep -Fx "$CONF_DIR/acme-challenge-helper.example.conf"; then exit 1; fi
cp "$CONF_DIR/acme-challenge-helper.example.conf" "$T/helper-before"
if nx_access_set_policy "$CONF_DIR/acme-challenge-helper.example.conf" strict; then exit 1; fi
cmp "$T/helper-before" "$CONF_DIR/acme-challenge-helper.example.conf"
rm "$CONF_DIR/acme-challenge-helper.example.conf"
"$NGINX_BIN" -p "$T" -c "$NGINX_MAIN_CONF"
[[ "$(curl --noproxy '*' -fsS http://127.0.0.1:18880/ -H 'Host: acme-challenge-user.example')" == private-site ]]
for host in unknown.example 127.0.0.1; do
  rc=0
  curl --noproxy '*' -sS --max-time 3 http://127.0.0.1:18880/ -H "Host: $host" > "$T/body-result" 2>/dev/null || rc=$?
  [[ $rc == 52 ]] # real Nginx 444, never timeout/unavailable socket
  [[ ! -s "$T/body-result" ]]
done
# HTTP/1.0 omits Host without HTTP/1.1 protocol-level 400 short-circuit.
rc=0
curl --http1.0 --noproxy '*' -sS --max-time 3 http://127.0.0.1:18880/ -H 'Host:' > "$T/body-result" 2>/dev/null || rc=$?
[[ $rc == 52 && ! -s "$T/body-result" ]]
echo 'PASS: imported/created prefix domains managed; exact helper excluded; real Host allowed/rejected'
"$NGINX_BIN" -p "$T" -c "$NGINX_MAIN_CONF" -s quit
for _ in {1..100}; do [[ -e "$T/pid" ]] || break; sleep .02; done
[[ ! -e "$T/pid" ]]
rm "$CONF_DIR"/*.conf
for i in {1..12}; do
  printf '# managed_by=Nginx-X\nserver { listen 127.0.0.1:%s; server_name site%s.example; return 200; }\n' "$((19000+i))" "$i" > "$CONF_DIR/site$i.conf"
done
python3() { echo python >> "$T/python-count"; command python3 "$@"; }
reload_nginx_safe() { echo reload >> "$T/reloads"; }
start=$(date +%s%N)
nx_access_set_policy "$CONF_DIR/site1.conf" strict
end=$(date +%s%N)
echo "FULL_SETTER_SITES=12 PYTHON_PROCESSES=$(wc -l < "$T/python-count") ELAPSED_NS=$((end-start)) RELOADS=$(wc -l < "$T/reloads")"
[[ "$(wc -l < "$T/python-count")" -le 3 && "$(wc -l < "$T/reloads")" == 1 ]]
# Batch must still refuse corruption in a different site and roll everything back.
for corrupt in duplicate marker include name; do
  cp -a "$CONF_DIR" "$T/before"
  case "$corrupt" in
    duplicate) printf '\n# access_policy=open\n# access_policy=strict\n' >> "$CONF_DIR/site12.conf" ;;
    marker) printf '# managed_by=Nginx-X\nserver { listen 19012; server_name site12.example;\n# nx-access-end\n}\n' > "$CONF_DIR/site12.conf" ;;
    include) printf '# managed_by=Nginx-X\nserver { listen 19012; server_name site12.example; include x; }\n' > "$CONF_DIR/site12.conf" ;;
    name) printf '# managed_by=Nginx-X\n# access_policy=strict\nserver { listen 19012; server_name *.example; }\n' > "$CONF_DIR/site12.conf" ;;
  esac
  cp -a "$CONF_DIR" "$T/corrupt"
  if nx_access_set_policy "$CONF_DIR/site1.conf" open; then echo "unsafe success: $corrupt"; exit 1; fi
  diff -qr "$T/corrupt" "$CONF_DIR"
  rm -rf "$CONF_DIR" "$T/corrupt"
  mv "$T/before" "$CONF_DIR"
done
# No cross-round cache: a real edit is consumed by the following setter.
sed -i 's/site12.example/changed12.example/' "$CONF_DIR/site12.conf"
nx_access_set_policy "$CONF_DIR/site12.conf" strict
grep -q 'changed12' "$CONF_DIR/site12.conf"
grep -q nx-access-begin "$CONF_DIR/site12.conf"
echo 'PASS: batch refusals preserved, rollback byte-exact, subsequent round observes edits'
