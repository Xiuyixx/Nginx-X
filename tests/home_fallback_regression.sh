#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2317
set -euo pipefail
source "$(dirname "$0")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
source ./nx.sh
site="$CONF_DIR/route.conf"
for routing in 'try_files $uri /; location / { root /tmp; }' 'location / { try_files $uri /; }' 'location / { try_files $uri /missing.html; }' 'location / { try_files $uri @app; } location @app { try_files $uri /; }' 'location / { try_files $uri /end; } location = /end { try_files $uri /missing.html; }' 'location / { try_files $uri /$arg_next; }'; do
 printf 'server { listen 18080; server_name example.test; %s }\n' "$routing" > "$site"
 if nx_conf_query home-set "$site" /missing.html >/dev/null 2>&1; then echo "FAIL: unsafe fallback accepted: $routing"; exit 1; fi
done
for routing in 'location / { try_files $uri =404; }' 'location / { try_files $uri /end; } location = /end { return 404; }' 'location / { proxy_pass http://127.0.0.1:3000; }' 'location / { try_files $uri @app; } location @app { proxy_pass http://127.0.0.1:3000; }'; do
 printf 'server { listen 18080; server_name example.test; %s }\n' "$routing" > "$site"
 nx_conf_query home-set "$site" /missing.html >/dev/null
done
echo 'PASS: reachable try_files fallbacks reject loops and retain terminal/static/proxy paths'
