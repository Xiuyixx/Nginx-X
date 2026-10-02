#!/usr/bin/env bash
# Destructive only inside a dedicated throwaway rootfs; never opt in on the host.
set -euo pipefail
if [[ ${NX_ACME_ISOLATED:-0} != 1 ]]; then
  echo 'skip: ACME identity proof requires a disposable root filesystem'
  exit 0
fi
[[ $EUID == 0 ]] || exit 1
root="$(cd "$(dirname "$0")/.." && pwd)"
adduser -D -s /bin/bash acmetest
printf 'acmetest:isolated-test-password\n' | chpasswd
printf 'acmetest ALL=(ALL:ALL) ALL\nDefaults:acmetest !use_pty\n' > /etc/sudoers.d/acmetest
chmod 0440 /etc/sudoers.d/acmetest
mkdir -p /home/acmetest/.acme.sh /etc/nginx/ssl-identity/example.com
chmod 0755 /etc/nginx/ssl-identity /etc/nginx/ssl-identity/example.com
cat > /home/acmetest/.acme.sh/acme.sh <<'ACME'
#!/bin/bash
set -eu
[[ $EUID != 0 ]] || exit 99
printf '%s %s\n' "$EUID" "$*" >> "$HOME/acme.log"
# A malicious/custom user hook cannot gain root during renewal.
touch /root/acme-hook-escalated 2>/dev/null || true
if [[ $1 == --cron ]]; then
  cp "$HOME/renewed-key" "$HOME/.acme.sh/nginxx-deploy/example.com/privkey.pem"
  cp "$HOME/renewed-chain" "$HOME/.acme.sh/nginxx-deploy/example.com/fullchain.pem"
else
  while (($#)); do
    case "$1" in --key-file) cp "$HOME/initial-key" "$2"; shift ;; --fullchain-file) cp "$HOME/initial-chain" "$2"; shift ;; esac
    shift
  done
fi
ACME
for generation in initial renewed; do
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com \
    -addext subjectAltName=DNS:example.com -keyout "/home/acmetest/$generation-key" \
    -out "/home/acmetest/$generation-chain" >/dev/null 2>&1
done
chmod +x /home/acmetest/.acme.sh/acme.sh
chown -R acmetest:acmetest /home/acmetest
mv /usr/sbin/nginx /usr/sbin/nginx-real
cat > /usr/sbin/nginx <<'NGINX'
#!/bin/sh
[ "$(id -u)" = 0 ] || exit 90
printf '%s\n' "$*" >> /root/identity-nginx.log
case "$*" in
  -t) [ ! -e /root/fail-test ] || exit 42 ;;
  '-s reload') [ ! -e /root/fail-reload ] || exit 43 ;;
esac
exit 0
NGINX
chmod 0755 /usr/sbin/nginx
cat > /home/acmetest/deploy-test <<SCRIPT
#!/bin/bash
set -euo pipefail
source "$root/nx.sh"
SSL_DIR=/etc/nginx/ssl-identity
# Harness supplies an interactive password to the real sudo binary. Product
# code never stores a password and installs no sudoers rule.
sudo() { /usr/bin/sudo -A "\$@"; }
export SUDO_ASKPASS=/home/acmetest/askpass
nx_acme_prepare_webroot
printf token > /usr/share/nginx/html/.well-known/acme-challenge/identity-test
nx_deploy_certificate example.com
nx_migrate_certificate_renewal
if has_acme_cron_task; then exit 1; fi
ensure_acme_cron
ensure_acme_cron
/usr/bin/sudo -k
if /usr/bin/sudo -n true 2>/dev/null; then exit 1; fi
SCRIPT
printf '#!/bin/sh\nprintf "isolated-test-password\\n"\n' > /home/acmetest/askpass
chmod 0700 /home/acmetest/askpass
chown acmetest:acmetest /home/acmetest/askpass /home/acmetest/deploy-test
su -s /bin/bash acmetest -c 'HOME=/home/acmetest bash /home/acmetest/deploy-test'
uid="$(id -u acmetest)"
[[ "$(stat -c '%u:%a' /etc/nginx/ssl-identity/example.com/privkey.pem)" == 0:600 ]]
[[ "$(stat -c '%u:%a' "/usr/local/libexec/nginxx-acme-$uid")" == 0:700 ]]
crontab -l | grep -Fx "0 3 * * * /usr/local/libexec/nginxx-acme-$uid cron"
[[ "$(crontab -l | grep -c "nginxx-acme-$uid cron")" == 1 ]]
[[ "$(stat -c %u /usr/share/nginx/html/.well-known/acme-challenge)" == "$uid" ]]
[[ ! -e /root/acme-hook-escalated ]]
# Invoke precisely the root cron command after explicitly expiring sudo.
"/usr/local/libexec/nginxx-acme-$uid" cron
cmp /etc/nginx/ssl-identity/example.com/privkey.pem /home/acmetest/renewed-key
[[ ! -e /root/acme-hook-escalated ]]
[[ "$(stat -c %u /home/acmetest/.acme.sh/acme.sh)" == "$uid" ]]
# A forged source symlink cannot disclose root-only bytes.
printf private-root-only > /root/private-identity
rm /home/acmetest/.acme.sh/nginxx-deploy/example.com/privkey.pem
ln -s /root/private-identity /home/acmetest/.acme.sh/nginxx-deploy/example.com/privkey.pem
if "/usr/local/libexec/nginxx-acme-$uid" deploy; then exit 1; fi
cmp /etc/nginx/ssl-identity/example.com/privkey.pem /home/acmetest/renewed-key
# Restore valid source; all rejected publications preserve both deployed bytes.
rm /home/acmetest/.acme.sh/nginxx-deploy/example.com/privkey.pem
cp /home/acmetest/initial-key /home/acmetest/.acme.sh/nginxx-deploy/example.com/privkey.pem
cp /home/acmetest/initial-chain /home/acmetest/.acme.sh/nginxx-deploy/example.com/fullchain.pem
chown -R acmetest:acmetest /home/acmetest/.acme.sh/nginxx-deploy
refuse() {
  if "/usr/local/libexec/nginxx-acme-$uid" deploy; then exit 1; fi
}
unchanged() {
  cmp /etc/nginx/ssl-identity/example.com/privkey.pem /home/acmetest/renewed-key
  cmp /etc/nginx/ssl-identity/example.com/fullchain.pem /home/acmetest/renewed-chain
}
for fault in test reload; do
  touch "/root/fail-$fault"
  refuse
  unchanged
  rm "/root/fail-$fault"
done
chown nobody /etc/nginx/ssl-identity/example.com
refuse
unchanged
chown root /etc/nginx/ssl-identity/example.com
for kind in directory symlink hardlink fifo; do
  mv /etc/nginx/ssl-identity/example.com/fullchain.pem /root/saved-chain
  case "$kind" in
    directory) mkdir /etc/nginx/ssl-identity/example.com/fullchain.pem ;;
    symlink) ln -s /root/saved-chain /etc/nginx/ssl-identity/example.com/fullchain.pem ;;
    hardlink) ln /root/saved-chain /etc/nginx/ssl-identity/example.com/fullchain.pem ;;
    fifo) mkfifo /etc/nginx/ssl-identity/example.com/fullchain.pem ;;
  esac
  refuse
  cmp /etc/nginx/ssl-identity/example.com/privkey.pem /home/acmetest/renewed-key
  rm -rf /etc/nginx/ssl-identity/example.com/fullchain.pem
  mv /root/saved-chain /etc/nginx/ssl-identity/example.com/fullchain.pem
done
cp /home/acmetest/renewed-key /home/acmetest/.acme.sh/nginxx-deploy/example.com/privkey.pem
refuse # key mismatch
unchanged
# Domain mismatch with a correctly matched private key is independently refused.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=other.example \
  -keyout /home/acmetest/.acme.sh/nginxx-deploy/example.com/privkey.pem \
  -out /home/acmetest/.acme.sh/nginxx-deploy/example.com/fullchain.pem >/dev/null 2>&1
chown -R acmetest:acmetest /home/acmetest/.acme.sh/nginxx-deploy
refuse
unchanged
cp /home/acmetest/initial-key /home/acmetest/.acme.sh/nginxx-deploy/example.com/privkey.pem
cp /home/acmetest/initial-chain /home/acmetest/.acme.sh/nginxx-deploy/example.com/fullchain.pem
printf 'example.com\n' > /var/lib/nginxx/acme-999.domains
chmod 0600 /var/lib/nginxx/acme-999.domains
refuse
unchanged
rm /var/lib/nginxx/acme-999.domains
# Fault injection changes only this disposable interpreter: fail the second
# os.replace, leaving the real generated publisher to execute its rollback.
mkdir -p /root/fault-python
cat > /root/fault-python/sitecustomize.py <<'PYFAULT'
import os
original=os.replace
count=0
def replace(src,dst,*args,**kwargs):
    global count
    if '/.deploy-' in src and not src.endswith('.old'):
        count+=1
        if count==2: raise OSError('injected second publication failure')
    return original(src,dst,*args,**kwargs)
os.replace=replace
PYFAULT
PYTHONPATH=/root/fault-python refuse
unchanged
# Deletion uses the same directory lock and refuses cross-account ownership.
printf 'example.com\n' > /var/lib/nginxx/acme-999.domains
chmod 0600 /var/lib/nginxx/acme-999.domains
if bash -c 'source "$1/nx.sh"; SSL_DIR=/etc/nginx/ssl-identity; nx_delete_certificate example.com' _ "$root"; then exit 1; fi
unchanged
rm /var/lib/nginxx/acme-999.domains
# Holding the shared inode blocks a generated deployment until released.
exec {test_lock}</etc/nginx/ssl-identity
flock -x "$test_lock"
if (exec {test_lock}<&-; timeout 1 "/usr/local/libexec/nginxx-acme-$uid" deploy); then exit 1; else [[ $? == 124 ]]; fi
exec {test_lock}<&-
unchanged
printf malformed > /home/acmetest/.acme.sh/nginxx-deploy/example.com/fullchain.pem
refuse
unchanged
# Native root uses exactly the same publisher and protected root scheduler.
mkdir -p /root/.acme.sh
cp /home/acmetest/{initial-key,initial-chain,renewed-key,renewed-chain} /root/
# shellcheck disable=SC2016
sed -e 's/\[\[ $EUID != 0 \]\]/[[ $EUID == 0 ]]/' \
  -e '/touch \/root\/acme-hook-escalated/d' /home/acmetest/.acme.sh/acme.sh > /root/.acme.sh/acme.sh
chmod 0700 /root/.acme.sh/acme.sh
# Give root a different hostname/account ownership manifest.
rm /var/lib/nginxx/acme-"$uid".domains
bash -c 'set -e; source "$1/nx.sh"; SSL_DIR=/etc/nginx/ssl-identity; nx_deploy_certificate example.com; ensure_acme_cron; ensure_acme_cron' _ "$root"
[[ "$(crontab -l | grep -c 'nginxx-acme-0 cron')" == 1 ]]
/usr/local/libexec/nginxx-acme-0 cron
cmp /etc/nginx/ssl-identity/example.com/privkey.pem /root/renewed-key
cmp /etc/nginx/ssl-identity/example.com/fullchain.pem /root/renewed-chain
uid=0
cp /root/initial-key /root/.acme.sh/nginxx-deploy/example.com/privkey.pem
cp /root/initial-chain /root/.acme.sh/nginxx-deploy/example.com/fullchain.pem
chmod 0640 /etc/nginx/ssl-identity/example.com/privkey.pem
chmod 0600 /etc/nginx/ssl-identity/example.com/fullchain.pem
root_unchanged() {
  unchanged
  [[ "$(stat -c '%u:%a' /etc/nginx/ssl-identity/example.com/privkey.pem)" == 0:640 ]]
  [[ "$(stat -c '%u:%a' /etc/nginx/ssl-identity/example.com/fullchain.pem)" == 0:600 ]]
}
for fault in test reload; do
  touch "/root/fail-$fault"
  refuse
  root_unchanged
  rm "/root/fail-$fault"
done
PYTHONPATH=/root/fault-python refuse
root_unchanged
cp /root/renewed-key /root/.acme.sh/nginxx-deploy/example.com/privkey.pem
refuse
root_unchanged
cp /root/initial-key /root/.acme.sh/nginxx-deploy/example.com/privkey.pem
printf malformed > /root/.acme.sh/nginxx-deploy/example.com/fullchain.pem
refuse
root_unchanged
cp /root/initial-chain /root/.acme.sh/nginxx-deploy/example.com/fullchain.pem
# Unsafe root account material is rejected before executing its cron command.
chmod 0666 /root/.acme.sh/acme.sh
cp /root/acme.log /root/acme-before
if /usr/local/libexec/nginxx-acme-0 cron; then exit 1; fi
cmp /root/acme.log /root/acme-before
root_unchanged
chmod 0700 /root/.acme.sh/acme.sh
mv /usr/sbin/nginx-real /usr/sbin/nginx
echo 'ok: password-sudo user deploys root:600 keys; root cron renews with expired sudo; user hooks stay unprivileged; symlink source rejected'
