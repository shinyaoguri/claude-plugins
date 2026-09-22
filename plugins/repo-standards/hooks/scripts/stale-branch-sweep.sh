#!/usr/bin/env bash
# SessionStart hook — 役目を終えたローカルブランチのうち、消しても情報が 1 ビットも
# 失われないと**機械的に証明できる**ものだけを静かに掃除する (ADR 0018)。
#
# 対象は「既定ブランチ (origin/HEAD、無ければ origin/main) の祖先」= 内容が完全に取り込み済みの
# もの。削除は `git branch -d` なので、取り込み済みでなければ git 自身が拒否する (判定と削除で
# 二重の安全策)。
#   なぜ必要か: グローバル設定の `git gone` (setup リポ tasks/git.yml) は
#   upstream:track == [gone] で役目終了を判定するため、**一度も push していない**
#   ブランチを永遠に拾えない。Claude Code の worktree 分離が作る worktree-agent-* や、
#   push せずに終わったセッションブランチがこれに当たる。実際に 1 リポで 77 本まで
#   積み上がり、うち 56 本がこの取りこぼしだった (経緯: claude-plugins#95)。
#
# squash merge 済みのブランチ (既定ブランチの祖先にならず、upstream が [gone] になるもの) は
# ここでは扱わない。setup の Stop hook が `git gone-clean` で消す。以前は「マージ済み PR の head と
# 一致することを gh で確かめてから消す」パスを持っていたが、gone-clean に自動実行の口ができてからは
# 候補が残らなくなったので撤去した (ADR 0030)。この hook は gh もネットワークも使わない。
#
# fetch はしない。判定は単調なので、remote-tracking が古くても誤爆せず「拾い漏らす」側にしか
# 倒れない。セッション開始を待たせないためでもある。
#
# stdin: SessionStart の JSON (.cwd)
set -uo pipefail

# 一時的に止めたいときの逃げ道 (このフックは全リポで動くため)
[ "${RS_BRANCH_SWEEP:-1}" = "0" ] && exit 0

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)
[ -n "$cwd" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0

git rev-parse --git-dir >/dev/null 2>&1 || exit 0

base=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
git rev-parse -q --verify "$base" >/dev/null 2>&1 || exit 0

# ---- 既定ブランチに取り込み済みのものを消す ----
# %(worktreepath) が非空 = どこかの worktree が掴んでいる (現在のブランチを含む) ので
# 候補から外す。既定ブランチ自身は名前で外す (自分の祖先なので必ず引っかかるため)。
deleted=0
while read -r branch; do
  [ -n "$branch" ] || continue
  git branch -d "$branch" >/dev/null 2>&1 && deleted=$((deleted + 1))
done < <(
  git for-each-ref --format='%(refname:short) %(worktreepath)' refs/heads |
    awk 'NF==1 {print $1}' |
    grep -vxF "${base#origin/}" |
    while read -r b; do
      git merge-base --is-ancestor "$b" "$base" 2>/dev/null && echo "$b"
    done
)

if [ "$deleted" -gt 0 ]; then
  echo "[repo-standards] 役目を終えたローカルブランチを削除しました (${base} に取り込み済み ${deleted} 本)。内容は ${base} に残っています。"
fi
exit 0
