#!/usr/bin/env bash
# plan-pass.sh の分岐テスト。
# 使い捨ての git リポと gh スタブを組み、hook の契約 (終了コードと stdout の decision) を
# そのまま検証する (Claude セッションにも GitHub にも触らない)。
#
#   bash scripts/test-rs-plan-pass.sh
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
hook="$repo_root/plugins/repo-standards/hooks/scripts/plan-pass.sh"

failures=0

# check <ケース名> <期待> <実際>
check() {
  if [ "$2" = "$3" ]; then
    echo "  [ok]   $1 → $3"
  else
    echo "  [FAIL] $1 → 期待 $2 / 実際 $3"
    [ -s "$sandbox/err" ] && sed 's/^/         | /' "$sandbox/err"
    failures=$((failures + 1))
  fi
}

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
: > "$sandbox/empty-gitconfig"
export GIT_CONFIG_GLOBAL="$sandbox/empty-gitconfig"

repo="$sandbox/repo"
git -c init.defaultBranch=main init -q "$repo"
git -C "$repo" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$repo" remote add origin https://github.com/acme/widget.git

# --- gh スタブ ---------------------------------------------------------------
# 番号ごとに state と labels を返す。実物には触らない
mkdir -p "$sandbox/bin"
cat > "$sandbox/bin/gh" <<'STUB'
#!/usr/bin/env bash
# gh issue view <番号> --repo <slug> --json state,labels
for arg in "$@"; do
  case "$arg" in [0-9]*) number="$arg"; break ;; esac
done
case "${number:-}" in
  7|11)  printf '{"state":"OPEN","labels":[{"name":"verify: triaged"}]}' ;;
  8)     printf '{"state":"OPEN","labels":[{"name":"bug"}]}' ;;          # 印が無い
  9)     printf '{"state":"CLOSED","labels":[{"name":"verify: triaged"}]}' ;;
  *)     exit 1 ;;                                                        # 引けない
esac
STUB
chmod +x "$sandbox/bin/gh"
export PATH="$sandbox/bin:$PATH"

plans="$sandbox/plans"
mkdir -p "$plans"

# run <プラン本文> — transcript 経由でプランを渡して hook を叩く
run() {
  local plan_file="$plans/plan.md" transcript="$sandbox/transcript.jsonl"
  printf '%s\n' "$1" > "$plan_file"
  # プラン置き場へ書いた直近の Write を持つ transcript を組む (壊れた行も混ぜる —
  # 実物の transcript には常に混ざるので、そこで落ちないことまで見る)
  {
    printf 'これは JSON ではない行\n'
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' "$plan_file"
  } > "$transcript"
  printf '{"session_id":"s1","cwd":"%s","transcript_path":"%s","hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode","tool_input":{}}' \
    "${run_cwd:-$repo}" "$transcript" | bash "$hook" 2>"$sandbox/err"
}

# run_inline <プラン本文> — payload に本文が載る版 (transcript を見ない経路)
run_inline() {
  printf '{"session_id":"s1","cwd":"%s","hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode","tool_input":{"plan":%s}}' \
    "$repo" "$(printf '%s' "$1" | jq -Rs .)" | bash "$hook" 2>"$sandbox/err"
}

# 素通し (無出力) なら pass、判定を返したらその behavior
decision() {
  local out
  out=$(run "$@")
  if [ -z "$out" ]; then echo pass; else printf '%s' "$out" | jq -r '.hookSpecificOutput.decision.behavior'; fi
}

decision_inline() {
  local out
  out=$(run_inline "$@")
  if [ -z "$out" ]; then echo pass; else printf '%s' "$out" | jq -r '.hookSpecificOutput.decision.behavior'; fi
}

echo "== 通す =="

check "見出しの番号 + トリアージ印 + open" allow \
  "$(decision '# #7 — つまみの色を直す

## 変更点
- Sources/Knob.swift')"

check "対象 Issue: 行で名乗った番号" allow \
  "$(decision '# つまみの色を直す

対象 Issue: #7

## 変更点
- Sources/Knob.swift')"

check "自リポの綴りで修飾された番号 (widget#7)" allow \
  "$(decision '# widget#7 — つまみの色を直す')"

check "自リポの URL で名乗った番号" allow \
  "$(decision '# つまみの色を直す

対象 Issue: https://github.com/acme/widget/issues/7')"

check "payload に本文が載る経路 (transcript を見ない)" allow \
  "$(decision_inline '# #7 — つまみの色を直す')"

check "本文に関連番号が並んでいても、見出しで確定する" allow \
  "$(decision '# #7 — つまみの色を直す

関連: #101 と #202 も同じ形をしている。#303 は別件。')"

echo
echo "== 通さない (素通しで人へ返す) =="

check "トリアージ印が無い" pass "$(decision '# #8 — 印の無い Issue')"
check "closed な Issue" pass "$(decision '# #9 — 閉じた Issue')"
check "gh が引けない番号" pass "$(decision '# #404 — 存在しない Issue')"
check "番号がどこにも無い" pass "$(decision '# つまみの色を直す

## 変更点
- Sources/Knob.swift')"

check "見出しに番号が 2 つあって確定しない" pass \
  "$(decision '# #7 と #11 をまとめて直す')"

check "他リポの修飾つき番号だけ (owner/repo#7 を自リポの #7 と読まない)" pass \
  "$(decision '# other/thing#7 — 別のリポジトリの話')"

check "他リポの短い修飾 (setup#7) も自リポの #7 と読まない" pass \
  "$(decision '# setup#7 — 別のリポジトリの話')"

check "他リポの URL は候補にしない" pass \
  "$(decision '# つまみの色を直す

参考: https://github.com/other/thing/issues/7')"

check "RS_PLAN_PASS=0 で全部人へ返す" pass \
  "$(RS_PLAN_PASS=0 decision '# #7 — つまみの色を直す')"

check "git リポの外" pass "$(run_cwd="$sandbox" decision '# #7 — つまみの色を直す')"

norem="$sandbox/norem"
git -c init.defaultBranch=main init -q "$norem"
check "origin を持たないリポ" pass "$(run_cwd="$norem" decision '# #7 — つまみの色を直す')"

check "プランファイルが見つからない" pass \
  "$(printf '{"session_id":"s1","cwd":"%s","transcript_path":"%s","tool_input":{}}' "$repo" "$sandbox/nope.jsonl" |
     bash "$hook" 2>"$sandbox/err" | { read -r out || true; [ -z "${out:-}" ] && echo pass || echo "$out"; })"

echo
echo "== deny は決して返さない =="
# 消したかった OK ボタンを別の形で作らないための不変条件 (ADR 0017)
denies=0
for plan in '# #7 x' '# #8 x' '# #9 x' '# #404 x' '# other/thing#7 x' '# 番号なし'; do
  out=$(run "$plan")
  [ -z "$out" ] && continue
  [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.decision.behavior')" = "deny" ] && denies=$((denies + 1))
done
check "deny の回数" 0 "$denies"

echo
echo "== 返す JSON の形 =="
out=$(run '# #7 — つまみの色を直す')
check "hookEventName" PermissionRequest "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')"
check "decisionReason に理由がある" yes \
  "$(printf '%s' "$out" | jq -r 'if (.hookSpecificOutput.decisionReason // "") | length > 0 then "yes" else "no" end')"
check "終了コード" 0 "$(run '# #7 x' >/dev/null 2>&1; echo $?)"

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "すべて通った"
