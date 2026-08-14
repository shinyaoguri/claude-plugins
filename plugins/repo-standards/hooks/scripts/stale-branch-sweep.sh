#!/usr/bin/env bash
# SessionStart hook — 役目を終えたローカルブランチのうち、消しても情報が 1 ビットも
# 失われないと**機械的に証明できる**ものだけを静かに掃除する (ADR 0018)。
#
# パス 1「既定ブランチ (origin/HEAD、無ければ origin/main) の祖先」
#   内容が完全に取り込み済みのもの。削除は `git branch -d` なので、取り込み済みで
#   なければ git 自身が拒否する (判定と削除で二重の安全策)。
#   なぜ必要か: グローバル設定の `git gone` (setup リポ tasks/git.yml) は
#   upstream:track == [gone] で役目終了を判定するため、**一度も push していない**
#   ブランチを永遠に拾えない。Claude Code の worktree 分離が作る worktree-agent-* や、
#   push せずに終わったセッションブランチがこれに当たる。実際に 1 リポで 77 本まで
#   積み上がり、うち 56 本がこの取りこぼしだった (経緯: claude-plugins#95)。
#
# パス 2「upstream:track == [gone] かつ、マージ済み PR の head と tip が一致」
#   個人標準は squash merge を required にしており、squash されたコミットは既定
#   ブランチの祖先にならない。つまりパス 1 は**マージ済みブランチを構造的に拾えず**、
#   本来そこを担う `git gone-clean` には自動実行の口が無かった (経緯: #99)。
#   ローカル tip が「マージ済み PR の headRefOid」と一致することを gh で確かめてから
#   だけ消す。一致 = ローカル参照が持つ情報はすべて GitHub 側にある (squash 後の内容は
#   既定ブランチに、元コミットは refs/pull/<N>/head に永続的に残る)。証明できない
#   もの (未 push のコミットが載っている / close された PR / gh が無い・失敗) には
#   触らないので、「削除系は提示に留める」という env-doctor の方針とも衝突しない。
#
# fetch はしない。どちらの判定も単調なので、remote-tracking が古くても誤爆せず
# 「拾い漏らす」側にしか倒れない。セッション開始を待たせないためでもある。
# パス 2 は候補があるときだけ gh を呼ぶ (掃除済みのリポではネットワークに触れない)。
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

# ---- パス 1: 既定ブランチに取り込み済み ----
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

# ---- パス 2: [gone] かつマージ済み PR の head と一致 ----
# 候補の抽出はタブ区切りで行う (worktreepath に空白が入りうるので最後に置く)。
gone_deleted=0
gone_over=0
gone_max=${RS_BRANCH_SWEEP_GONE_MAX:-10}
if [ "${RS_BRANCH_SWEEP_GONE:-1}" != "0" ]; then
  candidates=$(
    git for-each-ref --format='%(refname:short)	%(upstream:track)	%(objectname)	%(worktreepath)' refs/heads |
      awk -F'\t' -v base="${base#origin/}" '$2 == "[gone]" && $4 == "" && $1 != base { print $1 "\t" $3 }'
  )
  if [ -n "$candidates" ] && command -v gh >/dev/null 2>&1; then
    while IFS=$'\t' read -r branch tip; do
      [ -n "$branch" ] && [ -n "$tip" ] || continue
      # 待たせすぎないよう 1 セッションの照会数を打ち切る (残りは git gone で棚卸し)
      if [ "$gone_deleted" -ge "$gone_max" ]; then
        gone_over=$((gone_over + 1))
        continue
      fi
      json=$(gh pr list --head "$branch" --state merged --limit 5 --json headRefOid 2>/dev/null) || continue
      printf '%s' "$json" | jq -e --arg tip "$tip" 'map(.headRefOid) | index($tip)' >/dev/null 2>&1 || continue
      git branch -D "$branch" >/dev/null 2>&1 && gone_deleted=$((gone_deleted + 1))
    done <<EOF
$candidates
EOF
  fi
fi

report=""
[ "$deleted" -gt 0 ] && report="${base} に取り込み済み ${deleted} 本"
[ "$gone_deleted" -gt 0 ] && report="${report:+$report / }マージ済み PR と一致 ${gone_deleted} 本"
if [ -n "$report" ]; then
  echo "[repo-standards] 役目を終えたローカルブランチを削除しました (${report})。内容は ${base} と refs/pull/<N>/head に残っています。"
fi
if [ "$gone_over" -gt 0 ]; then
  echo "[repo-standards] upstream が [gone] のブランチが ${gone_over} 本残っています (1 セッション ${gone_max} 本まで照会)。git gone で一覧できます。"
fi
exit 0
