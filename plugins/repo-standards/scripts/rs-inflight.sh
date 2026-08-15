#!/usr/bin/env bash
# いま走っている作業 (in-flight) を 1 コマンドで集める。next-task スキルが「他セッションと
# 重ならない次のタスク」を選ぶための材料で、判定そのものはしない (収集のみ)。要 jq。
#
# 監査系 rs-*.sh の JSON Lines 契約 (rs-lib.sh 冒頭) には乗らない — あれは「1 チェック =
# 1 行」で status を報告する形式で、これはチェックではないため。独自スキーマを使う:
#
#   {"kind":"_meta","repo","worktree","branch","sources":{"gh","sessions"},"label_exists"}
#   {"kind":"worktree","path","branch","self"}          … 同一リポの他 worktree
#   {"kind":"pr","number","title","branch","draft","files":[...]}  … open PR と触るファイル
#   {"kind":"issue","number","title","url"}             … 着手印の付いた Issue
#   {"kind":"session","project","branch","title","pr","age_sec","self"} … 稼働中セッション
#
# self は「このセッション自身の作業」の印 (現在の worktree / そのブランチと一致するもの)。
# 除外するかは呼び出し側の判断に委ねる — 中断した自分の作業へ戻る用途もあるため。
#
# 収集源の性質が違うので、欠けたときの扱いも変える:
#   - git worktree … 常に取れる (取れなければリポジトリ外なので即終了)
#   - gh           … 不在・未認証・GitHub 外リポなら sources.gh=false にして pr/issue を省く
#   - セッション   … ~/.claude/runcat-sessions/*.json は setup リポの runcat-metrics.py が
#                    書く私的フォーマットで、他マシン・将来の版で消えても不思議はない。
#                    best-effort とし、無ければ sources.sessions=false にして黙って省く
#
# レポートツールでありゲートではない。何が取れなくても exit 0 を保ち、スクリプト自体の
# 異常 (jq 不在・リポジトリ外) のみ非 0 で落ちる。
#
# テスト用の差し替え口:
#   RS_INFLIGHT_SESSIONS_DIR       セッション JSON の置き場 (既定 ~/.claude/runcat-sessions)
#   RS_INFLIGHT_SESSION_MAX_AGE    稼働中とみなす更新からの秒数 (既定 900)
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "NG: jq が無い (brew install jq)" >&2; exit 1; }

git rev-parse --git-dir >/dev/null 2>&1 || { echo "NG: git リポジトリの中で実行する" >&2; exit 1; }

sessions_dir="${RS_INFLIGHT_SESSIONS_DIR:-$HOME/.claude/runcat-sessions}"
max_age="${RS_INFLIGHT_SESSION_MAX_AGE:-900}"

self_root=$(git rev-parse --show-toplevel 2>/dev/null) || self_root=""
self_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || self_branch=""
[ "$self_branch" = "HEAD" ] && self_branch=""

# ---- gh が使えるか (不在・未認証・GitHub 外リポのいずれでも pr/issue は諦める) ----
repo=""
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || repo=""
fi
have_gh=false
[ -n "$repo" ] && have_gh=true

# ---- 着手印ラベルの実在 (空の結果が「未着手」か「ラベル未作成」か区別できないため) ----
label="status: in progress"
label_exists=false
if [ "$have_gh" = true ]; then
  found=$(gh label list --limit 200 --json name --jq ".[] | select(.name == \"$label\") | .name" 2>/dev/null) || found=""
  [ -n "$found" ] && label_exists=true
fi

have_sessions=false
[ -d "$sessions_dir" ] && have_sessions=true

jq -cn --arg repo "$repo" --arg wt "$self_root" --arg br "$self_branch" \
  --argjson gh "$have_gh" --argjson se "$have_sessions" --argjson le "$label_exists" \
  '{kind:"_meta",repo:$repo,worktree:$wt,branch:$br,
    sources:{gh:$gh,sessions:$se},label_exists:$le}'

# ---- 1. 同一リポの worktree ----
# --porcelain は worktree/HEAD/branch/detached を空行区切りで返す。detached でも path は
# 残るので、ブランチ名が無いまま 1 行として出す (そこで誰かが作業している事実は使える)
wt_path=""; wt_branch=""
emit_worktree() {
  [ -n "$wt_path" ] || return 0
  local is_self=false
  [ "$wt_path" = "$self_root" ] && is_self=true
  jq -cn --arg p "$wt_path" --arg b "$wt_branch" --argjson s "$is_self" \
    '{kind:"worktree",path:$p,branch:$b,self:$s}'
}
while IFS= read -r line; do
  case "$line" in
    "worktree "*) emit_worktree; wt_path="${line#worktree }"; wt_branch="" ;;
    "branch "*)   wt_branch="${line#branch refs/heads/}" ;;
  esac
done < <(git worktree list --porcelain 2>/dev/null)
emit_worktree

# ---- 2. open PR と、その PR が触っているファイル ----
if [ "$have_gh" = true ]; then
  gh pr list --state open --limit 50 --json number,title,headRefName,isDraft,files 2>/dev/null \
    | jq -c '.[] | {kind:"pr",number,title,branch:.headRefName,draft:.isDraft,
                    files:[.files[]?.path]}' 2>/dev/null || true
fi

# ---- 3. 着手印の付いた Issue ----
if [ "$have_gh" = true ] && [ "$label_exists" = true ]; then
  gh issue list --state open --limit 50 --label "$label" --json number,title,url 2>/dev/null \
    | jq -c '.[] | {kind:"issue",number,title,url}' 2>/dev/null || true
fi

# ---- 4. 稼働中の Claude セッション (best-effort) ----
# updated_at からの経過が max_age 以内のものだけ。壊れた JSON は 1 件ずつ捨てる
if [ "$have_sessions" = true ]; then
  for f in "$sessions_dir"/*.json; do
    [ -r "$f" ] || continue
    jq -c --argjson max "$max_age" --arg self "$self_branch" \
      'select(type == "object" and (.updated_at | type) == "number")
       | (now - .updated_at) as $age
       | select($age <= $max)
       | {kind:"session",project:(.project // ""),branch:(.branch // ""),
          title:(.title // ""),pr:.pr,age_sec:($age | floor),
          self:(($self != "") and (.branch == $self))}' "$f" 2>/dev/null || true
  done
fi

exit 0
