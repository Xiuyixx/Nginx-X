#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
repo="$PWD"
root="$(mktemp -d)"
trap 'nx_test_cleanup; rm -rf "$root"' EXIT
mkdir -p "$root/source/lib" "$root/source/tools" "$root/source/.git" "$root/bin"
cp nx.sh install.sh "$root/source/"
cp lib/*.sh "$root/source/lib/"
cp tools/build-bundle.sh "$root/source/tools/"
# Replace only the fixture entry point: test exec migration without system writes.
python3 - "$root/source/nx.sh" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text(); marker='# All modules load before'
s=s.replace(marker, 'main() { declare -F nx_transaction nx_access_sync_files >/dev/null; echo MIGRATED; }\n\n'+marker)
p.write_text(s)
PY
cat > "$root/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
 *'remote get-url'*) echo https://github.com/Xiuyixx/Nginx-X.git ;;
 *pull*|*fetch*|*merge*) exit 0 ;;
 *symbolic-ref*) echo main ;;
 *rev-list*) echo '0 0' ;;
 *--abbrev-ref*) echo origin/main ;;
 *rev-parse*) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
 *'status --porcelain'*) : ;;
 *) exit 1 ;;
esac
MOCK
chmod +x "$root/bin/git"
# Source new definitions, then replace updater with the exact 5b99fe5 function.
# Its old install step copies raw nx.sh only and then execs the installed target.
PATH="$root/bin:$PATH" REPO_INSTALL_DIR="$root/source" bash -s -- "$repo" "$root" <<'RUN'
source "$1/nx.sh"
source "$1/tests/fixtures/legacy-update.sh"
SUDO=''
SCRIPT_DIR="$2/source"
printf '#!/usr/bin/env bash\nexit 0\n' > "$2/bin/nx"
chmod +x "$2/bin/nx"
NX_IN_MENU=1
update_script
RUN
# Recovery must leave a complete standalone bundle, not a source loader.
if grep -q '^NX_LIB_DIR=' "$root/bin/nx"; then echo 'legacy update left source loader' >&2; exit 1; fi
mv "$root/source/lib" "$root/hidden-lib"
[[ "$("$root/bin/nx")" == MIGRATED ]]
mv "$root/hidden-lib" "$root/source/lib"
# Exercise bootstrap through a privilege wrapper that strips the environment.
# Explicit env arguments must survive, including both custom installation paths.
mkdir -p "$root/bootstrap"
cp install.sh "$root/bootstrap/install.sh"
cat > "$root/bin/sudo-strip" <<'MOCK'
#!/usr/bin/env bash
exec env -i PATH="$PATH" HOME="$HOME" "$@"
MOCK
chmod +x "$root/bin/sudo-strip"
# Load installer function definitions without its dispatch block.
sed '/^for arg in "\$@"; do/,$d' install.sh > "$root/installer-functions"
PATH="$root/bin:$PATH" bash -s -- "$root" <<'RUN'
source "$1/installer-functions"
SUDO="$1/bin/sudo-strip"
INSTALL_DIR="$1/source"
TARGET_BIN="$1/bin/custom-nx"
NO_RUN=1
bootstrap_install
[[ -x "$TARGET_BIN" ]]
RUN
# A mismatched repository must not silently provide another revision's modules.
cp "$root/source/nx.sh" "$root/bin/raw-nx"
printf '\n# mismatched revision\n' >> "$root/bin/raw-nx"
cp "$root/bin/raw-nx" "$root/raw-before"
if REPO_INSTALL_DIR="$root/source" bash "$root/bin/raw-nx" > "$root/refusal.log" 2>&1; then
  echo 'mismatched legacy source unexpectedly recovered' >&2; exit 1
fi
cmp "$root/raw-before" "$root/bin/raw-nx"
echo 'ok: old updater exec migration and bootstrap privilege-boundary paths'
# The 39007be bundled updater invokes install.sh rather than copying the loader.
# Freeze its implementation so current identity checks cannot hide regressions.
# A preceding installer may publish a root-owned executable through sudo.
# Recreate this test fixture via its caller-owned directory, not an in-place write.
rm -f "$root/bin/nx"
printf '#!/bin/sh\nexit 0\n' > "$root/bin/nx"
chmod +x "$root/bin/nx"
PATH="$root/bin:$PATH" REPO_INSTALL_DIR="$root/source" bash -s -- "$repo" "$root" <<'RUN'
source "$1/nx.sh"
source "$1/tests/fixtures/legacy-bundle-update.sh"
SUDO=''
SCRIPT_DIR="$2/source"
NX_IN_MENU=1
update_script
RUN
# The upgraded artifact carries its exact install identity for future updates.
grep -Fq "NX_INSTALLED_TARGET=$root/bin/nx" "$root/bin/nx"
[[ "$("$root/bin/nx")" == MIGRATED ]]
echo 'ok: 39007be bundled updater installs registered identity and execs new bundle'
