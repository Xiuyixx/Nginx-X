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
  printf renewed > "$HOME/.acme.sh/nginxx-deploy/example.com/privkey.pem"
  printf renewed > "$HOME/.acme.sh/nginxx-deploy/example.com/fullchain.pem"
else
  while (($#)); do
    case "$1" in --key-file|--fullchain-file) printf initial > "$2"; shift ;; esac
    shift
  done
fi
ACME
chmod +x /home/acmetest/.acme.sh/acme.sh
chown -R acmetest:acmetest /home/acmetest
mv /usr/sbin/nginx /usr/sbin/nginx-real
cat > /usr/sbin/nginx <<'NGINX'
#!/bin/sh
[ "$(id -u)" = 0 ] || exit 90
printf '%s\n' "$*" >> /root/identity-nginx.log
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
[[ "$(cat /etc/nginx/ssl-identity/example.com/privkey.pem)" == renewed ]]
[[ ! -e /root/acme-hook-escalated ]]
[[ "$(stat -c %u /home/acmetest/.acme.sh/acme.sh)" == "$uid" ]]
# A forged source symlink cannot disclose root-only bytes.
printf private-root-only > /root/private-identity
rm /home/acmetest/.acme.sh/nginxx-deploy/example.com/privkey.pem
ln -s /root/private-identity /home/acmetest/.acme.sh/nginxx-deploy/example.com/privkey.pem
if "/usr/local/libexec/nginxx-acme-$uid" deploy; then exit 1; fi
[[ "$(cat /etc/nginx/ssl-identity/example.com/privkey.pem)" == renewed ]]
mv /usr/sbin/nginx-real /usr/sbin/nginx
echo 'ok: password-sudo user deploys root:600 keys; root cron renews with expired sudo; user hooks stay unprivileged; symlink source rejected'
