#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/Xiuyixx/Nginx-X.git"
REPO_BRANCH="main"
INSTALL_DIR="${INSTALL_DIR:-/opt/Nginx-X}"
TARGET_BIN="${TARGET_BIN:-/usr/local/bin/nx}"
NO_RUN="${NO_RUN:-0}"

SUDO=""
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  SUDO="sudo"
fi

confirm() {
  local prompt="$1"
  read -rp "${prompt} [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

install_git_if_needed() {
  if command -v git >/dev/null 2>&1; then
    return 0
  fi

  echo "[INFO] 未检测到 git，正在安装..."
  if command -v apt-get >/dev/null 2>&1; then
    if ! ${SUDO} apt-get update; then
      echo "[ERROR] apt-get update 失败。"
      exit 1
    fi
    if ! ${SUDO} apt-get install -y git; then
      echo "[ERROR] git 安装失败。"
      exit 1
    fi
  elif command -v dnf >/dev/null 2>&1; then
    if ! ${SUDO} dnf install -y git; then
      echo "[ERROR] git 安装失败。"
      exit 1
    fi
  elif command -v yum >/dev/null 2>&1; then
    if ! ${SUDO} yum install -y git; then
      echo "[ERROR] git 安装失败。"
      exit 1
    fi
  elif command -v apk >/dev/null 2>&1; then
    if ! ${SUDO} apk add git; then
      echo "[ERROR] git 安装失败。"
      exit 1
    fi
  elif command -v opkg >/dev/null 2>&1; then
    if ! ${SUDO} opkg update; then
      echo "[ERROR] opkg update 失败。"
      exit 1
    fi
    if ! ${SUDO} opkg install git; then
      echo "[ERROR] git 安装失败。"
      exit 1
    fi
  else
    echo "[ERROR] 无法自动安装 git，请手动安装后重试。"
    exit 1
  fi
}

install_local() {
  local script_dir source_script
  script_dir="$(get_script_dir)"
  source_script="${script_dir}/nx.sh"

  if [[ ! -f "$source_script" ]]; then
    echo "[ERROR] nx.sh not found in ${script_dir}"
    exit 1
  fi

  [[ "$TARGET_BIN" == /* && "$TARGET_BIN" != */ ]] || { echo "[ERROR] TARGET_BIN must be an absolute file path"; return 1; }
  [[ ! -d "$TARGET_BIN" ]] || { echo "[ERROR] TARGET_BIN is a directory (or directory symlink)"; return 1; }
  ${SUDO} mkdir -p "$(dirname "$TARGET_BIN")" || return 1
  # Resolve only the parent: replacing a symlink must not overwrite its target.
  TARGET_BIN="$(cd "$(dirname "$TARGET_BIN")" && pwd -P)/$(basename "$TARGET_BIN")"
  local bundle stage
  bundle="$(mktemp /tmp/nginxx-bundle-XXXXXX)" || return 1
  if ! NX_BUNDLE_TARGET="$TARGET_BIN" NX_BUNDLE_REPO="$script_dir" bash "${script_dir}/tools/build-bundle.sh" "$bundle"; then
    rm -f "$bundle"
    return 1
  fi
  # --no-run suppresses the menu, not production dependency installation.
  # shellcheck disable=SC2016 # $1 belongs to the privileged child shell
  if ! ${SUDO} bash -c 'source "$1"; ensure_runtime_dependencies' _ "$bundle"; then
    echo "[ERROR] 依赖安装失败；保留已有安装入口。" >&2
    rm -f "$bundle"
    return 1
  fi
  stage="$(${SUDO} mktemp "${TARGET_BIN}.stage.XXXXXX")" || { rm -f "$bundle"; return 1; }
  if ! ${SUDO} install -m 0755 "$bundle" "$stage" || ! ${SUDO} mv -fT "$stage" "$TARGET_BIN"; then
    ${SUDO} rm -f "$stage"
    rm -f "$bundle"
    return 1
  fi
  rm -f "$bundle"

  echo "[OK] Installed. You can now run: nx"

  if [[ "$NO_RUN" != "1" && -t 0 && -t 1 ]]; then
    read -rp "是否立即启动 Nginx-X？[y/N]: " run_now
    if [[ "$run_now" =~ ^[Yy]$ ]]; then
      exec "$TARGET_BIN"
    fi
  fi
}

# Fetch an explicit branch and prove ancestry before touching source or entry.
nx_git_sync() {
  local repo="$1" branch="$2" head target current upstream counts ahead behind dirty
  if ! ${SUDO} git -C "$repo" fetch --no-tags origin "+refs/heads/$branch:refs/remotes/origin/$branch"; then
    echo '[ERROR] fetch 失败；未安装，保留原源码和入口。' >&2; return 1
  fi
  head="$(${SUDO} git -C "$repo" rev-parse HEAD)" || return 1
  target="$(${SUDO} git -C "$repo" rev-parse "refs/remotes/origin/$branch^{commit}")" || return 1
  current="$(${SUDO} git -C "$repo" symbolic-ref --quiet --short HEAD)" || current=detached
  upstream="$(${SUDO} git -C "$repo" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" || upstream=none
  dirty="$(${SUDO} git -C "$repo" status --porcelain --untracked-files=all)" || return 1
  counts="$(${SUDO} git -C "$repo" rev-list --left-right --count "$head...$target")" || return 1
  read -r ahead behind <<< "$counts"
  if [[ -n "$dirty" || "$current" != "$branch" || "$upstream" != "origin/$branch" || "$ahead" != 0 ]]; then
    printf '[ERROR] 源码同步拒绝：HEAD=%s target=%s ahead=%s behind=%s branch=%s upstream=%s dirty=%s\n' \
      "$head" "$target" "$ahead" "$behind" "$current" "$upstream" "${dirty:+yes}" >&2
    echo '可能存在本地提交/分叉/远端回退。请先备份并确认以上目标 SHA，再人工精确同步；不会自动 reset 或丢弃修改。' >&2
    return 1
  fi
  if [[ "$head" != "$target" ]]; then
    ${SUDO} git -C "$repo" merge --ff-only "$target" || return 1
  fi
  [[ "$(${SUDO} git -C "$repo" rev-parse HEAD)" == "$target" && -z "$(${SUDO} git -C "$repo" status --porcelain --untracked-files=all)" ]] || return 1
  printf '[INFO] 源码已核对远端目标：%s\n' "$target"
}

bootstrap_install() {
  echo "[INFO] 开始一键安装 Nginx-X..."

  install_git_if_needed

  if [[ -d "$INSTALL_DIR/.git" ]]; then
    echo "[INFO] 检测到已安装目录，正在更新..."
    nx_git_sync "$INSTALL_DIR" "$REPO_BRANCH" || return 1
  elif [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]]; then
    echo "[ERROR] 目标目录已存在且不是 Git 仓库；保留原目录：$INSTALL_DIR"
    return 1
  else
    echo "[INFO] 克隆仓库到 $INSTALL_DIR"
    if ! ${SUDO} git clone -b "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR"; then
      echo "[ERROR] 克隆仓库失败。"
      exit 1
    fi
  fi

  if ! ${SUDO} env NO_RUN=1 TARGET_BIN="$TARGET_BIN" INSTALL_DIR="$INSTALL_DIR" bash "$INSTALL_DIR/install.sh" --no-run; then
    echo "[ERROR] 安装器执行失败。"
    exit 1
  fi

  if [[ "$NO_RUN" != "1" && -t 0 && -t 1 ]]; then
    read -rp "是否立即启动 Nginx-X？[y/N]: " run_now
    if [[ "$run_now" =~ ^[Yy]$ ]]; then
      echo "[OK] 安装完成，正在启动 Nginx-X..."
      exec "$TARGET_BIN"
    fi
  fi
}

get_script_dir() {
  local src=""
  if [[ ${BASH_SOURCE[0]-} != "" ]]; then
    src="${BASH_SOURCE[0]}"
  else
    src="$0"
  fi
  if [[ -n "$src" ]] && [[ -e "$src" ]]; then
    cd "$(dirname "$src")" && pwd
  else
    pwd
  fi
}

has_local_nx() {
  local script_dir
  script_dir="$(get_script_dir)"
  [[ -f "${script_dir}/nx.sh" ]]
}

# BASH_SOURCE[0] is unset for `bash -c`/stdin execution under `set -u`.
# An empty source marker means this is an executable entry, not a source call.
if [[ -n "${BASH_SOURCE[0]-}" && "${BASH_SOURCE[0]-}" != "$0" ]]; then return 0; fi

for arg in "$@"; do
  case "$arg" in
    --no-run) NO_RUN="1" ;;
    --help|-h) echo "Usage: install.sh [--no-run] (installs missing runtime tools; --no-run skips menu only)"; exit 0 ;;
  esac
done

if has_local_nx; then
  install_local
else
  bootstrap_install
fi
