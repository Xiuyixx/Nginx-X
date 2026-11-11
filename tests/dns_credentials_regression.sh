#!/usr/bin/env bash
# Dynamic production callbacks and isolated test state are intentional.
# shellcheck disable=SC1090,SC1091,SC2034,SC2317,SC2016
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
root="$NX_TEST_ENV_ROOT"
bash tools/build-bundle.sh "$root/bundle"
for entry in "$PWD/nx.sh" "$root/bundle"; do
  (
    source "$entry"
    export HOME="$root/home" DNS_PROBE="$root/probe"
    mkdir -p "$HOME/.acme.sh"
    cat > "$HOME/.acme.sh/acme.sh" <<'MOCK'
#!/usr/bin/env python3
import json, os, sys
names = 'CF_Token DP_Id DP_Key Ali_Key Ali_Secret HE_Username HE_Password GD_Key GD_Secret HUAWEICLOUD_Username HUAWEICLOUD_Password AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY GCE_Project GCE_ServiceAccountEmail DNS_KEY1 DNS_KEY2'.split()
with open(os.environ['DNS_PROBE'], 'a') as f:
    f.write(json.dumps([sys.argv[1:], {k: os.environ[k] for k in names if k in os.environ}]) + '\n')
if sys.argv[1] == '--issue':
    sys.exit(int(os.environ.get('DNS_FAIL_ISSUE', '0')))
MOCK
    chmod 700 "$HOME/.acme.sh/acme.sh"
    unset CF_Token DP_Id DP_Key Ali_Key Ali_Secret HE_Username HE_Password GD_Key GD_Secret HUAWEICLOUD_Username HUAWEICLOUD_Password AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY GCE_Project GCE_ServiceAccountEmail DNS_PROVIDER DNS_KEY1 DNS_KEY2
    load_email() { ACME_EMAIL=test@example.com; }
    ensure_acme_installed() { "$HOME/.acme.sh/acme.sh" --prerequisite; }
    nx_deploy_certificate() { "$HOME/.acme.sh/acme.sh" --deploy; return "${DNS_FAIL_DEPLOY:-0}"; }
    ensure_acme_cron() { "$HOME/.acme.sh/acme.sh" --schedule; return "${DNS_FAIL_CRON:-0}"; }
    # Every canonical name and legacy alias uses the same mapping; literal
    # metacharacters/UTF-8 never become commands or extra argv words.
    for row in 'cf cloudflare CF_Token - dns_cf' 'dp dnspod DP_Id DP_Key dns_dp' 'ali alidns Ali_Key Ali_Secret dns_ali' 'he he.net HE_Username HE_Password dns_he' 'gd godaddy GD_Key GD_Secret dns_gd' 'hw huaweicloud HUAWEICLOUD_Username HUAWEICLOUD_Password dns_huaweicloud' 'aws route53 AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY dns_aws' 'google gcp GCE_Project GCE_ServiceAccountEmail dns_gcloud'; do
      read -r canonical alias first second plugin <<< "$row"
      for provider in "$canonical" "$alias"; do
        first_value='literal $(touch SHOULD_NOT_EXIST) "值" \\ key'
        second_value='secret two; not shell'
        [[ $second != - ]] || second_value=''
        save_dns_conf "$provider" "$first_value" "$second_value" >/dev/null
        : > "$DNS_PROBE"
        has_dns_config
        [[ ! -v DNS_KEY1 && ! -v DNS_KEY2 && ! -v DNS_PROVIDER ]]
        [[ $(get_dns_issue_args) == "--dns $plugin" ]]
        _issue_cert_dns example.com >/dev/null
        "$HOME/.acme.sh/acme.sh" --after-menu
        python3 - "$DNS_PROBE" "$first" "$first_value" "$second" "$second_value" "$plugin" <<'PY'
import json, sys
path, first, value1, second, value2, plugin = sys.argv[1:]
rows = [json.loads(line) for line in open(path)]
expected = {first: value1}
if second != '-': expected[second] = value2
assert [args[0] for args, env in rows] == ['--prerequisite', '--set-default-ca', '--register-account', '--issue', '--deploy', '--schedule', '--after-menu'], rows
for args, env in rows:
    assert env == (expected if args[0] == '--issue' else {}), rows
    if args[0] == '--issue': assert args == ['--issue', '-d', 'example.com', '--dns', plugin]
PY
        [[ ! -v DNS_KEY1 && ! -v DNS_KEY2 && ! -v DNS_PROVIDER && ! -e SHOULD_NOT_EXIST ]]
      done
    done
    # Failure at issue/deploy/schedule cannot leak to the next menu command.
    save_dns_conf cf token '' >/dev/null
    for stage in ISSUE DEPLOY CRON; do
      export DNS_FAIL_ISSUE=0 DNS_FAIL_DEPLOY=0 DNS_FAIL_CRON=0
      export "DNS_FAIL_$stage=7"
      : > "$DNS_PROBE"
      if _issue_cert_dns example.com > "$root/failure" 2>&1; then exit 1; fi
      "$HOME/.acme.sh/acme.sh" --after-failure
      python3 - "$DNS_PROBE" "$stage" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert rows[-1] == [['--after-failure'], {}], rows
assert all(env == ({'CF_Token':'token'} if args[0]=='--issue' else {}) for args, env in rows), rows
commands = [args[0] for args, env in rows]
if sys.argv[2] == 'ISSUE': assert '--deploy' not in commands
if sys.argv[2] != 'CRON': assert '--schedule' not in commands
PY
      if grep -q '申请并安装成功' "$root/failure"; then exit 1; fi
    done
    unset DNS_FAIL_ISSUE DNS_FAIL_DEPLOY DNS_FAIL_CRON
    # Unsafe, unsupported and incomplete state must not execute ACME.
    for fault in permissions symlink syntax unknown missing-key; do
      save_dns_conf cf token '' >/dev/null
      case $fault in
        permissions) chmod 644 "$DNS_CONF" ;;
        symlink) mv "$DNS_CONF" "$root/actual-dns"; ln -s "$root/actual-dns" "$DNS_CONF" ;;
        syntax) printf 'touch SHOULD_NOT_EXIST\n' >> "$DNS_CONF" ;;
        unknown) save_dns_conf unknown key second >/dev/null ;;
        missing-key) save_dns_conf dp key '' >/dev/null ;;
      esac
      : > "$DNS_PROBE"
      if nx_acme_dns_command --issue -d example.com > "$root/unsafe" 2>&1; then exit 1; fi
      [[ ! -s "$DNS_PROBE" && ! -e SHOULD_NOT_EXIST && ! -v CF_Token ]]
      rm -f "$DNS_CONF"
    done
    # EOF (including a partial secret), empty input and invalid choices never
    # replace an existing 0600 file, and setup success never exports secrets.
    save_dns_conf cf old '' >/dev/null
    cp "$DNS_CONF" "$root/before-dns"
    for input in '' $'1\npartial' $'2\nid\n' $'1\n\n' $'9\n'; do
      printf %s "$input" > "$root/input"
      rc=0; setup_dns_api < "$root/input" > "$root/eof" 2>&1 || rc=$?
      [[ $rc == 10 || $rc == 1 ]]
      cmp "$DNS_CONF" "$root/before-dns"
      [[ $(stat -c %a "$DNS_CONF") == 600 && ! -v CF_Token ]]
    done
    setup_dns_api <<< $'1\nnew-token\nn' > "$root/setup" 2>&1
    [[ $(nx_state_read "$DNS_CONF" DNS_KEY1) == new-token && ! -v CF_Token ]]
    "$HOME/.acme.sh/acme.sh" --after-setup
    python3 - "$DNS_PROBE" <<'PY'
import json, sys
assert json.loads(open(sys.argv[1]).readlines()[-1]) == [['--after-setup'], {}]
PY
  )
  echo "PASS: $(basename "$entry") DNS aliases, child-only credentials, failures, safe state, EOF/cancel"
done
python3 tests/dns_credentials_pty.py "$PWD/nx.sh" "$root/bundle" "$root"
