#!/usr/bin/env bash
# One mutation, derived access rules, config validation and reload form a unit.
# Directory-wide snapshots retain modes/owners and include disabled sites.
# Callback contract: disk mutations only; shell variables stay in this subshell.
# Callers must use the return status (and files for instrumentation), not counters.
# Dynamic context is consumed only by functions called inside this subshell.
# shellcheck disable=SC2030
nx_transaction() (
  # Lock the directory inode itself: no writable lock file, symlink race, or
  # privileged shell redirection. Nginx configuration directories are readable
  # by sudo users; every caller (including root) locks the same inode.
  local lock_fd
  [[ -n "$CONF_DIR" && "$CONF_DIR" != / && -d "$CONF_DIR" && ! -L "$CONF_DIR" ]] || { error "配置目录必须是明确的普通目录。"; return 1; }
  command -v flock >/dev/null 2>&1 || { error "事务需要 flock（util-linux）。"; return 1; }
  exec {lock_fd}<"$CONF_DIR" || return 1
  flock -x "$lock_fd" || return 1
  # Existing inode aliases outside the snapshot cannot be restored by a
  # directory rollback. Reject them before any migration/callback can write.
  nx_transaction_paths_safe || return 1

  local snapshot rc=0 state_existed=0 main_existed=0 main_target=""
  # Read by ensure_websocket_map in nx.sh through Bash dynamic scope.
  # shellcheck disable=SC2034
  local NX_IN_TRANSACTION=1
  snapshot="$(mktemp -d /tmp/nginxx-transaction-XXXXXX)" || return 1
  if ! ${SUDO} cp -a "$CONF_DIR" "$snapshot/conf"; then
    rm -rf "$snapshot"
    return 1
  fi
  if [[ -L "$NGINX_MAIN_CONF" ]]; then
    main_target="$(readlink -f "$NGINX_MAIN_CONF")" || { ${SUDO} rm -rf "$snapshot"; return 1; }
    [[ -f "$main_target" ]] || { ${SUDO} rm -rf "$snapshot"; return 1; }
    ${SUDO} cp -a "$main_target" "$snapshot/main-target" || { ${SUDO} rm -rf "$snapshot"; return 1; }
  fi
  if [[ -f "$NGINX_MAIN_CONF" ]]; then
    main_existed=1
    ${SUDO} cp -a "$NGINX_MAIN_CONF" "$snapshot/main" || { ${SUDO} rm -rf "$snapshot"; return 1; }
  fi
  if [[ -f "$DOMAIN_ONLY_STATE" ]]; then
    state_existed=1
    if ! ${SUDO} cp -a "$DOMAIN_ONLY_STATE" "$snapshot/state"; then
      ${SUDO} rm -rf "$snapshot"
      return 1
    fi
  fi
  local backend_checkpoint=0
  if [[ -n ${NX_DOMAIN_ACTION:-} ]]; then
    mkdir -m 700 "$snapshot/backend" || { ${SUDO} rm -rf "$snapshot"; return 1; }
    if ! _nx_backend_engine checkpoint "$snapshot/backend"; then
      error '无法备份后端保护；未执行组合操作。'
      ${SUDO} rm -rf "$snapshot"
      return 1
    fi
    backend_checkpoint=1
  fi
  # Service managers and daemonized nginx must not retain our flock. The
  # transaction parent keeps its descriptor until commit/rollback completes.
  nx_transaction_reload() (
    exec {lock_fd}<&-
    reload_nginx_safe
  )
  nx_transaction_restore() {
    error "配置应用失败，正在恢复本次操作前的配置与访问策略。"
    # Only this configured directory is restored; never touch nginx system paths.
    local path
    for path in "$CONF_DIR"/* "$CONF_DIR"/.[!.]* "$CONF_DIR"/..?*; do
      [[ -e "$path" || -L "$path" ]] || continue
      ${SUDO} rm -rf -- "$path" || rc=1
    done
    ${SUDO} cp -a "$snapshot/conf/." "$CONF_DIR/" || rc=1
    if (( main_existed )); then
      ${SUDO} rm -f "$NGINX_MAIN_CONF" || rc=1
      ${SUDO} cp -a "$snapshot/main" "$NGINX_MAIN_CONF" || rc=1
      if [[ -n "$main_target" ]]; then
        ${SUDO} cp -a "$snapshot/main-target" "$main_target" || rc=1
      fi
    fi
    if (( state_existed )); then
      ${SUDO} cp -a "$snapshot/state" "$DOMAIN_ONLY_STATE" || rc=1
    else
      ${SUDO} rm -f "$DOMAIN_ONLY_STATE" || rc=1
    fi
    if (( backend_checkpoint )); then
      _nx_backend_engine restore "$snapshot/backend" || rc=1
    fi
    if (( rc )); then
      error "恢复文件失败；备份保留在 ${snapshot}，请立即检查。"
      return 1
    fi
    if ! nx_transaction_reload; then
      error "磁盘配置已恢复，但旧配置重载失败；备份保留在 ${snapshot}，请检查 Nginx 服务状态。"
      return 1
    fi
    ${SUDO} rm -rf "$snapshot"
  }
  trap 'trap - HUP INT TERM; nx_transaction_restore; exit 1' HUP INT TERM
  nx_transaction_changed() {
    ${SUDO} diff -qr "$snapshot/conf" "$CONF_DIR" >/dev/null 2>&1 || return 0
    if (( main_existed )); then
      if [[ -n "$main_target" ]]; then
        ${SUDO} cmp -s "$snapshot/main-target" "$main_target" || return 0
      else
        ${SUDO} cmp -s "$snapshot/main" "$NGINX_MAIN_CONF" || return 0
      fi
    elif [[ -e "$NGINX_MAIN_CONF" ]]; then return 0; fi
    return 1
  }
  nx_transaction_domain_before() {
    [[ ${NX_DOMAIN_ACTION:-} != disable ]] || _nx_backend_engine disable "$NX_DOMAIN_FILE"
  }
  nx_transaction_domain_after() {
    [[ ${NX_DOMAIN_ACTION:-} != enable ]] || _nx_backend_engine enable "$NX_DOMAIN_FILE" strict
  }
  nx_transaction_domain_guard() {
    if [[ ${NX_DOMAIN_ACTION:-} == enable ]]; then
      _nx_backend_engine guard "$snapshot/conf" "$NX_DOMAIN_FILE"
    else nx_backend_guard_snapshot "$snapshot/conf"; fi
  }
  if nx_access_migrate_state && nx_transaction_domain_before && "$@" && nx_transaction_paths_safe && nx_acme_sync_routes && ensure_websocket_map && nx_access_sync_files &&
     nx_transaction_domain_after && nx_transaction_domain_guard &&
     { ! nx_transaction_changed || nx_transaction_reload; }; then
    trap - HUP INT TERM
    ${SUDO} rm -rf "$snapshot"
    return 0
  fi
  trap - HUP INT TERM
  nx_transaction_restore
  return 1
)

nx_write_conf() {
  local tmp="$1" target="$2" old="${3:-}"
  nx_conf_path_allowed "$target" || return 1
  [[ -z "$old" ]] || nx_conf_path_allowed "$old" || return 1
  if [[ -n "$old" && "$old" != "$target" && ( -e "$target" || -e "${target%.bak}.bak" && "${target%.bak}.bak" != "$old" || -e "${target%.bak}" && "${target%.bak}" != "$old" ) ]]; then
    error "目标配置已存在，拒绝覆盖：${target}"
    return 1
  fi
  nx_acme_retain_conf_route "${old:-$target}" || return 1
  if [[ -n "$old" && -f "$old" ]]; then
    local metadata key value
    metadata="$(mktemp /tmp/nginxx-metadata-XXXXXX)" || return 1
    nx_conf_query metadata-drop "$tmp" access_policy access_default > "$metadata" || { rm -f "$metadata"; return 1; }
    for key in access_policy access_default; do
      value="$(conf_meta_get "$old" "$key")" || { rm -f "$metadata"; return 1; }
      if [[ "$key" == access_default && -n "$value" ]]; then
        local before after
        before="$(nx_access_parse "$old")" || { rm -f "$metadata"; return 1; }
        after="$(nx_access_parse "$tmp")" || { rm -f "$metadata"; return 1; }
        value="$(nx_conf_query defaults "$tmp" "$value" "$before" "$after")" || { rm -f "$metadata"; return 1; }
      fi
      if [[ -n "$value" ]]; then printf '\n# %s=%s\n' "$key" "$value" >> "$metadata"; fi
    done
    if [[ "$target" == "$old" ]]; then
      ${SUDO} tee "$target" < "$metadata" >/dev/null || { rm -f "$metadata"; return 1; }
    else
      if ! ${SUDO} cp -a "$old" "$target" || ! ${SUDO} tee "$target" < "$metadata" >/dev/null; then rm -f "$metadata"; return 1; fi
    fi
    rm -f "$metadata"
  else
    install_managed_file "$tmp" "$target" || return 1
  fi
  ensure_ssl_directives_present "$target" || return 1
  if [[ -n "$old" && "$old" != "$target" ]]; then
    ${SUDO} rm -f "$old" || return 1
  fi
}

apply_conf_with_rollback() {
  nx_conf_path_allowed "$2" || return 1
  [[ -z "${3:-}" ]] || nx_conf_path_allowed "$3" || return 1
  nx_transaction nx_write_conf "$@"
}

nx_move_conf() {
  nx_conf_path_allowed "$1" && nx_conf_path_allowed "$2" || return 1
  [[ -f "$1" && ! -e "$2" ]] || { error "源配置不存在或目标已存在。"; return 1; }
  nx_acme_retain_conf_route "$1" || return 1
  ${SUDO} mv "$1" "$2"
}

enable_conf() {
  local file="${1:-}"
  [[ "$file" == *.conf.bak ]] || { error "只能启用 .conf.bak 站点。"; return 1; }
  nx_transaction nx_move_conf "$CONF_DIR/$file" "$CONF_DIR/${file%.bak}" || return 1
  info "已启用：${file%.bak}"
}

disable_conf() {
  local file="${1:-}"
  [[ "$file" == *.conf ]] || { error "只能停用 .conf 站点。"; return 1; }
  nx_transaction nx_move_conf "$CONF_DIR/$file" "$CONF_DIR/$file.bak" || return 1
  info "已停用：${file}"
}

delete_conf() {
  local file="${1:-}"
  [[ -n "$file" && -f "$CONF_DIR/$file" ]] || return 1
  confirm "确认永久删除 ${file} ?" || return 0
  nx_transaction nx_remove_conf "$CONF_DIR/$file" || return 1
  info "已删除：${file}"
}

edit_conf_manual() {
  local file="${1:-}" tmp
  [[ -n "$file" && -f "$CONF_DIR/$file" ]] || return 1
  tmp="$(mktemp /tmp/nginxx-edit-XXXXXX)" || return 1
  if ! ${SUDO} cp "$CONF_DIR/$file" "$tmp" || ! run_editor "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mark_conf_manual_edited "$tmp" || ! apply_conf_with_rollback "$tmp" "$CONF_DIR/$file" "$CONF_DIR/$file"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  info "配置已编辑并生效：${file}"
}

nx_site_https_toggle() {
  local file="$1" domain
  [[ "$file" == *.conf ]] || { error "请先启用站点。"; return 1; }
  domain="$(extract_domain_from_conf "$file")" || return 1
  if conf_https_enabled "$file"; then
    disable_https_for_conf_file "$domain" "$file"
  else
    ensure_cert_for_domain_interactive "$domain" || return 1
    enable_https_for_conf_file "$domain" "$file"
  fi
}

nx_remove_conf() {
  nx_conf_path_allowed "$1" || return 1
  nx_acme_retain_conf_route "$1" || return 1
  ${SUDO} rm -f "$1"
}

# Every mutated site must be a regular immediate child of the snapshot directory.
nx_conf_path_allowed() {
  [[ -n "$1" && "$(dirname -- "$1")" == "$CONF_DIR" && ! -L "$1" && "$(basename -- "$1")" != .* ]] || {
    error "拒绝事务目录外路径或符号链接：$1"; return 1;
  }
  nx_assert_single_link "$1"
}

# In-place preservative writes keep the existing owner/mode. They are allowed
# only for an unaliased regular inode. Newly generated files retain their
# explicit install mode; neither path may modify an external hardlink alias.
nx_assert_single_link() {
  local links
  [[ -e "$1" ]] || return 0
  [[ -f "$1" ]] || { error "配置路径必须是普通文件：$1"; return 1; }
  links="$(${SUDO:-} stat -c '%h' -- "$1")" || return 1
  [[ "$links" == 1 ]] || { error "拒绝硬链接配置（事务无法恢复外部别名）：$1"; return 1; }
}

nx_transaction_paths_safe() {
  local linked main
  # Includes hidden derived files, disabled sites and nested directory files.
  linked="$(${SUDO:-} find "$CONF_DIR" -type f -links +1 -print -quit)" || return 1
  [[ -z "$linked" ]] || { error "拒绝硬链接配置（事务范围外别名）：$linked"; return 1; }
  main="$NGINX_MAIN_CONF"
  if [[ -L "$main" ]]; then
    main="$(readlink -f "$main")" || return 1
    [[ -f "$main" ]] || return 1
  fi
  nx_assert_single_link "$main" && nx_assert_single_link "$DOMAIN_ONLY_STATE"
}
nx_assert_new_target() {
  local base="${1%.bak}"
  [[ ! -e "$base" && ! -L "$base" && ! -e "$base.bak" && ! -L "$base.bak" ]] || {
    error "站点配置已存在（包括停用配置），请使用修改菜单。"; return 1;
  }
}

# Render TLS before publication. Never activate a temporary plain-text version.
nx_preserve_modify_tls() {
  local src="$1" candidate="$2" domain="$3" requested="$4" stage original old_domain
  local -a preserve_source=()
  conf_https_enabled "$src" || return 0
  old_domain="$(extract_domain_from_conf "$src")" || return 1
  [[ "$domain" == "$old_domain" || -f "$SSL_DIR/$domain/fullchain.pem" && -f "$SSL_DIR/$domain/privkey.pem" ]] || {
    error "HTTPS 修改需要目标域名的现有证书；原配置保持不变。"; return 1;
  }
  original="$(conf_meta_get "$src" https_original_listen_port)" || return 1
  if [[ -z "$original" ]]; then original="$(conf_meta_get "$src" listen_port)" || return 1; fi
  [[ -n "$original" ]] || original=80
  stage="$(mktemp)" || return 1
  [[ "$domain" != "$old_domain" ]] || preserve_source=("$src")
  if ! nx_https_transform enable "$candidate" "$domain" "$SSL_DIR" "$requested" "${preserve_source[@]}" > "$stage"; then rm -f "$stage"; return 1; fi
  nx_access_metadata "$stage" https_original_listen_port "$original" || { rm -f "$stage"; return 1; }
  cat "$stage" > "$candidate" || { rm -f "$stage"; return 1; }
  rm -f "$stage"
}

# Recheck uniqueness while holding the transaction lock (menu preflight is only UX).
nx_add_conf() {
  nx_assert_new_target "$2" || return 1
  nx_write_conf "$@"
}
