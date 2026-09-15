#!/usr/bin/env bash
set -euo pipefail

if ! command -v nginx >/dev/null 2>&1; then
  echo "skip: nginx is not installed"
  exit 0
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# shellcheck disable=SC1091
source nx.sh

SUDO=""
CONF_DIR="$TMPDIR_ROOT/conf.d"
SSL_DIR="$TMPDIR_ROOT/ssl"
NGINX_MAIN_CONF="$TMPDIR_ROOT/nginx.conf"
mkdir -p "$CONF_DIR" "$SSL_DIR/external.example.com"

ipv6_available() { return 1; }

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=external.example.com' \
  -keyout "$SSL_DIR/external.example.com/privkey.pem" \
  -out "$SSL_DIR/external.example.com/fullchain.pem" >/dev/null 2>&1

cat > "$NGINX_MAIN_CONF" <<EOF
pid ${TMPDIR_ROOT}/nginx.pid;
error_log stderr;
events {}
http {
    access_log off;
    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        '' close;
    }
    include ${CONF_DIR}/*.conf;
}
EOF

build_proxy_conf \
  "internal.example.com" \
  "18080" \
  "3000" \
  "$CONF_DIR/internal.conf"

build_external_proxy_conf \
  "external.example.com" \
  "18443" \
  "https://127.0.0.1:9443" \
  "normal" \
  "$CONF_DIR/external.conf" \
  "1"

nginx_cmd=(nginx)
if [[ ${EUID:-0} -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
  nginx_cmd=(sudo nginx)
fi
"${nginx_cmd[@]}" -t -p "$TMPDIR_ROOT/" -c "$NGINX_MAIN_CONF"
echo "generated configs passed nginx -t"
