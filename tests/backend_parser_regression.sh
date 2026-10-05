#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
python3 - <<'PY'
import pathlib
source=pathlib.Path('lib/backend.sh').read_text().split("<<'PYBACKEND'\n",1)[1].split('\ndef read_site',1)[0]
ns={}; exec(source,ns)
targets=ns['targets']; Refused=ns['Refused']
plain='server { listen 18080; server_name example.com; location / { proxy_pass http://127.0.0.1:18317; } }'
guards=r'''if ($http_host !~* "^(example\.com)\.?(:[0-9]+)?$") { return 444; }
if ($host !~* "^(example\.com)$") { return 444; }'''
good=plain.replace('location /',guards+' location /')
assert targets(good)==[18317]
for bad in (plain+'\n# nx-access-begin\n# return 444;',
            plain.replace('proxy_pass','return 444; proxy_pass'),
            good+'\n'+plain,
            plain.replace('proxy_pass',guards+' proxy_pass'),
            good.replace('example\\.com','.*')):
    try: targets(bad)
    except Refused: pass
    else: raise AssertionError('accepted fake strict guard: '+bad)
print('PASS: backend parser rejects comment/location/unprotected second server/wildcard fake strict guards')
PY
