#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2034 # menu/transaction callbacks and dynamic scan paths
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
  reload_nginx_safe() { :; }
  ensure_websocket_map() { :; }
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

  # Domains containing ".conf" are still valid labels: strip only the final
  # helper extension, otherwise the deleted-site helper becomes importable and
  # blocks recreation.
  for dotted_domain in api.config.example.com api.conference.example.com; do
    dotted_helper="$CONF_DIR/acme-challenge-${dotted_domain}.conf"
    nx_acme_render_helper "$dotted_domain" > "$dotted_helper"
    nx_managed_conf_is_helper "$dotted_helper"
    nx_assert_new_target "$CONF_DIR/${dotted_domain}-80.conf"
    mapfile -t dotted_scan < <(_scan_unmanaged_confs)
    if printf '%s\n' "${dotted_scan[@]:-}" | grep -Fxq "$dotted_helper"; then
      echo "dotted-domain helper leaked into import scan: $dotted_helper" >&2
      exit 1
    fi
    rm -f "$dotted_helper"
  done
  # Prefixes are not ownership proof: a business domain can contain the
  # literal helper name followed by additional DNS labels.
  prefix_site="$CONF_DIR/00-websocket-map.config.example-18082.conf"
  printf '# managed_by=Nginx-X\nserver { listen 18082; server_name 00-websocket-map.config.example; }\n' > "$prefix_site"
  if nx_managed_conf_is_helper "$prefix_site"; then exit 1; fi
  list_managed_conf_files 1 | grep -Fx "$prefix_site" >/dev/null
  rm -f "$prefix_site"

  # Identical active/backup copies are not two import candidates.  A backup
  # must never be silently activated, and a second source with the same site
  # identity must not create a second managed file.
  rm -f "$CONF_DIR"/* "$CONF_DIR"/.[!.]*
  cat > "$CONF_DIR/duplicate.conf" <<'EOF'
server {
    listen 18080;
    server_name duplicate.example.com;
    location / { return 200; }
}
EOF
  cp "$CONF_DIR/duplicate.conf" "$CONF_DIR/duplicate.conf.bak"
  mapfile -t duplicate_scan < <(_scan_unmanaged_confs)
  [[ ${#duplicate_scan[@]} == 1 && ${duplicate_scan[0]} == "$CONF_DIR/duplicate.conf" ]]
  import_single_conf "$CONF_DIR/duplicate.conf" >/dev/null
  [[ -f "$CONF_DIR/duplicate.example.com-18080.conf" && ! -e "$CONF_DIR/duplicate.conf" ]]
  if import_single_conf "$CONF_DIR/duplicate.conf.bak" > "$T/duplicate-import" 2>&1; then exit 1; fi
  grep -q '备份/停用文件不会自动启用' "$T/duplicate-import"
  if [[ -e "$CONF_DIR/duplicate.conf.bak" ]] && grep -q '^# managed_by=Nginx-X$' "$CONF_DIR/duplicate.conf.bak"; then
    echo 'backup copy was imported as a managed site' >&2
    exit 1
  fi

  # Deleting an imported site records the unchanged external origin.  The
  # origin remains on disk, but is not offered again until it is edited.
  rm -f "$CONF_DIR"/* "$CONF_DIR"/.[!.]*
  SITES_ENABLED="$T/sites-enabled"; SITES_AVAILABLE="$T/sites-available"
  rm -rf "$SITES_ENABLED" "$SITES_AVAILABLE"
  mkdir -p "$SITES_ENABLED" "$SITES_AVAILABLE"
  export NX_SITES_ENABLED_DIR="$SITES_ENABLED" NX_SITES_AVAILABLE_DIR="$SITES_AVAILABLE"
  cat > "$SITES_AVAILABLE/legacy.conf" <<'EOF'
server {
    listen 18081;
    server_name legacy.example.com;
    location / { return 200; }
}
EOF
  mapfile -t external_scan < <(_scan_unmanaged_confs)
  [[ ${#external_scan[@]} == 1 && ${external_scan[0]} == "$SITES_AVAILABLE/legacy.conf" ]]
  import_single_conf "$SITES_AVAILABLE/legacy.conf" >/dev/null
  [[ -f "$CONF_DIR/legacy.example.com-18081.conf" && -f "$SITES_AVAILABLE/legacy.conf" ]]
  confirm() { return 0; }
  delete_conf legacy.example.com-18081.conf >/dev/null
  if _scan_unmanaged_confs | grep -q .; then exit 1; fi
  [[ -s "$CONF_DIR/.nx-import-tombstones" ]]
  printf '\n# edited source\n' >> "$SITES_AVAILABLE/legacy.conf"
  _scan_unmanaged_confs | grep -Fxq "$SITES_AVAILABLE/legacy.conf"

  # A colliding reserved metadata field from a prior export is replaced in
  # the copied candidate, never duplicated and never written to the origin.
  printf '# import_source_key=%064d\n' 0 >> "$SITES_AVAILABLE/legacy.conf"
  cp "$SITES_AVAILABLE/legacy.conf" "$T/origin-before"
  import_single_conf "$SITES_AVAILABLE/legacy.conf" >/dev/null
  cmp "$SITES_AVAILABLE/legacy.conf" "$T/origin-before"
  [[ $(grep -c '^# import_source_key=' "$CONF_DIR/legacy.example.com-18081.conf") == 1 ]]
  delete_conf legacy.example.com-18081.conf >/dev/null
  if _scan_unmanaged_confs | grep -q .; then exit 1; fi

  # Bad source-history state is an error, not evidence that every old source
  # is new. The real menu must not print a false empty/success result.
  printf 'corrupted\n' > "$CONF_DIR/.nx-import-tombstones"
  if import_existing_confs > "$T/bad-history" 2>&1; then exit 1; fi
  grep -q '已停止扫描' "$T/bad-history"
  if grep -q '未发现需要导入' "$T/bad-history"; then exit 1; fi
  rm -f "$CONF_DIR/.nx-import-tombstones"

  # A same-domain/port source with another bind address must not become a
  # second managed identity. This also covers a scanner snapshot going stale
  # between the initial listing and a later import selection.
  import_single_conf "$SITES_AVAILABLE/legacy.conf" >/dev/null
  cat > "$SITES_AVAILABLE/alias.conf" <<'EOF'
server { listen 127.0.0.1:18081; server_name LEGACY.EXAMPLE.COM.; location / { return 201; } }
EOF
  if import_single_conf "$SITES_AVAILABLE/alias.conf" > "$T/identity-conflict" 2>&1; then exit 1; fi
  grep -q '已由 Nginx-X 纳管' "$T/identity-conflict"
  [[ $(list_managed_conf_files 1 | wc -l) == 1 ]]

  # Historical filenames do not bypass identity checks during a rename.
  rm -f "$CONF_DIR"/* "$CONF_DIR"/.[!.]*
  printf '# managed_by=Nginx-X\nserver { listen 18083; server_name existing.example; }\n' > "$CONF_DIR/historical-80.conf.bak"
  printf '# managed_by=Nginx-X\nserver { listen 18084; server_name other.example; }\n' > "$CONF_DIR/other.example-18084.conf"
  cp "$CONF_DIR/historical-80.conf.bak" "$T/rename-candidate"
  cp "$CONF_DIR/other.example-18084.conf" "$T/rename-before"
  if apply_conf_with_rollback "$T/rename-candidate" "$CONF_DIR/existing.example-18083.conf" "$CONF_DIR/other.example-18084.conf" > "$T/rename-conflict" 2>&1; then exit 1; fi
  cmp "$CONF_DIR/other.example-18084.conf" "$T/rename-before"
  [[ ! -e "$CONF_DIR/existing.example-18083.conf" ]]

  # A failed delete/reload restores both the site and source-history state.
  rm -f "$CONF_DIR"/* "$CONF_DIR"/.[!.]*
  import_single_conf "$SITES_AVAILABLE/legacy.conf" >/dev/null
  (
    reload_nginx_safe() { return 1; }
    if delete_conf legacy.example.com-18081.conf > "$T/delete-rollback" 2>&1; then exit 1; fi
    [[ -f "$CONF_DIR/legacy.example.com-18081.conf" && ! -e "$CONF_DIR/.nx-import-tombstones" ]]
  )
  delete_conf legacy.example.com-18081.conf >/dev/null
  [[ ! -e "$CONF_DIR/legacy.example.com-18081.conf" && -s "$CONF_DIR/.nx-import-tombstones" ]]
)
done
echo 'PASS: source/bundle helper identity, import deduplication, tombstones and delete/reimport lifecycle'
