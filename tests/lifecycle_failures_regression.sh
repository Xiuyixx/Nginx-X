#!/usr/bin/env bash
# Source and standalone bundle regression coverage for lifecycle failure paths.
# shellcheck disable=SC2317,SC1090,SC2030,SC2031,SC2059,SC2016,SC2034
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
root="$(mktemp -d)"
trap 'rm -rf "$root"; nx_test_cleanup' EXIT
bash tools/build-bundle.sh "$root/bundle"

for entry in ./nx.sh "$root/bundle"; do
  (
    source "$entry"
    SUDO=''
    # A failed write must preserve the old file and propagate through the
    # real interactive caller; no success message may be emitted.
    rm -f "$EMAIL_CONF"
    printf 'ACME_EMAIL=old@example.com\n' > "$EMAIL_CONF"
    output="$root/email-$(basename "$entry").log"
    printf() {
      if [[ ${1:-} == 'ACME_EMAIL=%q\n' ]]; then return 1; fi
      builtin printf "$@"
    }
    if set_acme_email <<< 'new@example.com' > "$output" 2>&1; then
      echo 'email write failure was reported as success' >&2
      exit 1
    fi
    [[ "$(cat "$EMAIL_CONF")" == 'ACME_EMAIL=old@example.com' ]]
    if grep -q '邮箱已保存到' "$output"; then exit 1; fi
    grep -q '邮箱配置保存失败' "$output"

    # A symlink target is rejected instead of being followed.
    printf 'unrelated\n' > "$root/email-target"
    rm -f "$EMAIL_CONF"
    ln -s "$root/email-target" "$EMAIL_CONF"
    if save_email 'other@example.com'; then exit 1; fi
    [[ "$(cat "$root/email-target")" == unrelated ]]

    # No-match pgrep output must stay one line.
    require_nginx_installed() { :; }
    clear() { :; }
    nx_stub_status() { return 1; }
    nginx_proc_counters() { echo '0 0'; }
    pgrep() {
      if [[ ${1:-} == -fc ]]; then echo 0; return 1; fi
      return 1
    }
    output="$root/monitor-$(basename "$entry").log"
    show_nginx_realtime_status < /dev/null > "$output"
    python3 - "$output" <<'PYMON'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text()
assert 'Worker进程: 0\n启动时间:' in s
PYMON
    grep -q '^Worker进程: 0$' "$output"

    # Derived map/ACME helper files are not site entries.
    rm -f "$CONF_DIR"/*
    printf 'map $http_upgrade $connection_upgrade { default upgrade; }\n' > "$CONF_DIR/00-websocket-map.conf"
    nx_acme_render_helper helper.example > "$CONF_DIR/acme-challenge-helper.example.conf"
    printf '# managed_by=Nginx-X\nserver { listen 80; server_name site.example; }\n' > "$CONF_DIR/site.conf"
    output="$root/panel-$(basename "$entry").log"
    nginx_local_version() { :; }
    nx_panel_has_acme_cron() { return 1; }
    system_info_panel > "$output"
    grep -q '已启用站点配置数: 1' "$output"
  )
done

# Failure injection through the actual menu wrapper, plus the automatic
# certificate preparation caller. Errexit is suppressed in these call chains.
for entry in ./nx.sh "$root/bundle"; do
  for failure in directory mktemp write chmod rename; do
    (
      source "$entry"
      SUDO=''
      rm -f "$EMAIL_CONF"
      printf 'ACME_EMAIL=old@example.com\n' > "$EMAIL_CONF"
      chmod 600 "$EMAIL_CONF"
      cp "$EMAIL_CONF" "$root/email-before"
      case "$failure" in
        directory) ensure_state_dir() { return 1; } ;;
        mktemp) mktemp() { return 1; } ;;
        write) printf() { [[ ${1:-} != 'ACME_EMAIL=%q\n' ]] || return 1; builtin printf "$@"; } ;;
        chmod) chmod() { return 1; } ;;
        rename) mv() { return 1; } ;;
      esac
      run_menu_action set_acme_email <<< 'new@example.com' > "$root/email-menu" 2>&1
      cmp "$EMAIL_CONF" "$root/email-before"
      [[ $(stat -c %a "$EMAIL_CONF") == 600 ]]
      grep -q '操作未完成' "$root/email-menu"
      if grep -q '邮箱已保存到' "$root/email-menu"; then exit 1; fi
      if compgen -G "$STATE_DIR/.email.conf.*" >/dev/null; then exit 1; fi
      load_email() { :; }
      unset ACME_EMAIL
      if ensure_email_interactive <<< 'new@example.com' > "$root/email-auto" 2>&1; then exit 1; fi
      [[ -z ${ACME_EMAIL:-} ]]
      cmp "$EMAIL_CONF" "$root/email-before"
    )
  done
  (
    source "$entry"
    SUDO=''
    rm -f "$EMAIL_CONF"
    save_email 'literal+$(do-not-execute)@example.com' >/dev/null
    [[ $(stat -c %a "$EMAIL_CONF") == 600 ]]
    load_email
    [[ "$ACME_EMAIL" == 'literal+$(do-not-execute)@example.com' ]]
  )
done

# APT candidate probing stays isolated; installation sees OS .list/.sources
# plus the legacy main sources.list, but never a duplicate old nginx source.
for entry in ./nx.sh "$root/bundle"; do
  (
    source "$entry"
    SUDO=''
    NX_APT_PARTS="$root/os-parts" NX_APT_MAIN_SOURCE="$root/main.list"
    NX_APT_SOURCE="$NX_APT_PARTS/nginx.list" NX_REPO_KEY="$root/repo-key"
    mkdir -p "$NX_APT_PARTS"
    printf 'old nginx source\n' > "$NX_APT_SOURCE"
    printf 'OS legacy\n' > "$NX_APT_MAIN_SOURCE"
    printf 'OS list\n' > "$NX_APT_PARTS/os.list"
    printf 'OS deb822\n' > "$NX_APT_PARTS/os.sources"
    nx_repo_fetch() { echo data > "$2"; }
    nx_repo_metadata_valid() { :; }
    nx_repo_validate_key() { :; }
    gpg() { while (($#)); do if [[ $1 == -o ]]; then echo key > "$2"; return; fi; shift; done; }
    apt-get() {
      local option parts='' action=''
      for option in "$@"; do
        case "$option" in
          Dir::Etc::sourceparts=*) parts="${option#*=}" ;;
          update|install) action="$option" ;;
        esac
      done
      if [[ $parts == - ]]; then [[ $action == update ]]; return; fi
      [[ -f "$parts/os.list" && -f "$parts/os.sources" && ! -e "$parts/nginx.list" ]] || return 91
      grep -rlqx 'OS legacy' "$parts" >/dev/null || return 92
      if [[ $action == install ]]; then touch "$root/os-deps-visible"; fi
    }
    rm -f "$root/os-deps-visible"
    nx_install_repository apt debian bookworm '' ''
    [[ -f "$root/os-deps-visible" ]]
    [[ $(cat "$NX_APT_MAIN_SOURCE") == 'OS legacy' ]]
    [[ $(cat "$NX_APT_PARTS/os.list") == 'OS list' ]]
  )
done

# Missing cron/crontab is a dependency failure unless the package transaction
# actually makes both commands available.
for entry in ./nx.sh "$root/bundle"; do
  (
    source "$entry"
    SUDO=''
    NX_APT_PARTS="$root/empty-parts"
    mkdir -p "$NX_APT_PARTS"
    ready="$root/cron-ready-$(basename "$entry")"
    apt_log="$root/apt-$(basename "$entry").log"
    check_cmd() {
      case "$1" in
        crontab|cron) [[ -e "$ready" ]] ;;
        *) return 0 ;;
      esac
    }
    apt-get() {
      echo "$*" >> "$apt_log"
      if [[ "$*" == *install* ]]; then touch "$ready"; fi
    }
    nx_install_repository_dependencies apt
    grep -q 'install' "$apt_log"
  )
done

for entry in ./nx.sh "$root/bundle"; do
  for manager in apt dnf yum; do
    for failure in package still-missing; do
      (
        source "$entry"
        SUDO=''
        NX_APT_PARTS="$root/empty-parts"
        mkdir -p "$NX_APT_PARTS"
        check_cmd() { [[ $1 != crontab && $1 != cron && $1 != crond ]]; }
        apt-get() { [[ $failure != package ]]; }
        dnf() { [[ $failure != package ]]; }
        yum() { [[ $failure != package ]]; }
        if nx_install_repository_dependencies "$manager" > "$root/cron-failure" 2>&1; then exit 1; fi
      )
    done
    (
      source "$entry"
      SUDO=''
      check_cmd() { return 0; }
      apt-get() { echo 'unexpected package operation' >&2; exit 99; }
      dnf() { apt-get "$@"; }; yum() { apt-get "$@"; }
      nx_install_repository_dependencies "$manager"
    )
  done
done

echo 'PASS source/bundle email failure propagation, OS repository visibility, diagnostic counts/zero-worker output, and cron dependency checks'
