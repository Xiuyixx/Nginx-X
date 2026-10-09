#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034
set -euo pipefail
source "$(dirname "$0")/fixtures/test-environment.sh"
cd "$(dirname "$0")/.."
source ./nx.sh
root="$NX_TEST_ENV_ROOT"
SUDO=''
git init -q --bare "$root/origin"
git init -q -b main "$root/publisher"
git -C "$root/publisher" config user.email test@example.test
git -C "$root/publisher" config user.name Test
echo first > "$root/publisher/file"
git -C "$root/publisher" add .
git -C "$root/publisher" commit -qm first
git -C "$root/publisher" remote add origin "$root/origin"
git -C "$root/publisher" push -qu origin main
git clone -q -b main "$root/origin" "$root/client"
first=$(git -C "$root/client" rev-parse HEAD)
nx_git_sync "$root/client" main
printf unchanged > "$root/entry"
reject() {
 if nx_update_publish "$root/client" "$root/entry" "$root/client" > "$root/log" 2>&1; then echo 'FAIL: unsafe update accepted'; exit 1; fi
 [[ $(cat "$root/entry") == unchanged ]]
}
echo second >> "$root/publisher/file"
git -C "$root/publisher" commit -qam second
git -C "$root/publisher" push -q
nx_git_sync "$root/client" main
second=$(git -C "$root/client" rev-parse HEAD)
[[ "$first" != "$second" ]]
# Simulate remote force rollback: old code must not be reinstalled as latest.
git -C "$root/publisher" push -q --force origin "$first:main"
reject
grep -q "HEAD=$second target=$first ahead=1 behind=0" "$root/log"
git -C "$root/publisher" push -q origin main
printf dirty >> "$root/client/file"; reject
git -C "$root/client" checkout -- file
printf untracked > "$root/client/untracked"; reject; rm "$root/client/untracked"
git -C "$root/client" checkout -q --detach; reject
git -C "$root/client" checkout -q main
git -C "$root/client" config branch.main.merge refs/heads/other; reject
git -C "$root/client" config branch.main.merge refs/heads/main
git -C "$root/client" config user.email test@example.test
git -C "$root/client" config user.name Test
echo local > "$root/client/local"
git -C "$root/client" add .; git -C "$root/client" commit -qm local
echo remote >> "$root/publisher/file"
git -C "$root/publisher" commit -qam remote; git -C "$root/publisher" push -q
reject; grep -q 'ahead=1 behind=1' "$root/log"
git -C "$root/client" remote set-url origin "$root/offline"; reject
grep -q 'fetch 失败' "$root/log"
# The standalone bootstrap must carry the exact same gate (also under sudo).
product=$(declare -f nx_git_sync)
source ./install.sh
[[ $(declare -f nx_git_sync) == "$product" ]]
echo 'PASS: same/ff/rollback/diverged/dirty/untracked/detached/upstream/offline gate; entry untouched'
