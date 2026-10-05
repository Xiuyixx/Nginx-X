#!/usr/bin/env bash
# Real package hooks: run only inside a disposable privileged container/rootfs.
set -euo pipefail
if [[ ${NX_DEPENDENCIES_ISOLATED:-0} != 1 ]]; then
 echo 'SKIP backend dependency package lifecycle: requires disposable privileged rootfs'; exit 0
fi
[[ $EUID == 0 && -r /project/lib/dependencies.sh ]] || exit 1
cd /project
source lib/dependencies.sh
SUDO=''
manager="${NX_DEPENDENCIES_MANAGER:-apt}"
# A separately extracted nft binary seeds rules while nft package is absent.
[[ -x /probe/usr/sbin/nft || -x /probe/sbin/nft ]] || exit 1
probe=/probe/usr/sbin/nft
[[ -x $probe ]] || probe=/probe/sbin/nft
export LD_LIBRARY_PATH=/probe/usr/lib/x86_64-linux-gnu:/probe/lib/x86_64-linux-gnu:/probe/usr/lib64:/probe/usr/lib
"$probe" add table inet nx_dependency_sentinel
"$probe" add chain inet nx_dependency_sentinel marker
"$probe" add rule inet nx_dependency_sentinel marker counter comment 'retain-package-install'
"$probe" -s list ruleset > /tmp/rules.before
# Existing admin configuration must not be overwritten or evaluated.
mkdir -p /etc/systemd/system /usr/sbin
printf '#!/bin/sh\necho policy-called >> /tmp/policy-called\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d
cp /usr/sbin/policy-rc.d /tmp/policy.before
printf '# administrator sentinel\nflush ruleset\n' > /etc/nftables.conf
cp /etc/nftables.conf /tmp/config.before
mkdir -p /run/systemd/system
# Real package hooks must not reach this fixture service manager at all.
# If suppression fails, it clears the isolated sentinel and fails the test.
cat > /usr/bin/systemctl <<'SERVICE'
#!/bin/sh
echo "$*" >> /tmp/systemctl-called
/probe/usr/sbin/nft flush ruleset
exit 1
SERVICE
chmod 0755 /usr/bin/systemctl
cp /usr/bin/systemctl /tmp/systemctl.before
if command -v nft >/dev/null; then echo 'nft must initially be absent' >&2; exit 1; fi
case "$manager" in apt|apk) packages=(nftables iproute2);; dnf|yum) packages=(nftables iproute);; *) exit 1;; esac
nx_install_backend_packages "$manager" "${packages[@]}" || { echo 'FAIL real package installation' >&2; exit 1; }
command -v nft
command -v ss
nft --version
ss -V
"$probe" -s list ruleset > /tmp/rules.after
cmp /tmp/rules.before /tmp/rules.after
cmp /tmp/policy.before /usr/sbin/policy-rc.d
cmp /tmp/config.before /etc/nftables.conf
cmp /tmp/systemctl.before /usr/bin/systemctl
[[ ! -e /tmp/systemctl-called && ! -e /tmp/policy-called ]]
[[ ! -e /etc/systemd/system/multi-user.target.wants/nftables.service ]]
# The production installer must still prepare dependencies with --no-run,
# publish a real standalone bundle, and be repeatable without refreshing sources.
TARGET_BIN=/tmp/installed-nx bash install.sh --no-run
bash -n /tmp/installed-nx
/tmp/installed-nx --help
TARGET_BIN=/tmp/installed-nx bash install.sh --no-run
"$probe" -s list ruleset > /tmp/rules.final
cmp /tmp/rules.before /tmp/rules.final
[[ ! -e /tmp/systemctl-called ]]
echo "PASS real $manager package install and installer --no-run: sentinel rules preserved; no service start/enable; existing admin files preserved"
