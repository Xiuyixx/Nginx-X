#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2015
# EXIT callback and deliberate failure propagation for compound probes.
# Official packages first; USTC paths verified against Release/repomd.xml.
nx_repository_candidates() {
  printf '%s\n' https://nginx.org/packages https://mirrors.ustc.edu.cn/nginx
}

nx_repo_fetch() {
  curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 5 --max-time 20 "$1" -o "$2"
}

# Reject unknown primary keys, including a malicious extra key in a valid bundle.
# Trust anchors published at https://nginx.org/en/linux_packages.html.
nx_repo_validate_key() {
  local records fingerprints fingerprint
  records="$(gpg --batch --homedir "$2" --show-keys --with-colons "$1" 2>/dev/null)" || return 1
  fingerprints="$(printf '%s\n' "$records" | awk -F: '$1=="pub" {primary=1; next} $1=="fpr" && primary {print $10; primary=0}')"
  [[ -n "$fingerprints" ]] || return 1
  while IFS= read -r fingerprint; do
    case "$fingerprint" in
      573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62|8540A6F18833A80E9C1653A42FD21310B49F6B46|9E9BE90EACBCDE69FE9B204CBCDCD8A38D88A2B3) ;;
      *) return 1 ;;
    esac
  done <<< "$fingerprints"
}

nx_repo_metadata_valid() {
  python3 - "$1" "$2" <<'PY'
import pathlib, sys, xml.etree.ElementTree as ET
try:
    data = pathlib.Path(sys.argv[2]).read_text()
    if sys.argv[1] == 'apt':
        assert 'Origin: nginx\n' in data and '\nSHA256:\n' in data
    else:
        root = ET.fromstring(data)
        assert root.tag == '{http://linux.duke.edu/metadata/repo}repomd'
        assert root.findall('{http://linux.duke.edu/metadata/repo}data')
except Exception:
    sys.exit(1)
PY
}

# Transaction owns just these two regular files; indexes and installed packages
# are not rolled back. Refuse symlinks rather than mutate an unsnapshotted target.
nx_install_repository() (
  local pkg="$1" os="$2" codename="$3" version="$4" arch="$5"
  local source key work base metadata key_url success=0 changed=0 restore_failed=0
  case "$pkg" in
    apt)
      [[ "$os" == ubuntu || "$os" == debian ]] || { error "没有适用于 $os 的官方 APT 仓库。"; return 1; }
      [[ "$codename" =~ ^[a-z][a-z0-9-]*$ ]] || return 1
      source="${NX_APT_SOURCE:-/etc/apt/sources.list.d/nginx.list}"
      key="${NX_REPO_KEY:-/usr/share/keyrings/nginx-archive-keyring.gpg}"
      metadata="$os/dists/$codename/Release" ;;
    dnf|yum)
      case "$os" in centos|rhel|rocky|almalinux) ;; *) error "没有适用于 $os 的官方 RPM 仓库。"; return 1 ;; esac
      version="${version%%.*}"
      [[ "$version" =~ ^[0-9]+$ && "$arch" =~ ^(x86_64|aarch64)$ ]] || return 1
      source="${NX_RPM_SOURCE:-/etc/yum.repos.d/nginx.repo}"
      key="${NX_REPO_KEY:-/etc/pki/rpm-gpg/nginx-signing.key}"
      metadata="centos/$version/$arch/repodata/repomd.xml" ;;
    *) return 1 ;;
  esac
  local target
  for target in "$source" "$key"; do
    [[ ! -L "$target" && ( ! -e "$target" || -f "$target" ) ]] || { error "仓库目标不是普通文件：$target"; return 1; }
  done
  ${SUDO} mkdir -p "$(dirname "$source")" "$(dirname "$key")" || return 1
  work="$(mktemp -d)" || return 1
  chmod 700 "$work" || return 1
  mkdir "$work/gpg" || return 1
  chmod 700 "$work/gpg" || return 1
  # shellcheck disable=SC2317
  nx_repo_finish() {
    local item
    if [[ "$success" != 1 && "$changed" == 1 ]]; then
      for item in source key; do
        if [[ -e "$work/$item.backup" ]]; then
          [[ ! -L "${!item}" && ( ! -e "${!item}" || -f "${!item}" ) ]] && ${SUDO} cp -aT "$work/$item.backup" "${!item}" || restore_failed=1
        else
          ${SUDO} rm -f -- "${!item}" || restore_failed=1
        fi
      done
    fi
    if [[ "$restore_failed" == 1 ]]; then
      error "恢复源/密钥失败，保留恢复副本：$work"
    else
      ${SUDO} rm -rf -- "$work"
    fi
  }
  trap nx_repo_finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  [[ ! -e "$source" ]] || ${SUDO} cp -a "$source" "$work/source.backup" || return 1
  [[ ! -e "$key" ]] || ${SUDO} cp -a "$key" "$work/key.backup" || return 1
  while IFS= read -r base; do
    note "尝试仓库：$base"
    if ! nx_repo_fetch "$base/$metadata" "$work/metadata" || ! nx_repo_metadata_valid "$pkg" "$work/metadata"; then continue; fi
    key_url="${base%/packages}/keys/nginx_signing.key"
    if ! nx_repo_fetch "$key_url" "$work/key.asc" || ! nx_repo_validate_key "$work/key.asc" "$work/gpg"; then continue; fi
    rm -f "$work/key.ready"
    if [[ "$pkg" == apt ]]; then
      gpg --batch --yes --homedir "$work/gpg" --dearmor -o "$work/key.ready" "$work/key.asc" || continue
      printf 'deb [signed-by=%s] %s/%s %s nginx\n' "$key" "$base" "$os" "$codename" > "$work/source.ready" || return 1
    else
      cp "$work/key.asc" "$work/key.ready" || return 1
      printf '[nginx-stable]\nname=nginx stable repo\nbaseurl=%s/centos/%s/%s/\ngpgcheck=1\nenabled=1\ngpgkey=file://%s\nmodule_hotfixes=true\n' "$base" "$version" "$arch" "$key" > "$work/source.ready" || return 1
    fi
    changed=1
    # Stage on destination filesystem, then rename; never truncate live key.
    nx_repo_publish "$work/key.ready" "$key" && nx_repo_publish "$work/source.ready" "$source" || return 1
    if [[ "$pkg" == apt ]]; then
      local -a opts=(-o "Dir::Etc::sourcelist=$source" -o 'Dir::Etc::sourceparts=-' -o 'APT::Get::List-Cleanup=0' -o 'Acquire::http::Timeout=20' -o 'Acquire::https::Timeout=20' -o 'Acquire::Retries=0' -o 'APT::Update::Error-Mode=any')
      if ! ${SUDO} apt-get "${opts[@]}" update || ! ${SUDO} apt-get "${opts[@]}" install -y nginx; then continue; fi
    else
      ${SUDO} "$pkg" --disablerepo='*' --enablerepo=nginx-stable --setopt=timeout=20 --setopt=retries=1 makecache -y || continue
      # Dependencies may come from existing OS sources; do not alter them.
      ${SUDO} "$pkg" --setopt=timeout=20 --setopt=retries=1 --exclude=nginx-mod* install -y nginx --setopt="*.exclude=nginx" --setopt=nginx-stable.exclude= || continue
    fi
    success=1
    return 0
  done < <(nx_repository_candidates)
  error "没有可用的已签名 Nginx 仓库；恢复原源和密钥（不撤销已安装的软件包）。"
  return 1
)

nx_repo_publish() {
  local tmp
  [[ ! -L "$2" && ( ! -e "$2" || -f "$2" ) ]] || return 1
  tmp="$(${SUDO} mktemp "$(dirname "$2")/.nx-repo.XXXXXX")" || return 1
  if ${SUDO} install -m 0644 "$1" "$tmp" && ${SUDO} mv -fT -- "$tmp" "$2"; then return 0; fi
  ${SUDO} rm -f -- "$tmp"
  return 1
}

nx_using_official_repository() {
  # Exact approved roots, not arbitrary mirrors or simply an nginx.repo filename.
  grep -rsqE 'https://(nginx\.org/packages|mirrors\.ustc\.edu\.cn/nginx)/(ubuntu|debian|centos)/?[[:space:]/$]' \
    "${NX_APT_SOURCE:-/etc/apt/sources.list.d/nginx.list}" \
    "${NX_RPM_SOURCE:-/etc/yum.repos.d/nginx.repo}" /etc/apt/sources.list 2>/dev/null
}

# Bootstrap only missing tools. Exclude the dedicated old nginx source from
# dependency refresh without removing/modifying it, so a broken old endpoint
# cannot prevent the new candidate transaction.
nx_install_repository_dependencies() (
  local pkg="$1" cmd work file
  local -a missing=()
  for cmd in python3 curl wget socat gpg; do check_cmd "$cmd" || missing+=("$cmd"); done
  if [[ "$pkg" == apt ]]; then check_cmd lsb_release || missing+=(lsb-release); fi
  [[ ${#missing[@]} -gt 0 ]] || return 0
  if [[ "$pkg" == apt ]]; then
    work="$(mktemp -d)" || return 1
    trap 'rm -rf -- "$work"' EXIT
    mkdir "$work/parts" || return 1
    for file in "${NX_APT_PARTS:-/etc/apt/sources.list.d}"/*; do
      [[ -f "$file" && "$file" != "${NX_APT_SOURCE:-/etc/apt/sources.list.d/nginx.list}" ]] || continue
      cp "$file" "$work/parts/" || return 1
    done
    local -a opts=(-o "Dir::Etc::sourceparts=$work/parts" -o 'Acquire::http::Timeout=20' -o 'Acquire::https::Timeout=20' -o 'Acquire::Retries=0' -o 'APT::Update::Error-Mode=any')
    ${SUDO} apt-get "${opts[@]}" update || return 1
    ${SUDO} apt-get "${opts[@]}" install -y python3 curl wget socat cron gpg lsb-release ca-certificates || return 1
  else
    ${SUDO} "$pkg" --disablerepo='nginx*' --setopt=timeout=20 --setopt=retries=1 install -y python3 curl wget socat cronie gnupg2 || return 1
  fi
)
