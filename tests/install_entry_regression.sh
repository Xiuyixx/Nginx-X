#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
installer="${NX_TEST_INSTALLER:-$PWD/install.sh}"
mkdir -p "$root/repo/tools" "$root/mock" "$root/empty"
cp "$installer" "$root/repo/install.sh"
printf '# fixture source entry\n' > "$root/repo/nx.sh"
# Exercise the complete installer, but replace product dependency/menu code.
cat > "$root/repo/tools/build-bundle.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'bundle\n' >> "$NX_ENTRY_LOG"
cat > "$1" <<'BUNDLE'
#!/usr/bin/env bash
ensure_runtime_dependencies() { printf 'dependencies\n' >> "$NX_ENTRY_LOG"; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'unexpected-menu\n' >> "$NX_ENTRY_LOG"
  exit 91
fi
BUNDLE
SH
cat > "$root/mock/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
 clone)
  printf 'clone\n' >> "$NX_ENTRY_LOG"
  destination="${@: -1}"
  mkdir -p "$destination/.git"
  cp -R "$NX_ENTRY_REPO/." "$destination/"
  ;;
 -C)
  [[ "$3 $4 $5 $6" == 'pull origin main --ff-only' ]]
  printf 'pull\n' >> "$NX_ENTRY_LOG"
  ;;
 *) exit 92 ;;
esac
SH
# Match the README command exactly without downloading or running host installers.
cat > "$root/mock/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == '-fsSL https://raw.githubusercontent.com/Xiuyixx/Nginx-X/main/install.sh' ]]
cat "$NX_ENTRY_INSTALLER"
SH
cat > "$root/mock/sudo" <<'SH'
#!/usr/bin/env bash
exec "$@"
SH
for command in apt-get dnf yum apk opkg systemctl nx; do
  printf '#!/bin/sh\necho "unexpected host operation" >&2; exit 93\n' > "$root/mock/$command"
done
chmod +x "$root/mock/"*
export PATH="$root/mock:$PATH" NX_ENTRY_REPO="$root/repo" NX_ENTRY_INSTALLER="$installer"
export NX_ENTRY_LOG="$root/events" INSTALL_DIR TARGET_BIN
# shellcheck disable=SC2016 # Match literal README shell expressions; do not expand them here.
readme_command="$(sed -n '/^bash -c "$(curl /p' README.md)"
# shellcheck disable=SC2016 # The expected command contains a literal command substitution.
[[ "$readme_command" == 'bash -c "$(curl -fsSL https://raw.githubusercontent.com/Xiuyixx/Nginx-X/main/install.sh)"' ]]
for mode in readme bash-c stdin file local; do
  INSTALL_DIR="$root/install-$mode"
  TARGET_BIN="$root/bin/$mode"
  : > "$NX_ENTRY_LOG"
  (
    cd "$root/empty"
    # A pre-existing NO_RUN=0 ensures --no-run is parsed, not just inherited.
    export NO_RUN=0
    case "$mode" in
      readme) bash -c "$readme_command" ;;
      bash-c) bash -uc "$(cat "$installer")" -- --no-run ;;
      stdin) bash -us -- --no-run < "$installer" ;;
      file) cp "$installer" "$root/empty/install.sh"; bash -u ./install.sh --no-run ;;
      local) bash -u "$root/repo/install.sh" --no-run ;;
    esac
  ) > "$root/$mode.out" 2>&1
  grep -Fq '[OK] Installed.' "$root/$mode.out"
  [[ -x "$TARGET_BIN" ]]
  if [[ "$mode" == local ]]; then
    printf 'bundle\ndependencies\n' > "$root/expected"
  else
    printf 'clone\nbundle\ndependencies\n' > "$root/expected"
  fi
  cmp "$root/expected" "$NX_ENTRY_LOG"
  # Re-running the remote entry must update and install, not silently return.
  if [[ "$mode" == bash-c ]]; then
    : > "$NX_ENTRY_LOG"
    (cd "$root/empty"; NO_RUN=0 bash -uc "$(cat "$installer")" -- --no-run) > "$root/update.out" 2>&1
    printf 'pull\nbundle\ndependencies\n' > "$root/expected"
    cmp "$root/expected" "$NX_ENTRY_LOG"
  fi
done
# Source is still a library-only operation even when the caller uses nounset.
: > "$NX_ENTRY_LOG"
INSTALL_DIR="$root/source-install" TARGET_BIN="$root/source-bin" bash -uc '
  source "$1" --no-run
  declare -F bootstrap_install install_local get_script_dir >/dev/null
' _ "$installer"
[[ ! -s "$NX_ENTRY_LOG" && ! -e "$root/source-install" && ! -e "$root/source-bin" ]]
# Help under bash-c must exit before bootstrap as well.
(cd "$root/empty"; bash -uc "$(cat "$installer")" -- --help) > "$root/help"
grep -Fq 'Usage: install.sh' "$root/help"
[[ ! -s "$NX_ENTRY_LOG" ]]
echo 'ok: complete README/bash-c/stdin/file/local installer entries, clone/update/dependencies, --no-run and side-effect-free source/help'
