#!/usr/bin/env bash
# Run only inside the reviewed private mount+network namespace executor.
# shellcheck disable=SC2034,SC2317,SC1091,SC2030,SC2031,SC2016
set -euo pipefail
[[ ${NX_CERT_AUDIT_NAMESPACE:-0} == 1 ]] || { echo 'skip: requires private mount/network namespace'; exit 0; }
repo=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d); chmod 755 "$t"
trap 'if [[ ${NX_CERT_AUDIT_KEEP:-0} == 1 ]]; then cp -a "$t" /tmp/nginxx-cert-fix-20261004/evidence; fi; rm -rf "$t"' EXIT
export HOME="${t:?}/home" NX_CONF_DIR="$t/conf" SSL_DIR="$t/ssl" STATE_DIR="$t/state" NGINX_MAIN_CONF="$t/nginx.conf"
mkdir -p "$HOME/.acme.sh" "$NX_CONF_DIR" "$SSL_DIR" "$STATE_DIR" "$t/bin" "$t/manifests"
source "$repo/nx.sh"
SUDO=''
# Exact generated dispatcher, only destination/header/reload executables replaced.
nx_acme_privileged_paths() { NX_ACME_DISPATCH="$t/dispatch"; NX_ACME_MANIFEST="$t/manifests/acme-0.domains"; }
nx_acme_prepare_dispatch() {
 nx_acme_privileged_paths
 { printf '#!/bin/bash\nset -euo pipefail\naccount=root\naccount_home=%q\nssl=%q\nmanifest=%q\n' "$HOME" "$SSL_DIR" "$NX_ACME_MANIFEST"
 sed -n '/^    cat <<.*DISPATCH.*$/,/^DISPATCH$/p' "$repo/lib/certificates.sh" | sed '1d;$d'
 } > "$t/dispatch-candidate-$BASHPID"
 chmod 700 "$t/dispatch-candidate-$BASHPID"
 mv -fT "$t/dispatch-candidate-$BASHPID" "$NX_ACME_DISPATCH"
}
printf '#!/bin/sh\n[[ ! -f "%s/fail-reload" ]]\n' "$t" > "$t/bin/nginx"
# POSIX shell stub, with fault injection.
printf '#!/bin/sh\ntest ! -f "%s/fail-reload"\n' "$t" > "$t/bin/nginx"
chmod 700 "$t/bin/nginx"; export PATH="$t/bin:$PATH"
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
# Actual publisher reload failure must restore account stage as well as PEMs.
cp -a "$HOME/.acme.sh/nginxx-deploy/a.example" "$t/stage-reload"
cp -a "$SSL_DIR/a.example" "$t/deployed-reload"
cert a.example; touch "$t/fail-reload"
if nx_deploy_certificate a.example > "$t/reload-failure" 2>&1; then exit 1; fi
rm "$t/fail-reload"
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
