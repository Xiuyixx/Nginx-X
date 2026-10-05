#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:?output file required}"
# Replace the eager loader with module contents, preserving execution guard.
awk '/^# All modules load before/ { exit } { print }' "$root/nx.sh" > "$out"
# Persist install identity before the execution guard; never derive it from PATH.
printf '\nNX_INSTALLED_TARGET=%q\nNX_INSTALLED_REPO=%q\n' "${NX_BUNDLE_TARGET:-}" "${NX_BUNDLE_REPO:-}" >> "$out"
for module in dependencies templates certificates transactions access https diagnostics backend; do
  cat "$root/lib/$module.sh" >> "$out"
  printf '\n' >> "$out"
done
cat >> "$out" <<'GUARD'
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --help|-h) echo "Usage: nx (interactive Nginx-X manager)" ;;
    *) main ;;
  esac
fi
GUARD
bash -n "$out"
