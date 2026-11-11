#!/usr/bin/env bash
# Execute privileged ACME proofs only in a COPY of a prepared Alpine rootfs.
# Usage: bash tests/acme_rootfs_runner.sh /tmp/prepared-alpine identity|lifecycle|audit
# Prepare the rootfs separately with apk: bash nginx python3 openssl curl sudo
# shadow coreutils findutils procps util-linux iproute2 diffutils.
# Dependencies may download during preparation; test execution has no network
# except its private loopback. No host users, cron, services or firewall change.
set -euo pipefail
if [[ $# == 0 ]]; then echo 'SKIP: ACME rootfs runner requires an explicit disposable rootfs and proof'; exit 0; fi
[[ $EUID == 0 && $# == 2 ]] || { echo "usage: $0 PREPARED_ALPINE_ROOTFS identity|lifecycle|audit" >&2; exit 2; }
base=$(realpath "$1")
[[ $base != / && -f "$base/etc/alpine-release" && -x "$base/bin/bash" ]] || exit 2
case "$2" in
 identity|lifecycle) proof="tests/acme_${2}_isolated.sh" ;;
 audit) proof=tests/cert_audit_20261004.sh ;;
 *) exit 2 ;;
esac
repo=$(cd "$(dirname "$0")/.." && pwd)
run=$(mktemp -d /tmp/nginxx-acme-rootfs-run-XXXXXX)
# Retain logs and source snapshot for a precise, reproducible evidence boundary.
echo "ACME disposable execution and evidence: $run"
mkdir "$run/rootfs" "$run/source"
cp -a --reflink=auto "$base/." "$run/rootfs/"
tar -C "$repo" --exclude=.git -cf - . | tar -C "$run/source" -xf -
find "$run/source" -type f -print0 | sort -z | xargs -0 sha256sum > "$run/source.sha256"
mkdir -p "$run/rootfs/project" "$run/rootfs/proc" "$run/rootfs/dev"
# --kill-child ensures all daemons die with the private PID namespace. Mounts
# cannot propagate to the host; project files are a read-only frozen snapshot.
if unshare --mount --pid --net --fork --kill-child bash -s -- "$run" "$proof" > "$run/test.log" 2>&1 <<'NAMESPACE'
set -euo pipefail
run=$1; proof=$2
mount --make-rprivate /
mount --bind "$run/source" "$run/rootfs/project"
mount -o remount,bind,ro "$run/rootfs/project"
mount -t proc proc "$run/rootfs/proc"
mount -t tmpfs -o mode=755,nosuid tmpfs "$run/rootfs/dev"
for device in 'null 1 3' 'zero 1 5' 'random 1 8' 'urandom 1 9' 'tty 5 0'; do
 read -r name major minor <<< "$device"
 mknod -m 666 "$run/rootfs/dev/$name" c "$major" "$minor"
done
ln -s /proc/self/fd "$run/rootfs/dev/fd"
ln -s /proc/self/fd/0 "$run/rootfs/dev/stdin"
ln -s /proc/self/fd/1 "$run/rootfs/dev/stdout"
ln -s /proc/self/fd/2 "$run/rootfs/dev/stderr"
chroot "$run/rootfs" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
 NX_ACME_ISOLATED=1 NX_CERT_AUDIT_NAMESPACE=1 NX_CERT_AUDIT_KEEP=1 \
 /bin/bash -c 'set -e; ip link set lo up; cd /project; nginx -v; bash "$1"' _ "$proof"
NAMESPACE
then
 cat "$run/test.log"
 echo "PASS $proof; evidence: $run"
else
 rc=$?
 cat "$run/test.log" >&2
 echo "FAIL $proof (exit $rc); evidence: $run" >&2
 exit "$rc"
fi
