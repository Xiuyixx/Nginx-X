#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
root="$(mktemp -d)"
trap 'nx_test_cleanup; rm -rf "$root"' EXIT
mkdir -p "$root/source/lib" "$root/source/tools" "$root/bin"
cp nx.sh install.sh "$root/source/"
cp lib/*.sh "$root/source/lib/"
cp tools/build-bundle.sh "$root/source/tools/"
TARGET_BIN="$root/bin/nx" bash "$root/source/install.sh" --no-run >/dev/null
bash -n "$root/bin/nx"
# Installed command is self contained even if all source modules disappear.
cp "$root/bin/nx" "$root/first"
printf '\n# module-only update\n' >> "$root/source/lib/access.sh"
TARGET_BIN="$root/bin/nx" bash "$root/source/install.sh" --no-run >/dev/null
if cmp -s "$root/first" "$root/bin/nx"; then echo 'module-only update was ignored' >&2; exit 1; fi
mkdir -p "$root/directory-target"
ln -s "$root/directory-target" "$root/directory-link"
for target in "$root/directory-target" "$root/directory-link"; do
 if TARGET_BIN="$target" bash "$root/source/install.sh" --no-run > "$root/rejected" 2>&1; then exit 1; fi
 [[ -z "$(find "$root/directory-target" -mindepth 1 -print)" ]]
 if grep -q 'Installed' "$root/rejected"; then exit 1; fi
done
rm -rf "$root/source"
bash -c 'source "$1"; declare -F nx_transaction nx_access_sync_files nx_https_transform build_proxy_conf issue_cert >/dev/null' _ "$root/bin/nx"
[[ ! -e "$root/bin/nx.new" ]]
echo 'ok: coherent standalone bundle and custom installation path'
# A target becoming a directory after validation must fail, not nest the stage.
mkdir -p "$root/race-source/lib" "$root/race-source/tools" "$root/mock"
cp nx.sh install.sh "$root/race-source/"
cp lib/*.sh "$root/race-source/lib/"
cp tools/build-bundle.sh "$root/race-source/tools/"
real_mv="$(command -v mv)"
cat > "$root/mock/mv" <<'SH'
#!/usr/bin/env bash
mkdir -p "${@: -1}"
exec "$NX_REAL_MV" "$@"
SH
# This fixture owns every path: avoid sudo's secure_path bypassing the mv
# injection on non-root CI runners. No privileged operation is required.
cat > "$root/mock/sudo" <<'SH'
#!/usr/bin/env bash
exec "$@"
SH
chmod +x "$root/mock/mv" "$root/mock/sudo"
if PATH="$root/mock:$PATH" NX_REAL_MV="$real_mv" TARGET_BIN="$root/bin/raced" bash "$root/race-source/install.sh" --no-run > "$root/race.log" 2>&1; then exit 1; fi
[[ -d "$root/bin/raced" && -z "$(find "$root/bin/raced" -mindepth 1 -print)" ]]
[[ -z "$(find "$root/bin" -name 'raced.stage.*' -print)" ]]
if grep -q 'Installed' "$root/race.log"; then exit 1; fi
