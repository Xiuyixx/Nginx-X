#!/usr/bin/env bash
# Source only from privileged tests inside their disposable rootfs. Keep the
# actual ELF at its original path so /proc/<master>/exe identity stays real.
# Redirect only subprocess command execution through the fault wrapper; no
# process, socket, generation-log or runtime-proof API is replaced.
# shellcheck disable=SC2034
nx_test_install_nginx_wrapper() {
  NX_TEST_NGINX_SITECUSTOMIZE="$(python3 -c 'import sysconfig; print(sysconfig.get_path("purelib"))')/sitecustomize.py"
  [[ ! -e "$NX_TEST_NGINX_SITECUSTOMIZE" ]] || return 1
  export NX_TEST_NGINX_WRAPPER="$1"
  cat > "$NX_TEST_NGINX_SITECUSTOMIZE" <<'PY'
import os, subprocess
_original_run = subprocess.run
def _fault_wrapped_run(args, *positional, **kwargs):
    wrapper = os.environ.get('NX_TEST_NGINX_WRAPPER')
    if wrapper and isinstance(args, (list, tuple)) and args and os.path.basename(args[0]) == 'nginx':
        args = [wrapper, *args[1:]]
    return _original_run(args, *positional, **kwargs)
subprocess.run = _fault_wrapped_run
PY
}
nx_test_remove_nginx_wrapper() {
  rm -f "$NX_TEST_NGINX_SITECUSTOMIZE"
}
