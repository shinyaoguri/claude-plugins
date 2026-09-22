#!/usr/bin/env bash
# stale-branch-sweep.sh (SessionStart hook) の判定テスト。
# 使い捨ての git リポで hook を直接叩く (ネットワークにも実マシンの git 設定にも触らない)。
# origin/main は refs/remotes/origin/main を直接張って再現し、[gone] は
# branch.<name>.remote / .merge を張ったまま remote-tracking を消して再現する。
# gh は「呼ばれたら記録する」スタブへ差し替え、この hook が GitHub に問い合わせないことも検証する。
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

# --- gh スタブ ---------------------------------------------------------------
# この hook は gh を呼ばない。呼んだら記録に残るスタブを PATH に置き、呼ばないことを検証する
mkdir -p "$sandbox/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$GH_STUB_LOG"\necho "[]"\n' > "$sandbox/bin/gh"
chmod +x "$sandbox/bin/gh"
export GH_STUB_LOG="$sandbox/gh.log"
: > "$GH_STUB_LOG"
export PATH="$sandbox/bin:$PATH"

# 3 コミットの main と、それを指す origin/main を持つリポを組み立てる。
# origin は [gone] 判定に remote 設定が要るので張るが、fetch も push もしない
setup_repo() {
  repo="$sandbox/repo-$1"
  mkdir -p "$repo"
  git -c init.defaultBranch=main init -q "$repo"
  g commit -q --allow-empty -m c1
  g commit -q --allow-empty -m c2
  g commit -q --allow-empty -m c3
  g update-ref refs/remotes/origin/main "$(g rev-parse HEAD)"
  g remote add origin "$sandbox/fake.git"
  g config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  : > "$GH_STUB_LOG"
}

# gone_branch <ブランチ> — upstream:track が [gone] のブランチを作る。
# 追跡先を設定したまま remote-tracking が無い状態 = push したブランチが remote で
# 消され fetch --prune 済み、を再現する。コミットは main と別物にする (squash merge
# 後と同じで、内容は main にあるがコミットは祖先にならない = パス 1 では拾えない)
gone_branch() {
  g update-ref "refs/heads/$1" "$(g commit-tree -p HEAD -m "own-$1" "$(g rev-parse 'HEAD^{tree}')")"
  g config "branch.$1.remote" origin
  g config "branch.$1.merge" "refs/heads/$1"
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

# --- [gone] のブランチには触らない ---
# squash merge 済みのブランチは既定ブランチの祖先にならないので、この hook では証明できない。
# そこは setup の Stop hook (git gone-clean) の担当で、この hook は gh も呼ばない (ADR 0030)
setup_repo gone
gone_branch merged-pr
out=$(run_hook)
check "[gone] のブランチは残す" "main,merged-pr" "$(branches)"
check "[gone] があっても gh を呼ばない" "0" "$(wc -l < "$GH_STUB_LOG" | tr -d ' ')"
check "[gone] があっても無出力" "" "$out"

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
