#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/fixtures/test-environment.sh
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
root="$(mktemp -d)"
trap 'nx_test_cleanup; rm -rf "$root"' EXIT
# Extract the actual published snippets, not a hand-maintained test duplicate.
python3 - "$root" <<'PY'
import pathlib, re, sys
out = pathlib.Path(sys.argv[1])
values = {'host': 'alias.example', 'body_bytes_sent': '1048576',
          'server_port': '18443', 'scheme': 'https', 'server_name': 'main.example'}
formats = []
for index, filename in enumerate(('README.md', 'docs/diagnostics.md')):
    text = pathlib.Path(filename).read_text()
    matches = re.findall(r"^log_format\s+(\w+)\s+'([^']+)';$", text, re.M)
    assert len(matches) == 1, (filename, 'expected one complete log_format example')
    name, template = matches[0]
    assert f'access_log /var/log/nginx/access.host.log {name};' in text, filename
    rendered = re.sub(r'\$(\w+)', lambda m: values[m[1]], template)
    (out / f'log{index}').write_text(rendered + '\n')
    formats.append(template)
assert formats[0] == formats[1], 'README and diagnostics guide disagree'
PY
cat > "$root/site.conf" <<'EOF'
server { listen 18443 ssl; server_name main.example alias.example; }
EOF
bash tools/build-bundle.sh "$root/bundle"
for implementation in ./nx.sh "$root/bundle"; do
  (
    # shellcheck disable=SC1090
    source "$implementation"
    for logfile in "$root/log0" "$root/log1"; do
      nx_traffic_rows "$logfile" "$root/site.conf" > "$root/result"
      grep -F '请求: 1 | 下行: 1.00 MiB' "$root/result" >/dev/null
      if grep -F 'N/A' "$root/result"; then exit 1; fi
    done
  )
done
echo 'PASS published host-log snippets produce accurate source/bundle statistics'
