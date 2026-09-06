#!/usr/bin/env bash
# PermissionRequest(ExitPlanMode) hook — 合意済みの Issue に紐づくプランは、承認を待たずに通す。
#
# ADR 0017 は「確認疲れで**本当に見るべき 1 回まで反射で押す**ようになるのが最大の害」と
# 書き、確認をプラン承認 1 点へ集約した。集約は正しかったが、**集約した先の 1 回も反射に
# なっている** — 直近 3 日の transcript で ExitPlanMode は 201 回 (承認 188 / 却下 13)、
# **却下に人が言葉を添えたものは 0 件**だった (shinyaoguri/claude-plugins#153)。
#
# 止めたかったのは「合意なしに実装が広がること」で、それを止めているのは plan-gate.sh が
# 強制する**プランの存在**のほうである。承認プロンプトは 201 回に対して 0 件の情報しか
# 足していない。しかも、このセットアップではプランが出る時点で同じ問いに既に答えが出て
# いる — トリアージ印は「完了条件が固まっている」ことの印で、それを付けたのは人間である。
# **トリアージが実質のプラン承認になっており、同じ人に同じ判断を 2 回押させている。**
#
# だから消すのは**待つこと**だけで、**書くことと残すことは 1 文字も減らさない**。
# plan-gate.sh はそのまま、プランの GitHub への記録 (PostToolUse) もそのままである。
#
# ## 判定
#
#   プラン本文から**このリポジトリの** Issue 番号が 1 つに確定でき、
#   その Issue が open かつトリアージ印を持つ      → allow (プロンプトを出さない)
#   それ以外                                        → 素通し (いままでどおり人へ)
#
# **deny は返さない。** 消したかった OK ボタンを別の形で作らないため (ADR 0017 が
# plan-gate を ask にしなかったのと対の理由)。判定できないものはすべて素通しで、
# 失うのは待たずに済んだはずの時間だけである。
#
# ## 「このリポジトリの」を落とさない
#
# 番号だけを拾うと、`setup#148` や `owner/repo#148` と書いたプランが**このリポの #148**
# として通る。実際にその形の誤射が起きている (mokume-metal/mokume#991: 記録の置き場は cwd
# から・投稿先は literal から取っていたため、他リポのプランに mokume の番号が付いた)。
# だからここは **`#` の直前が名前の一部でないときだけ**裸の番号として数え、修飾された形は
# このリポの綴りに一致するものだけを足す。
#
# ## プラン本文の在処
#
# この版の ExitPlanMode は本文を引数で渡さず**プランファイルへ書かせる**ので、tool_input
# からは読めない。transcript を後ろから見て、プラン置き場へ書いた直近の Write/Edit を探す
# (payload に .tool_input.plan があればそちらを優先する)。
#
# 契約: stdin に PermissionRequest の JSON。素通しは無出力 + 終了コード 0。
# 呼び出し口は hooks/hooks.json、テストは scripts/test-rs-plan-pass.sh。
set -uo pipefail

# 一時的に止めたいときの逃げ道 (このフックは全リポで動くため。RS_PLAN_GATE と対称)
[ "${RS_PLAN_PASS:-1}" = "0" ] && exit 0

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
[ -n "$cwd" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0

# --- このリポジトリの綴り -----------------------------------------------------
# gh に聞かず remote から取る (フックは 1 回の判定に何秒もかけられない)。解けなければ
# 素通し — 「このリポの番号か」を確かめられないまま通さない
remote=$(git config --get remote.origin.url 2>/dev/null) || exit 0
slug=$(printf '%s' "$remote" |
  sed -E -e 's#^git@[^:]+:##' -e 's#^ssh://git@[^/]+/##' -e 's#^https?://[^/]+/##' -e 's#\.git$##')
printf '%s' "$slug" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' || exit 0
owner_repo="$slug"
repo_name="${slug#*/}"

# --- プラン本文 ---------------------------------------------------------------
plan=$(printf '%s' "$input" | jq -r '.tool_input.plan? // .tool_input.content? // ""')

if [ -z "$plan" ]; then
  transcript=$(printf '%s' "$input" | jq -r '.transcript_path // ""')
  [ -n "$transcript" ] && [ -f "$transcript" ] || exit 0
  # 末尾だけ見る。プランを書いたのは直前なので、全体を舐める必要が無い
  # -R で 1 行ずつ生の文字列として読む。transcript には壊れた行が混ざるので、
  # jq に JSON として食わせると 1 行で全体が落ちる (fromjson? が拾えるのは文字列だけ)
  plan_file=$(tail -n 2000 "$transcript" 2>/dev/null |
    jq -R -r 'fromjson? // empty | .message?.content? // empty | select(type == "array") | .[]
           | select(.type? == "tool_use")
           | select(.name? == "Write" or .name? == "Edit")
           | .input?.file_path // empty' 2>/dev/null |
    grep '/plans/' | tail -1)
  [ -n "$plan_file" ] && [ -f "$plan_file" ] || exit 0
  plan=$(cat "$plan_file" 2>/dev/null) || exit 0
fi
[ -n "$plan" ] || exit 0

# --- 対象 Issue の番号 ---------------------------------------------------------
# 裸の #N は、直前が名前の一部でないときだけ数える (setup#148 / owner/repo#148 をこのリポの
# #148 と読まないため)。修飾された形はこのリポの綴りに一致するものだけ足す。
numbers_in() { # stdin=テキスト → 番号を 1 行 1 件
  local text
  text=$(cat)
  {
    printf '%s' "$text" | grep -oE '(^|[[:space:]([{<"'"'"'])#[0-9]+' | grep -oE '[0-9]+'
    printf '%s' "$text" | grep -oE "(^|[^A-Za-z0-9._/-])($owner_repo|$repo_name)#[0-9]+" |
      grep -oE '[0-9]+$'
    printf '%s' "$text" | grep -oE "github\.com/$owner_repo/(issues|pull)/[0-9]+" | grep -oE '[0-9]+$'
  } 2>/dev/null | sort -u
}

# 確信の高い順に 3 段。**先に当たった段で確定させる** — 本文には関連 Issue の番号がいくつも
# 現れるので、全体から拾うのは最後の手段にする
headings=$(printf '%s\n' "$plan" | grep -E '^#{1,6}[[:space:]]' | numbers_in)
declared=$(printf '%s\n' "$plan" | grep -E '^[[:space:]]*(対象 Issue|Closes|Fixes|Resolves)' | numbers_in)
everything=$(printf '%s\n' "$plan" | numbers_in)

for tier in "$headings" "$declared" "$everything"; do
  [ -n "$tier" ] || continue
  # 1 つに確定しない段に当たったら、そこで諦める (確信が下がる方向へは進まない)
  [ "$(printf '%s\n' "$tier" | wc -l | tr -d ' ')" = "1" ] || exit 0
  issue="$tier"
  break
done
[ -n "${issue:-}" ] || exit 0

# --- トリアージ印 --------------------------------------------------------------
# 綴りはリポジトリごとに違う。既定は mokume の綴りだが、**持たないリポでは単に一致しない**
# ので設定は要らない (そういうリポでは今までどおり人へ返る)
label=${RS_PLAN_PASS_LABEL:-verify: triaged}

view=$(gh issue view "$issue" --repo "$owner_repo" --json state,labels 2>/dev/null) || exit 0
[ -n "$view" ] || exit 0
[ "$(printf '%s' "$view" | jq -r '.state // ""')" = "OPEN" ] || exit 0
printf '%s' "$view" | jq -e --arg l "$label" 'any(.labels[]?.name; . == $l)' >/dev/null 2>&1 || exit 0

jq -n --arg r "$owner_repo#$issue はトリアージ済み ($label) なので、プランの承認を待たずに通した。完了条件は既に人が固めており、着手時の突き合わせも済んでいる。プランはいままでどおり記録される。待たせたいときは RS_PLAN_PASS=0。" \
  '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "allow"}, decisionReason: $r}}'

exit 0
