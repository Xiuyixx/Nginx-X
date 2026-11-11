#!/usr/bin/env bash
# Generate the actual dispatcher template without executing privileged install.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tests/fixtures/test-environment.sh
source tests/fixtures/test-environment.sh
root="$NX_TEST_ENV_ROOT"
bash tools/build-bundle.sh "$root/bundle"
for entry in "$PWD/nx.sh" "$root/bundle"; do
 python3 - "$entry" "$root/render" <<'PY'
import pathlib,sys
text=pathlib.Path(sys.argv[1]).read_text()
# The source entry loads the certificate module; the bundle embeds it.
if 'nx_acme_prepare_dispatch() {' not in text:
    text=(pathlib.Path(sys.argv[1]).parent/'lib/certificates.sh').read_text()
start=text.index('  {\n',text.index('nx_acme_prepare_dispatch() {'))
end=text.index('  } > "$tmp"',start)+len('  } > "$tmp"')
pathlib.Path(sys.argv[2]).write_text(text[start:end])
PY
 ENTRY="$entry" RENDER="$root/render" OUTPUT="$root/dispatcher" bash -c '
 source "$ENTRY"
 tmp="$OUTPUT"; user=root; NX_ACME_MANIFEST="$STATE_DIR/manifest"
 source "$RENDER"
 '
 bash -n "$root/dispatcher"
 python3 - "$root/dispatcher" <<'PY'
import pathlib,sys
text=pathlib.Path(sys.argv[1]).read_text()
engine=text.split("{ cat <<'PYPUBLISH_ENGINE'\n",1)[1].split('\nPYPUBLISH_ENGINE\n',1)[0]
publish=text.split("cat <<'PYPUBLISH'\n",1)[1].split('\nPYPUBLISH\n',1)[0]
compile(engine+'\n'+publish,'dispatcher-publish','exec')
assert 'nx_reload(nginx_bin, main_conf, nginx_pid, nginx_prefix, timeout=nginx_timeout)' in publish
assert 'deployment backups retained' in publish
assert 'close_fds=True' in engine
assert 'NX_NGINX_RUNTIME_PROBE' not in text
assert 'main_conf=' in text
PY
 echo "PASS dispatcher $(basename "$entry"): generated Bash/Python compile, shared runtime engine, configured main path, rollback backup retention"
done
