#!/usr/bin/env bash
# stale-branch-sweep.sh (SessionStart hook) の判定テスト。
# 使い捨ての git リポで hook を直接叩く (ネットワークにも実マシンの git 設定にも触らない)。
# origin/main は remote を持たせず refs/remotes/origin/main を直接張って再現する。
#
#   bash scripts/test-rs-branch-sweep.sh
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
hook="$repo_root/plugins/repo-standards/hooks/scripts/stale-branch-sweep.sh"

failures=0

# check <ケース名> <期待> <実際>
check() {
  if [ "$2" = "$3" ]; then
    echo "  [ok]   $1 → $3"
  else
    echo "  [FAIL] $1 → 期待 $2 / 実際 $3"
    failures=$((failures + 1))
  fi
}

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
: > "$sandbox/empty-gitconfig"
export GIT_CONFIG_GLOBAL="$sandbox/empty-gitconfig"

g() { git -C "$repo" -c user.email=t@example.com -c user.name=t "$@"; }
branches() { g for-each-ref --format='%(refname:short)' refs/heads | sort | paste -sd, -; }
run_hook() { printf '{"cwd":"%s"}' "$repo" | "$hook" 2>/dev/null; }

# 3 コミットの main と、それを指す origin/main を持つリポを組み立てる
setup_repo() {
  repo="$sandbox/repo-$1"
  mkdir -p "$repo"
  git -c init.defaultBranch=main init -q "$repo"
  g commit -q --allow-empty -m c1
  g commit -q --allow-empty -m c2
  g commit -q --allow-empty -m c3
  g update-ref refs/remotes/origin/main "$(g rev-parse HEAD)"
}

echo "stale-branch-sweep (SessionStart):"

# --- 取り込み済み / 未マージ / 既定ブランチ ---
setup_repo basic
g branch merged-old HEAD~2          # 内容が origin/main に入っている
g branch merged-tip HEAD            # origin/main そのもの (境界値)
g branch unmerged HEAD              # このあと独自コミットを載せる
g update-ref refs/heads/unmerged "$(g commit-tree -p HEAD -m own "$(g rev-parse HEAD^{tree})")"
out=$(run_hook)
check "取り込み済みブランチを削除する" "main,unmerged" "$(branches)"
check "削除したら 1 行報告する" "1" "$(printf '%s' "$out" | grep -c '^\[repo-standards\]')"

# --- 掃除対象ゼロ ---
out=$(run_hook)
check "掃除対象ゼロなら無出力" "" "$out"
check "掃除対象ゼロでも exit 0" "0" "$?"

# --- worktree が掴んでいるブランチ ---
setup_repo worktree
g branch checked-out HEAD~1
g worktree add -q "$sandbox/wt" checked-out
run_hook >/dev/null
check "worktree が掴んでいるブランチは残す" "checked-out,main" "$(branches)"

# --- 逃げ道 ---
setup_repo optout
g branch merged-old HEAD~1
printf '{"cwd":"%s"}' "$repo" | RS_BRANCH_SWEEP=0 "$hook" >/dev/null 2>&1
check "RS_BRANCH_SWEEP=0 なら何もしない" "main,merged-old" "$(branches)"

# --- origin/main が無いリポ (未 push / remote 無し) ---
setup_repo no-origin
g update-ref -d refs/remotes/origin/main
g branch merged-old HEAD~1
run_hook >/dev/null
check "既定ブランチが解決できなければ何もしない" "main,merged-old" "$(branches)"

# --- 異常系 ---
printf '{"cwd":"%s/does-not-exist"}' "$sandbox" | "$hook" >/dev/null 2>&1
check "git リポでない cwd でも exit 0" "0" "$?"
printf 'not json' | "$hook" >/dev/null 2>&1
check "壊れた JSON でも exit 0" "0" "$?"
printf '{}' | "$hook" >/dev/null 2>&1
check "cwd 欠落でも exit 0" "0" "$?"

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK"
