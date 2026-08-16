#!/usr/bin/env bash
# SessionStart hook — 残骸 worktree のうち、**情報が 1 ビットも失われないもの (prune)** だけを
# 静かに畳み、**後続処理を能動的に壊すもの (既定ブランチを掴んだ linked worktree)** を知らせる。
# 削除は一切しない (ADR 0018 と同じ立場。何が失われるか証明できないものには触らない)。
#
# なぜ通知が要るか: linked worktree が `main` を掴んでいると、別の場所での
# `gh pr merge --squash --delete-branch` が**マージ後のローカル後処理で落ちる**:
#
#   failed to run git: fatal: 'main' is already used by worktree at '.../worktrees/xxx'
#
# マージ自体は成功しているぶん気付きにくく、既定ブランチへの切り戻しとローカルブランチ削除だけが
# 行われないまま残る。掴んでいる worktree は「マージ済みセッションの残骸」であることが多い
# (経緯: claude-plugins#114)。repo-audit の worktrees_clean も同じ状態を指摘するが、
# 監査を回すまで誰も見ないので、日常のセッションで気付ける口をここに置く。
#
# `git worktree prune` は実ディレクトリが消えた登録を畳むだけで、作業ツリーにもブランチにも
# 触らない。ブランチ側の掃除は stale-branch-sweep.sh が担う (こちらは worktree 専任)。
#
# stdin: SessionStart の JSON (.cwd)
set -uo pipefail

# 一時的に止めたいときの逃げ道 (このフックは全リポで動くため)
[ "${RS_WORKTREE_SWEEP:-1}" = "0" ] && exit 0

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)
[ -n "$cwd" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0

git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# ---- 1. 実ディレクトリが消えた登録を畳む ----
git worktree prune >/dev/null 2>&1

# ---- 2. 既定ブランチを掴んだ linked worktree を知らせる ----
# 既定ブランチの導出は stale-branch-sweep.sh と揃える (origin/HEAD、無ければ main)。
# origin が無いリポでも main を掴んだ残骸は後処理を壊すので、fetch もリモート照会もしない。
base=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
base=${base#origin/}

# --porcelain は worktree/HEAD/branch/detached を空行区切りで返す。1 本目がリポジトリ本体
# (メインチェックアウト) なので、そこが既定ブランチを掴んでいるのは正常な状態として外す。
holders=$(
  git worktree list --porcelain 2>/dev/null | awk -v base="refs/heads/$base" '
    /^worktree /{ p = substr($0, 10); b = "" }
    /^branch /  { b = substr($0, 8) }
    /^$/        { if (p != "") { if (++n > 1 && b == base) print p } ; p = "" }
    END         { if (p != "" && ++n > 1 && b == base) print p }
  '
)

[ -n "$holders" ] || exit 0

count=$(printf '%s\n' "$holders" | grep -c .)
echo "[repo-standards] linked worktree が既定ブランチ ($base) を掴んでいます (${count} 個)。このままだと別の場所での gh pr merge --delete-branch がマージ後のローカル後処理で失敗します。"
printf '%s\n' "$holders" | while IFS= read -r p; do
  [ -n "$p" ] || continue
  echo "[repo-standards]   $p — 未コミットの変更が無いことを確かめてから git worktree remove \"$p\" (残す場合はその worktree で別ブランチへ切り替える)"
done
exit 0
