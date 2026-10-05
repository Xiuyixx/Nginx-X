#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
root="$(mktemp -d)"
trap 'nx_test_cleanup; rm -rf "$root"' EXIT
bash tools/build-bundle.sh "$root/nx-bundle"

for entry in "$PWD/nx.sh" "$root/nx-bundle"; do
  # Source only: never enter main or touch runtime dependencies/services.
  bash -s -- "$entry" > "$root/$(basename "$entry").title" <<'SH'
set -euo pipefail
source "$1"
[[ "$APP_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
[[ "$APP_NAME" == Nginx-X ]]
clear() { :; }
title="$(banner)"
[[ "$title" == "${APP_NAME} v${APP_VERSION}"$'\n========================================' ]]
[[ ! "$title" =~ [0-9]{4}-[0-9]{2}-[0-9]{2} ]]
printf '%s\n' "$title"
SH
done
cmp "$root/nx.sh.title" "$root/nx-bundle.title"
version="$(head -n 1 "$root/nx.sh.title")"
version="${version#Nginx-X v}"
grep -Fq "当前版本：**${version}**" README.md
grep -Fq "菜单标题为 \`Nginx-X v${version}\`" README.md
current_changelog="$(sed -n '/^## \[/ { p; q; }' CHANGELOG.md)"
[[ "$current_changelog" == "## [${version}] - "* ]]
echo "ok: source/bundle title Nginx-X v${version}, numeric semver and matching docs"
