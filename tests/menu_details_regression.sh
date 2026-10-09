#!/usr/bin/env bash
# shellcheck disable=SC1090,SC1091,SC2034,SC2317
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
root="$NX_TEST_ENV_ROOT"
bash tools/build-bundle.sh "$root/bundle"
for entry in "$PWD/nx.sh" "$root/bundle"; do
 (
 source "$entry"
 clear() { :; }
 require_nginx_installed() { :; }
 pause() { read -r _ || return 0; }
 rm -f "$CONF_DIR"/*
 printf '# managed_by=Nginx-X\nserver { listen 80; server_name example.com; }\n' > "$CONF_DIR/a.conf"
 printf '# managed_by=Nginx-X\nserver { listen 443 ssl; server_name secure.test; }\n' > "$CONF_DIR/b.conf"
 printf '# managed_by=Nginx-X\nserver {\n' > "$CONF_DIR/c.conf"
 config_status_summary "$CONF_DIR/a.conf" > "$root/out"
 for text in '域名：example.com' '状态：启用' 'HTTPS：已关闭' '端口：80' '域名限制：不限域名'; do grep -Fxq "$text" "$root/out"; done
 if grep -q '访问保护\||' "$root/out"; then exit 1; fi
 config_status_summary "$CONF_DIR/c.conf" > "$root/out"
 for text in '域名：未知域名' 'HTTPS：未知' '端口：未知' '域名限制：未知'; do grep -Fxq "$text" "$root/out"; done
 config_status_summary "$CONF_DIR/missing.conf" > "$root/out"
 grep -Fxq '状态：未知' "$root/out"
 config_file_action_menu a.conf <<< 0 > "$root/out"
 if grep -q '修改参数：\|编辑配置：' "$root/out"; then exit 1; fi
 grep -Fxq '========== 配置操作 ==========' "$root/out"
 modify_conf() { echo MODIFY; return 10; }
 edit_conf_manual() { echo EDIT; }
 config_file_action_menu a.conf <<< 3 > "$root/out"
 grep -q '修改参数：向导重建' "$root/out"; grep -q MODIFY "$root/out"
 config_file_action_menu a.conf <<< $'4\n' > "$root/out"
 grep -q '编辑配置：直接编辑' "$root/out"; grep -q EDIT "$root/out"
 rc=0; enable_https_from_config_list <<< 0 > "$root/out" || rc=$?
 [[ $rc == 10 ]]
 for text in '开启后 HTTP 会跳转到 HTTPS' '域名：example.com' '文件：a.conf' 'HTTPS：已关闭' '域名：secure.test' 'HTTPS：已开启' '域名：未知域名' 'HTTPS：未知' '0) 返回上级'; do grep -Fq "$text" "$root/out"; done
 # Already-on choice remains a no-op and consumes no certificate input.
 ensure_email_interactive() { echo UNEXPECTED; return 1; }
 enable_https_for_conf_file() { echo UNEXPECTED; return 1; }
 { enable_https_from_config_list; read -r next; [[ $next == PARENT ]]; } <<< $'2\nPARENT' > "$root/out"
 grep -q '无需重复操作' "$root/out"
 if grep -q UNEXPECTED "$root/out"; then exit 1; fi
 for input in 99 ''; do
  rc=0; enable_https_from_config_list <<< "$input" > "$root/out" || rc=$?; [[ $rc == 1 ]]
 done
 rc=0; enable_https_from_config_list < /dev/null > "$root/out" || rc=$?; [[ $rc == 10 ]]
 certificate_preparation_status > "$root/out"
 grep -Fxq '仅检查本地配置，未验证凭据有效性。' "$root/out"
 main_menu > "$root/out"
 grep -Fxq '4) 运行状态' "$root/out"; grep -Fxq '0) 退出脚本' "$root/out"
 echo "PASS: menu details $(basename "$entry")"
 )
done
