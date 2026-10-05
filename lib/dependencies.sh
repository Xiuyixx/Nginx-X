#!/usr/bin/env bash
# Tool installation is a lifecycle action, never a source-time operation.
nx_dependency_present() {
  local path
  path="$(command -v "$1" 2>/dev/null || true)"
  [[ -n "$path" && -x "$path" ]]
}

# Install firewall-related tools after downloading packages. Maintainer hooks
# run in private mount/network/PID namespaces with a private /run, so they
# cannot reach host systemd/dbus or the host firewall. Existing policy-rc.d and
# /etc/nftables.conf are never replaced or masked.
nx_install_backend_packages() {
  local manager="$1"; shift
  local scratch rc=0
  scratch="$(mktemp -d /tmp/nginxx-packages-XXXXXX)" || return 1
  chmod 0755 "$scratch" || { rm -rf "$scratch"; return 1; }
  if ! ${SUDO:-} bash -s -- "$scratch" "$manager" "$@" <<'NXPACKAGES'
set -euo pipefail
scratch="$1"; manager="$2"; shift 2
command -v unshare >/dev/null || { echo 'dependencies: util-linux unshare required for safe package hooks' >&2; exit 1; }
# Prove isolation before any package transaction or repository refresh.
unshare --propagation unchanged --mount --net --pid --fork --mount-proc bash -ec 'mount --make-rprivate /; mount -t tmpfs tmpfs /run; true' || {
  echo 'dependencies: cannot isolate package hooks; refusing firewall-tool installation' >&2; exit 1;
}
case "$manager" in
 apt)
  apt-get update
  mkdir "$scratch/cache" "$scratch/cache/partial"
  apt-get -s --no-install-recommends install "$@" > "$scratch/plan"
  if grep -Eq '^Inst (systemd[^ ]*|init-system-helpers|openrc|sysvinit[^ ]*) ' "$scratch/plan"; then
    echo "dependencies: transaction changes init helpers; refusing unsafe automatic installation" >&2; exit 1
  fi
  apt-get -o "Dir::Cache::archives=$scratch/cache" install -y --download-only --no-install-recommends "$@"
  ;;
 dnf|yum)
  "$manager" install -y --downloadonly "$@"
  ;;
 apk)
  mkdir "$scratch/cache"
  apk fetch --recursive --output "$scratch/cache" "$@"
  # All signed APK artifacts are passed explicitly at install time; no
  # unsigned synthetic repository or --allow-untrusted is needed.
  ;;
 *) echo "dependencies: unsupported safe package manager: $manager" >&2; exit 1;;
esac

unshare --propagation unchanged --mount --net --pid --fork --mount-proc bash -s -- "$scratch" "$manager" "$@" <<'NXISOLATED'
set -euo pipefail
scratch="$1"; manager="$2"; shift 2
mount --make-rprivate /
mount -t tmpfs tmpfs /run
# No host init sockets or PIDs exist in this view. Inhibit helper enable /
# preset operations too, only inside this mount namespace (never host masks).
for helper in /usr/bin/systemctl /bin/systemctl /usr/bin/deb-systemd-helper /usr/sbin/invoke-rc.d /usr/bin/deb-systemd-invoke /sbin/rc-service /usr/sbin/rc-service /sbin/rc-update /usr/lib/systemd/systemd-update-helper /usr/lib/systemd/systemd-sysv-install; do
  if [[ -e "$helper" ]]; then mount --bind /bin/true "$helper"; fi
done
# Package conffile preservation is enforced by the native package manager;
# Nginx-X does not supply, edit, load or replace /etc/nftables.conf.
case "$manager" in
 apt) apt-get -o "Dir::Cache::archives=$scratch/cache" -o Dpkg::Options::=--force-confold install -y --no-download --no-install-recommends "$@" ;;
 dnf|yum) "$manager" --cacheonly install -y "$@" ;;
 apk) apk --no-network add "$scratch/cache"/*.apk ;;
esac
NXISOLATED
NXPACKAGES
  then
    rc=1
    printf 'dependencies: package installation did not complete (%s: %s); old nx entry was not replaced, but the package manager may have left partial package state; resolve it before retrying\n' "$manager" "$*" >&2
  fi
  ${SUDO:-} rm -rf "$scratch" || return 1
  return "$rc"
}

nx_ensure_backend_dependencies() {
  local manager="$1" cmd
  local -a packages=() missing=()
  # OpenRC/OpenWrt are supported for Nginx management, not backend protection.
  # Do not install or switch init systems to make protection appear supported.
  [[ "$(uname -s)" == Linux ]] || return 0
  case "$manager" in
    apt|dnf|yum|apk) ;;
    opkg) return 0 ;;
    *)
      if nx_dependency_present nft && nx_dependency_present ss; then return 0; fi
      printf 'dependencies: no supported package manager for missing nft/ss\n' >&2; return 1 ;;
  esac
  for cmd in nft ss; do
    nx_dependency_present "$cmd" || missing+=("$cmd")
  done
  [[ ${#missing[@]} -gt 0 ]] || return 0
  for cmd in "${missing[@]}"; do
    case "$cmd:$manager" in
      nft:*) packages+=(nftables) ;;
      ss:dnf|ss:yum) packages+=(iproute) ;;
      ss:*) packages+=(iproute2) ;;
    esac
  done
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    if ! nx_dependency_present sudo || ! sudo -v; then
      printf 'dependencies: sudo privileges required to install missing tools: %s\n' "${missing[*]}" >&2
      return 1
    fi
  fi
  nx_install_backend_packages "$manager" "${packages[@]}" || return 1
  hash -r
  for cmd in "${missing[@]}"; do
    nx_dependency_present "$cmd" || { printf 'dependencies: command still unavailable: %s\n' "$cmd" >&2; return 1; }
  done
}
