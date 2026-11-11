#!/usr/bin/env bash
# Run only inside the reviewed private mount+network namespace executor.
# shellcheck disable=SC2034,SC2317,SC1091,SC2030,SC2031,SC2016
set -euo pipefail
[[ ${NX_CERT_AUDIT_NAMESPACE:-0} == 1 ]] || { echo 'skip: requires private mount/network namespace'; exit 0; }
repo=$(cd "$(dirname "$0")/.." && pwd)
[[ $EUID == 0 ]] || exit 1
# Protected ancestors are part of the real dispatcher's trust checks.  Do not
# weaken /tmp permissions or bypass those checks to accommodate the fixture.
t=$(mktemp -d /root/nginxx-cert-audit-XXXXXX); chmod 755 "$t"
export HOME="${t:?}/home" NX_CONF_DIR="$t/conf" SSL_DIR="$t/ssl" STATE_DIR="$t/state" NGINX_MAIN_CONF="$t/nginx.conf"
export NX_NGINX_PID_FILE="$t/nginx.pid"
mkdir -p "$HOME/.acme.sh" "$NX_CONF_DIR" "$SSL_DIR" "$STATE_DIR" "$t/manifests"
source "$repo/nx.sh"
SUDO=''
# Run the actual generator, including every heredoc and the shared embedded
# runtime engine.  Only its protected output paths are fixture-specific.
nx_acme_privileged_paths() { NX_ACME_DISPATCH="$t/dispatch"; NX_ACME_MANIFEST="$t/manifests/acme-0.domains"; }
nx_acme_privileged_paths
source "$repo/tests/acme_nginx_fault_wrapper.sh"
nx_test_install_nginx_wrapper "$t/nginx-wrapper"
cleanup() {
 local rc=$?
 /usr/sbin/nginx -c "$NGINX_MAIN_CONF" -s quit >/dev/null 2>&1 || true
 nx_test_remove_nginx_wrapper
 if (( rc )); then
  tail -80 "$t/error.log" >&2 || true
  for log in "$t"/*failure "$t"/*holder "$t"/*waiting*; do
   [[ ! -f "$log" ]] || { echo "--- $log" >&2; tail -30 "$log" >&2; }
  done
 fi
 if [[ ${NX_CERT_AUDIT_KEEP:-0} == 1 ]]; then
  mkdir -p /tmp/nginxx-cert-fix-20261004
  cp -a "$t" /tmp/nginxx-cert-fix-20261004/evidence
 fi
 rm -rf "$t"
 return "$rc"
}
trap cleanup EXIT
export NX_AUDIT_ROOT="$t"
cat > "$t/nginx-wrapper" <<'NGINX'
#!/bin/bash
set -euo pipefail
[[ $EUID == 0 ]] || exit 90
printf '%s\n' "$*" >> "$NX_AUDIT_ROOT/nginx-calls"
for arg do
 if [[ $arg == -t && -e "$NX_AUDIT_ROOT/fail-reload" ]]; then
  if [[ ! -e "$NX_AUDIT_ROOT/reload-injected" ]] && grep -q "Nginx-X temporary private generation witness" "$NX_AUDIT_ROOT/nginx.conf"; then
   /usr/sbin/nginx "$@"
   printf 'server { listen 192.0.2.1:19999; }\n' > "$NX_AUDIT_ROOT/conf/reload-fault.conf"
   touch "$NX_AUDIT_ROOT/reload-injected"
   exit 0
  fi
  rm -f "$NX_AUDIT_ROOT/conf/reload-fault.conf"
 fi
 if [[ $arg == -t && -e "$NX_AUDIT_ROOT/fail-test" ]]; then exit 42; fi
 if [[ $arg == -t && -e "$NX_AUDIT_ROOT/probe-locks" ]]; then
  for directory in "$NX_PROBE_CONF" "$NX_PROBE_SSL"; do
   for descriptor in /proc/$$/fd/*; do
    [[ $(readlink "$descriptor") != "$directory" ]] || exit 91
   done
   exec {probe}<"$directory"
   if flock -n -x "$probe"; then exit 92; fi
   exec {probe}<&-
  done
  if [[ ! -e "$NX_PROBE_READY" ]]; then
   touch "$NX_PROBE_READY"
   read -r _ < "$NX_PROBE_GATE"
  fi
 fi
 done
exec /usr/sbin/nginx "$@"
NGINX
chmod 0755 "$t/nginx-wrapper"
cat > "$NGINX_MAIN_CONF" <<CONF
pid $NX_NGINX_PID_FILE;
error_log $t/error.log notice;
events { worker_connections 128; }
http {
 access_log off;
 map \$http_upgrade \$connection_upgrade { default upgrade; "" close; }
 server { listen 127.0.0.1:18081; location / { return 200 audit; } }
 include $CONF_DIR/*.conf;
}
CONF
cat > "$HOME/.acme.sh/acme.sh" <<'ACME'
#!/bin/bash
set -e
[[ $1 != --cron ]] || exit 0
if [[ -e "$HOME/install-fail" ]]; then
 while (($#)); do
  if [[ $1 == --key-file ]]; then printf partial > "$2"; exit 8; fi
  shift
 done
fi
domain=''
for ((i=1;i<=$#;i++)); do
 if [[ ${!i} == -d ]]; then j=$((i+1)); domain=${!j}; fi
done
mkdir -p "$HOME/.acme.sh/$domain"
printf 'deployment-state-mutated\n' > "$HOME/.acme.sh/$domain/$domain.conf"
while (($#)); do
 case "$1" in --key-file) cp "$HOME/key" "$2"; shift ;; --fullchain-file) cp "$HOME/chain" "$2"; shift ;; esac
 shift
done
ACME
chmod 700 "$HOME/.acme.sh/acme.sh"
cert() { openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$1" -keyout "$HOME/key" -out "$HOME/chain" >/dev/null 2>&1; }
# First ever deployment fails: absent manifest and stage must remain absent.
cert wrong.example
if nx_deploy_certificate first.example > "$t/first-failure" 2>&1; then exit 1; fi
[[ ! -e "$NX_ACME_MANIFEST" && ! -e "$HOME/.acme.sh/nginxx-deploy/first.example" ]]
echo 'PASS M1 first account failure restores absent manifest and stage'
cert a.example
nx_deploy_certificate a.example
[[ "$(curl --noproxy '*' -fsS http://127.0.0.1:18081/)" == audit ]]
cp -a "$NX_ACME_MANIFEST" "$t/manifest-before"
cp -a "$HOME/.acme.sh/nginxx-deploy/a.example" "$t/stage-before"
cp -a "$HOME/.acme.sh/a.example" "$t/account-before"
if nx_deploy_certificate b.example > "$t/b-failure" 2>&1; then exit 1; fi
cmp "$t/manifest-before" "$NX_ACME_MANIFEST"
[[ ! -e "$HOME/.acme.sh/nginxx-deploy/b.example" ]]
echo 'PASS M1 new domain: manifest and absent stage restored'
cert wrong.example
if nx_deploy_certificate a.example > "$t/a-failure" 2>&1; then exit 1; fi
diff -r "$t/stage-before" "$HOME/.acme.sh/nginxx-deploy/a.example"
diff -r "$t/account-before" "$HOME/.acme.sh/a.example"
cmp "$t/manifest-before" "$NX_ACME_MANIFEST"
echo 'PASS M1 existing domain: stage pair and manifest restored'
touch "$HOME/install-fail"
if nx_deploy_certificate a.example > "$t/install-failure" 2>&1; then exit 1; fi
rm "$HOME/install-fail"
diff -r "$t/stage-before" "$HOME/.acme.sh/nginxx-deploy/a.example"
cmp "$t/manifest-before" "$NX_ACME_MANIFEST"
echo 'PASS M1 acme partial write failure restores original staged pair' 
cert a.example
nx_deploy_certificate a.example
"$NX_ACME_DISPATCH" cron
cmp "$HOME/chain" "$SSL_DIR/a.example/fullchain.pem"
echo 'PASS M1 A deploy and cron update after B failure'
# Hold deployment lock: both interactive install and cron must wait.
(exec {fd}<"$SSL_DIR"; flock -x "$fd"; touch "$t/locked"; sleep 2) & holder=$!
while [[ ! -e "$t/locked" ]]; do sleep .02; done
nx_deploy_certificate a.example > "$t/concurrent-install" 2>&1 & deploy=$!
"$NX_ACME_DISPATCH" cron > "$t/concurrent-cron" 2>&1 & cron=$!
sleep .2; kill -0 "$deploy"; kill -0 "$cron"
wait "$holder"; wait "$deploy"; wait "$cron"
echo 'PASS M1 concurrent cron/install serialize on same directory inode'
# Real configuration transaction and dispatcher serialize on the same inode.
cp "$SSL_DIR/a.example/fullchain.pem" "$t/before-conf-lock"
cert a.example
cp "$HOME/key" "$HOME/.acme.sh/nginxx-deploy/a.example/privkey.pem"
cp "$HOME/chain" "$HOME/.acme.sh/nginxx-deploy/a.example/fullchain.pem"
mkfifo "$t/conf-gate"
hold_config() { touch "$t/conf-locked"; read -r _ < "$t/conf-gate"; }
nx_transaction hold_config > "$t/config-holder" 2>&1 & holder=$!
while [[ ! -e "$t/conf-locked" ]]; do kill -0 "$holder"; sleep .02; done
"$NX_ACME_DISPATCH" cron > "$t/conf-waiting-cron" 2>&1 & cron=$!
sleep .2; kill -0 "$cron"
cmp "$t/before-conf-lock" "$SSL_DIR/a.example/fullchain.pem"
echo release > "$t/conf-gate"
wait "$holder" || { cat "$t/config-holder"; exit 1; }; wait "$cron" || { cat "$t/conf-waiting-cron"; exit 1; }
cmp "$HOME/chain" "$SSL_DIR/a.example/fullchain.pem"
# Reload subprocess cannot inherit either FD; the publisher parent must still
# hold both locks during reload. A reverse-order transaction cannot enter.
touch "$t/probe-locks"
export NX_PROBE_CONF="$CONF_DIR" NX_PROBE_SSL="$SSL_DIR" NX_PROBE_READY="$t/publisher-ready" NX_PROBE_GATE="$t/publisher-gate"
mkfifo "$NX_PROBE_GATE"
"$NX_ACME_DISPATCH" cron > "$t/publisher-holder" 2>&1 & deploy=$!
while [[ ! -e "$NX_PROBE_READY" ]]; do kill -0 "$deploy"; sleep .02; done
# Callback evidence lives outside snapshot: no reload is needed for this noop.
nx_transaction touch "$t/entered-config" > "$t/waiting-config" 2>&1 & holder=$!
sleep .2; kill -0 "$holder"; [[ ! -e "$t/entered-config" ]]
echo release > "$NX_PROBE_GATE"
wait "$deploy"; wait "$holder"
[[ -e "$t/entered-config" ]]
rm "$t/probe-locks"
echo 'PASS shared CONF inode serializes both directions; reload closes SSL/CONF FDs while publisher holds locks'
# Actual publisher reload failure must restore account stage as well as PEMs.
cp -a "$HOME/.acme.sh/nginxx-deploy/a.example" "$t/stage-reload"
cp -a "$SSL_DIR/a.example" "$t/deployed-reload"
cert a.example; touch "$t/fail-reload"
if nx_deploy_certificate a.example > "$t/reload-failure" 2>&1; then exit 1; fi
rm "$t/fail-reload"
rm -f "$CONF_DIR/reload-fault.conf" "$t/reload-injected"
diff -r "$t/stage-reload" "$HOME/.acme.sh/nginxx-deploy/a.example"
diff -r "$t/deployed-reload" "$SSL_DIR/a.example"
echo 'PASS M1 reload failure restores account and deployed PEM pair'
for body in 'return 404;' 'root /wrong;' 'proxy_pass http://127.0.0.1:9;'; do
 printf 'server { listen 80; server_name a.example; location ^~ /.well-known/acme-challenge/ { %s } location / { return 200 business; } }\n' "$body" > "$CONF_DIR/custom.conf"
 cp "$CONF_DIR/custom.conf" "$t/original"
 if nx_https_transform challenge "$CONF_DIR/custom.conf" a.example "$SSL_DIR" '' > "$t/transformed" 2> "$t/refusal"; then exit 1; fi
 cmp "$CONF_DIR/custom.conf" "$t/original"
done
rm "$CONF_DIR/custom.conf"
echo 'PASS M5 unknown return/root/proxy challenge rejected without business overwrite'
printf 'server { listen 80; server_name a.example; location ^~ /.well-known/acme-challenge/ { root /usr/share/nginx/html; default_type "text/plain"; try_files $uri =404; } location / { return 200 business; } }\n' > "$t/known.conf"
nx_https_transform challenge "$t/known.conf" a.example "$SSL_DIR" '' > "$t/known-transformed"
cmp "$t/known.conf" "$t/known-transformed"
echo 'PASS M5 exact generated challenge block preserved byte-for-byte' 
# Real transaction hook, fail before publication; preserved certificate route stays.
nx_acme_render_helper a.example > "$CONF_DIR/acme-challenge-a.example.conf"
touch "$CONF_DIR/.nx-acme-a.example.state"
cp -a "$CONF_DIR" "$t/routes-before"
ensure_acme_installed() { return 1; }
if _issue_cert_http new.example; then exit 1; fi
diff -r "$t/routes-before" "$CONF_DIR"
ensure_acme_installed() { :; }; nx_acme_prepare_webroot() { return 1; }
if _issue_cert_http new.example; then exit 1; fi
diff -r "$t/routes-before" "$CONF_DIR"
echo 'PASS L1 both prerequisites leave original helper/marker/certificate route unchanged'
# Scheduler: two account paths share the protected SSL inode.
crontab() {
 if [[ $1 == -l ]]; then [[ ${READ_FAIL:-0} != 1 ]] || { echo 'permission denied' >&2; return 2; }; cat "$t/cron";
 else [[ ${WRITE_FAIL:-0} != 1 ]] || return 3; cat > "$t/cron"; fi
}
printf '7 4 * * * administrator\n' > "$t/cron"
(nx_acme_privileged_paths() { NX_ACME_DISPATCH="$t/dispatch-a"; }; nx_acme_privileged_cron enable) & first=$!
(nx_acme_privileged_paths() { NX_ACME_DISPATCH="$t/dispatch-b"; }; nx_acme_privileged_cron enable) & second=$!
wait "$first"; wait "$second"
grep -q 'dispatch-a cron' "$t/cron"; grep -q 'dispatch-b cron' "$t/cron"; grep -q administrator "$t/cron"
cp "$t/cron" "$t/cron-before"
if READ_FAIL=1 nx_acme_privileged_cron enable; then exit 1; fi
cmp "$t/cron-before" "$t/cron"
if WRITE_FAIL=1 nx_acme_privileged_cron remove; then exit 1; fi
cmp "$t/cron-before" "$t/cron"
# Enable published root job, then legacy cleanup fails: no false success and
# the root job stays safe/retryable; other-account/admin jobs remain intact.
nx_acme_account_crontab() { echo 'permission denied' >&2; return 2; }
if ensure_acme_cron; then exit 1; fi
grep -q 'dispatch cron' "$t/cron"; grep -q 'dispatch-a cron' "$t/cron"; grep -q 'dispatch-b cron' "$t/cron"
echo 'PASS scheduler concurrent accounts, read/write failures, partial enable preserve unrelated jobs'
# Joint disaster recovery rehearsal: retain configuration, certificates, account,
# credentials, ownership manifests, dispatcher and both scheduler scopes.
printf 'EMAIL=test@example.com\nDNS_KEY=fixture-secret\n' > "$STATE_DIR/credentials"
chmod 600 "$STATE_DIR/credentials"
printf 'account-cron disabled\n' > "$t/account-cron"
mkdir -p "$t/periodic"; printf 'legacy disabled\n' > "$t/periodic/saved"
cp -a "$t" "$t.joint-before"
tar -cpf "$t.joint.tar" -C "$t" conf ssl home state manifests dispatch cron account-cron periodic
rm -rf "$t/conf" "$t/ssl" "${t:?}/home" "$t/state" "$t/manifests" "$t/dispatch" "$t/cron" "$t/account-cron" "$t/periodic"
tar -xpf "$t.joint.tar" -C "$t"
for item in conf ssl home state manifests dispatch cron account-cron periodic; do
 diff -r "$t.joint-before/$item" "$t/$item"
done
[[ $(stat -c %a "$STATE_DIR/credentials") == 600 ]]
[[ $(stat -c %a "$SSL_DIR/a.example/privkey.pem") == 600 ]]
"$NX_ACME_DISPATCH" cron
openssl x509 -in "$SSL_DIR/a.example/fullchain.pem" -noout -checkhost a.example
rm -rf "$t.joint-before" "$t.joint.tar"
echo 'PASS joint backup restore: config, PEM, account, credentials, manifest, dispatcher, cron and periodic byte/mode preservation; restored dispatcher publishes'
echo 'certificate audit 20261004 passed' 
