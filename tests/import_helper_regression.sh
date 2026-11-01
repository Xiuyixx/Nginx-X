#!/usr/bin/env bash
# Deleting a site keeps its port-80 ACME challenge route so the retained
# certificate can still renew.  That helper has no managed header, so both the
# import scanner and the new-site duplicate guard must recognise it as a
# generated helper instead of a site.
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
  # shellcheck disable=SC2034 # consumed by the sourced helpers below
  SUDO=""
  CONF_DIR="$NX_CONF_DIR"
  HELPER="$CONF_DIR/acme-challenge-api.x17.xyz.conf"

  # Exact body produced by nx_acme_render_helper after the site is deleted.
  cat > "$HELPER" <<'EOF'
# nx_helper=acme-http01
server {
    listen 80;
    server_name api.x17.xyz;
    location ^~ /.well-known/acme-challenge/ {
        root /usr/share/nginx/html;
        default_type "text/plain";
        try_files $uri =404;
    }
    location / { return 404; }
}
EOF

  # An unrelated legacy config must still be offered for import.
  cat > "$CONF_DIR/legacy-site.conf" <<'EOF'
server {
    listen 8080;
    server_name legacy.example.com;
    location / { return 200; }
}
EOF

  # A managed site is never offered for import.
  cat > "$CONF_DIR/managed-site-81.conf" <<'EOF'
# managed_by=Nginx-X
server {
    listen 81;
    server_name managed.example.com;
    location / { return 200; }
}
EOF

  mapfile -t scanned < <(_scan_unmanaged_confs)
  printf '%s\n' "${scanned[@]:-}" > "$T/scanned"
  grep -qx "$CONF_DIR/legacy-site.conf" "$T/scanned"
  if grep -qx "$HELPER" "$T/scanned"; then
    echo "helper leaked into the import scan: $HELPER" >&2
    exit 1
  fi
  if grep -qx "$CONF_DIR/managed-site-81.conf" "$T/scanned"; then
    echo 'managed site leaked into the import scan' >&2
    exit 1
  fi

  # The retained challenge route must not block recreating the same domain.
  nx_assert_new_target "$CONF_DIR/api.x17.xyz-80.conf"

  # A real site still guards its domain/port, including renamed HTTPS saves.
  cat > "$CONF_DIR/api.x17.xyz-80.conf" <<'EOF'
# managed_by=Nginx-X
server {
    listen 443 ssl;
    server_name api.x17.xyz;
    location / { return 200; }
}
EOF
  if nx_assert_new_target "$CONF_DIR/api.x17.xyz-443.conf" > "$T/blocked" 2>&1; then exit 1; fi
  grep -q '同域名和监听端口的配置已存在' "$T/blocked"
  rm -f "$CONF_DIR/api.x17.xyz-80.conf"

  # Without the site, only the helper remains and the guard stays open.
  nx_assert_new_target "$CONF_DIR/api.x17.xyz-80.conf"
)
done
echo 'PASS: import scan and duplicate guard ignore generated helpers, keep real sites protected'
