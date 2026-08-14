#!/usr/bin/env bash
# stale-branch-sweep.sh (SessionStart hook) の判定テスト。
# 使い捨ての git リポで hook を直接叩く (ネットワークにも実マシンの git 設定にも触らない)。
# origin/main は refs/remotes/origin/main を直接張って再現し、[gone] は
# branch.<name>.remote / .merge を張ったまま remote-tracking を消して再現する。
# gh はスタブへ差し替えるので GitHub には一切問い合わせない。
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
# 呼ばれた引数を $GH_STUB_LOG に記録し、--head <branch> に対応する応答ファイルが
# あればその中身を、無ければ空配列 (= マージ済み PR 無し) を返す。
# GH_STUB_FAIL=1 で「gh が失敗した」を再現する。
mkdir -p "$sandbox/bin" "$sandbox/pr"
cat > "$sandbox/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_STUB_LOG"
[ "${GH_STUB_FAIL:-0}" = "1" ] && exit 1
head=""; prev=""
for a in "$@"; do [ "$prev" = "--head" ] && head="$a"; prev="$a"; done
if [ -f "$GH_STUB_DIR/$head" ]; then cat "$GH_STUB_DIR/$head"; else echo '[]'; fi
STUB
chmod +x "$sandbox/bin/gh"
export GH_STUB_DIR="$sandbox/pr"
export GH_STUB_LOG="$sandbox/gh.log"
: > "$GH_STUB_LOG"
export PATH="$sandbox/bin:$PATH"

# gh がインストールされていない環境を再現する PATH (必要なコマンドだけを張る)
mkdir -p "$sandbox/nogh"
for c in git jq awk grep cat; do ln -sf "$(command -v "$c")" "$sandbox/nogh/$c"; done

# merged_pr <ブランチ> <headRefOid> — そのブランチを head とするマージ済み PR を宣言する
merged_pr() { printf '[{"headRefOid":"%s"}]\n' "$2" > "$sandbox/pr/$1"; }

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
  rm -f "$sandbox/pr"/*
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

# --- [gone] × マージ済み PR (パス 2) ---
setup_repo gone
gone_branch merged-pr        # tip が PR の head と一致する = 消してよい
gone_branch ahead-of-pr      # PR はマージ済みだが tip が先に進んでいる
gone_branch closed-pr        # マージされずに閉じた PR (応答は空配列)
merged_pr merged-pr "$(g rev-parse merged-pr)"
merged_pr ahead-of-pr "$(g rev-parse HEAD)"
out=$(run_hook)
check "マージ済み PR と tip が一致する [gone] を削除する" "ahead-of-pr,closed-pr,main" "$(branches)"
check "削除したら 1 行報告する ([gone] 側)" "1" "$(printf '%s' "$out" | grep -c 'マージ済み PR と一致 1 本')"
check "候補ごとに gh へ 1 回ずつ照会する" "3" "$(grep -c -- '--head' "$GH_STUB_LOG")"

# --- 候補ゼロなら gh を呼ばない ---
setup_repo no-candidate
g branch merged-old HEAD~1
run_hook >/dev/null
check "[gone] が無ければ gh を呼ばない" "0" "$(wc -l < "$GH_STUB_LOG" | tr -d ' ')"

# --- gh が失敗する / gh が無い ---
setup_repo gh-fail
gone_branch merged-pr
merged_pr merged-pr "$(g rev-parse merged-pr)"
printf '{"cwd":"%s"}' "$repo" | GH_STUB_FAIL=1 "$hook" >/dev/null 2>&1
check "gh が失敗したら残す" "main,merged-pr" "$(branches)"
check "gh が失敗しても exit 0" "0" "$?"

setup_repo gh-absent
gone_branch merged-pr
merged_pr merged-pr "$(g rev-parse merged-pr)"
printf '{"cwd":"%s"}' "$repo" | PATH="$sandbox/nogh" "$hook" >/dev/null 2>&1
check "gh が無ければ残す" "main,merged-pr" "$(branches)"
check "gh が無くても exit 0" "0" "$?"

# --- worktree が掴んでいる [gone] ---
setup_repo gone-worktree
gone_branch checked-out
merged_pr checked-out "$(g rev-parse checked-out)"
g worktree add -q "$sandbox/wt-gone" checked-out
run_hook >/dev/null
check "worktree が掴んでいる [gone] は残す" "checked-out,main" "$(branches)"
# 削除は git 自身も拒むので、候補から外れていること (= gh を引く前に落ちること) まで見る
check "worktree が掴んでいる [gone] は gh へ照会しない" "0" "$(wc -l < "$GH_STUB_LOG" | tr -d ' ')"

# --- 逃げ道 ([gone] 側だけ止める) ---
setup_repo gone-optout
gone_branch merged-pr
merged_pr merged-pr "$(g rev-parse merged-pr)"
printf '{"cwd":"%s"}' "$repo" | RS_BRANCH_SWEEP_GONE=0 "$hook" >/dev/null 2>&1
check "RS_BRANCH_SWEEP_GONE=0 なら [gone] に触らない" "main,merged-pr" "$(branches)"
check "RS_BRANCH_SWEEP_GONE=0 でも gh を呼ばない" "0" "$(wc -l < "$GH_STUB_LOG" | tr -d ' ')"

# --- 1 セッションの照会上限 ---
setup_repo gone-cap
gone_branch pr-a
gone_branch pr-b
merged_pr pr-a "$(g rev-parse pr-a)"
merged_pr pr-b "$(g rev-parse pr-b)"
out=$(printf '{"cwd":"%s"}' "$repo" | RS_BRANCH_SWEEP_GONE_MAX=1 "$hook" 2>/dev/null)
check "上限まで削除したら打ち切る" "main,pr-b" "$(branches)"
check "残りを報告する" "1" "$(printf '%s' "$out" | grep -c '1 本残っています')"

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
