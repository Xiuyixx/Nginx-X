#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
source ./nx.sh
source ./lib/access.sh
root=$(mktemp -d)
trap '[[ ! -f "$root/nginx.pid" ]] || kill "$(cat "$root/nginx.pid")" 2>/dev/null || :; nx_test_wait_pidfile "$root/nginx.pid"; rm -rf "$root"; nx_test_cleanup' EXIT
CONF_DIR="$root/conf"; DOMAIN_ONLY_STATE="$root/state"; SUDO=''
mkdir -p "$CONF_DIR"
nginx_bin=${NGINX_TEST_BIN:-$(command -v nginx || true)}
# Detect capabilities from the same binary used for real validation below.
nginx_local_version() {
 [[ -x "$nginx_bin" ]] || return 0
 "$nginx_bin" -v 2>&1 | sed -E 's#^nginx version: nginx/##'
}
cat > "$CONF_DIR/site.conf" <<'EOF'
# managed_by=Nginx-X
server {
 listen 127.0.0.1:19876;
 server_name a.example b.example;
 location / { return 200 'preserved'; }
}
EOF
printf 'DOMAIN_ONLY=1\n' > "$DOMAIN_ONLY_STATE"
nx_access_sync_files
grep -q 'listen 127.0.0.1:19876 default_server;' "$(domain_only_conf_path)"
if grep -q '\[::\]' "$(domain_only_conf_path)"; then exit 1; fi
grep -q "return 200 'preserved'" "$CONF_DIR/site.conf"
cp "$CONF_DIR/site.conf" "$root/before"
nx_access_sync_files
cmp "$root/before" "$CONF_DIR/site.conf"
# An explicit default owns only its address and keeps strict guards.
nx_access_set_default_files "$CONF_DIR/site.conf" 127.0.0.1:19876
nx_access_sync_files
[[ ! -f "$(domain_only_conf_path)" ]]
grep -q 'nx-access-default' "$CONF_DIR/site.conf"
nx_access_sync_files
# Clear managed default and choose a deliberate open default.
nx_access_set_policy_files "$CONF_DIR/site.conf" open
nx_access_sync_files
if grep -q 'nx-access-begin' "$CONF_DIR/site.conf"; then exit 1; fi
nx_access_set_default_files "$CONF_DIR/site.conf" ''
nx_access_set_policy_files "$CONF_DIR/site.conf" strict
nx_access_sync_files
# Reject hidden includes and regex names without modifying the file.
cp "$CONF_DIR/site.conf" "$root/ambiguous"
sed -i '/server_name/a\ include mystery.conf;' "$root/ambiguous"
if nx_access_parse "$root/ambiguous" transform 1 > /dev/null 2>&1; then exit 1; fi
# Different address defaults cannot suppress our exact-address catchall.
cat > "$CONF_DIR/custom.conf" <<'EOF'
server { listen 127.0.0.2:19876 default_server; server_name custom; return 200; }
EOF
nx_access_sync_files
grep -q '127.0.0.1:19876 default_server' "$(domain_only_conf_path)"
# Conflicting explicit defaults fail before publishing transformations.
nx_access_set_default_files "$CONF_DIR/site.conf" 127.0.0.1:19876
sed -i 's/127.0.0.2/127.0.0.1/' "$CONF_DIR/custom.conf"
if nx_access_sync_files > /dev/null 2>&1; then exit 1; fi
rm "$CONF_DIR/custom.conf"
nx_access_set_default_files "$CONF_DIR/site.conf" ''
nx_access_sync_files
if [[ -x "$nginx_bin" ]]; then
 openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=a.example -keyout "$root/key" -out "$root/cert" >/dev/null 2>&1
 cat >> "$CONF_DIR/site.conf" <<EOF
server {
 listen 127.0.0.1:19877 ssl;
 server_name a.example b.example;
 ssl_certificate $root/cert;
 ssl_certificate_key $root/key;
 location / { return 200 'tls'; }
}
EOF
 nx_access_sync_files
 cat > "$root/nginx.conf" <<EOF
pid $root/nginx.pid;
error_log $root/error.log;
events {}
http {
 access_log off;
 client_body_temp_path $root/body;
 proxy_temp_path $root/proxy;
 fastcgi_temp_path $root/fastcgi;
 uwsgi_temp_path $root/uwsgi;
 scgi_temp_path $root/scgi;
 include $CONF_DIR/*.conf;
}
EOF
 "$nginx_bin" -t -p "$root/" -c "$root/nginx.conf"
 "$nginx_bin" -p "$root/" -c "$root/nginx.conf"
 [[ $(curl --noproxy '*' -s http://127.0.0.1:19876 -H 'Host: b.example') == preserved ]]
 if curl --noproxy '*' -s http://127.0.0.1:19876 -H 'Host: wrong.example'; then exit 1; fi
 [[ $(curl --noproxy '*' -sk --resolve a.example:19877:127.0.0.1 https://a.example:19877) == tls ]]
 if curl --noproxy '*' -sk --resolve a.example:19877:127.0.0.1 https://a.example:19877 -H 'Host: b.example'; then exit 1; fi
 if curl --noproxy '*' -sk https://127.0.0.1:19877 -H 'Host: a.example'; then exit 1; fi
fi
echo 'access policy regression: ok'
