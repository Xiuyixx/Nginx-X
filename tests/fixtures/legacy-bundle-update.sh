# shellcheck shell=bash
update_script() {
  # 优先使用当前脚本所在目录（如果它本身是个 git 仓库），
  # 其次 fallback 到传统安装目录 REPO_INSTALL_DIR（/opt/Nginx-X）。
  # 以适配安装到非标准路径 / 开发环境直接运行的场景。
  local work_dir=""
  if [[ -n "${SCRIPT_DIR:-}" && -d "${SCRIPT_DIR}/.git" ]]; then
    work_dir="${SCRIPT_DIR}"
  elif [[ -d "${REPO_INSTALL_DIR}/.git" ]]; then
    work_dir="${REPO_INSTALL_DIR}"
  fi

  note "正在从 ${REPO_URL} (分支: ${REPO_BRANCH}) 更新脚本..."

  if [[ -n "$work_dir" ]]; then
    # 校对 remote，防止已仓库指向旧 fork
    local cur_remote=""
    cur_remote="$(${SUDO} git -C "$work_dir" remote get-url origin 2>/dev/null || echo '')"
    if [[ -n "$cur_remote" && "$cur_remote" != "$REPO_URL" ]]; then
      warn "当前仓库 remote 与内置 REPO_URL 不一致："
      warn "  本地: $cur_remote"
      warn "  预期: $REPO_URL"
      if ! confirm "仍从本地 remote 拉取（保留现有配置）？"; then
        info "已取消更新。"
        return 0
      fi
    fi
    if ! ${SUDO} git -C "$work_dir" pull --ff-only origin "${REPO_BRANCH}"; then
      error "拉取最新代码失败，请检查网络或手动更新。"
      return 1
    fi
  elif [[ -d "${REPO_INSTALL_DIR}" ]]; then
    warn "安装目录存在但不是 Git 仓库，将重新克隆..."
    ${SUDO} rm -rf "${REPO_INSTALL_DIR}"
    if ! ${SUDO} git clone -b "${REPO_BRANCH}" "${REPO_URL}" "${REPO_INSTALL_DIR}"; then
      error "克隆仓库失败，请检查网络。"
      return 1
    fi
    work_dir="${REPO_INSTALL_DIR}"
  else
    if ! ${SUDO} git clone -b "${REPO_BRANCH}" "${REPO_URL}" "${REPO_INSTALL_DIR}"; then
      error "克隆仓库失败，请检查网络。"
      return 1
    fi
    work_dir="${REPO_INSTALL_DIR}"
  fi

  # 推断 nx 可执行文件的安装目标：
  # 1) 若 command -v nx 能找到，使用它的实际路径
  # 2) 否则 fallback 到 /usr/local/bin/nx
  local target_bin=""
  if check_cmd nx; then
    target_bin="$(command -v nx 2>/dev/null || true)"
  fi
  [[ -z "$target_bin" ]] && target_bin="/usr/local/bin/nx"

  # 对比更新前后内容：无变化则提示已最新并返回菜单，不重启
  local bin_md5_before=""
  if [[ -f "$target_bin" ]] && check_cmd md5sum; then
    bin_md5_before="$(md5sum "$target_bin" 2>/dev/null | awk '{print $1}')"
  fi

  ${SUDO} env TARGET_BIN="$target_bin" bash "${work_dir}/install.sh" --no-run || return 1

  local bin_md5_after=""
  if check_cmd md5sum; then
    bin_md5_after="$(md5sum "$target_bin" 2>/dev/null | awk '{print $1}')"
  fi

  if [[ -n "$bin_md5_before" && "$bin_md5_before" == "$bin_md5_after" ]]; then
    info "当前已是最新版本（${target_bin}）。"
    return 0
  fi

  info "脚本已更新到最新版本（${target_bin}）。"

  # 是否自动重启进入新版本（在交互式主菜单中才触发，直接 exec 替换当前进程）
  if [[ "${NX_IN_MENU:-0}" == "1" ]]; then
    note "正在重启 nx 并进入新版本..."
    sleep 1
    exec "$target_bin"
  fi
  note "重新启动 nx 后生效。"
}

