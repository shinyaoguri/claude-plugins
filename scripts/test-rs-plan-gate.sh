#!/usr/bin/env bash
# plan-gate.sh / plan-gate-mark.sh の分岐テスト。
# 使い捨ての git リポを組み、hook の契約 (終了コードと stdout の permissionDecision) を
# そのまま検証する (Claude セッションにも GitHub にも触らない)。
#
#   bash scripts/test-rs-plan-gate.sh
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
hooks="$repo_root/plugins/repo-standards/hooks/scripts"
gate_hook="$hooks/plan-gate.sh"
mark_hook="$hooks/plan-gate-mark.sh"

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
mkdir -p "$repo/src" "$repo/docs" "$sandbox/outside"
git -c init.defaultBranch=main init -q "$repo"
git -C "$repo" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init

gate_dir="$repo/.git/claude-plan-gate"

reset() { rm -rf "$gate_dir"; }

# stdin の PreToolUse JSON を組んで hook を叩く。$2 で permission_mode、$3 で
# tool_input のキー名 (NotebookEdit は notebook_path) を差し替える
run_gate() {
  printf '{"session_id":"sess1","cwd":"%s","permission_mode":"%s","tool_input":{"%s":"%s"}}' \
    "$repo" "${2:-default}" "${3:-file_path}" "$1" | bash "$gate_hook" 2>"$sandbox/err"
}

# 素通し (無出力) なら pass、判定を返したらその permissionDecision
decision() {
  local out
  out=$(run_gate "$@")
  if [ -z "$out" ]; then echo pass; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'; fi
}

reason() { run_gate "$@" | jq -r '.hookSpecificOutput.permissionDecisionReason'; }

echo "plan-gate.sh (PreToolUse: 合意なしに実装が広がるのを止める):"

reset
check "1 ファイル目は素通し (小さい修正でプランを書かせない)" pass "$(decision src/a.txt)"
check "2 ファイル目も素通し (閾値未満)" pass "$(decision src/b.txt)"
check "3 ファイル目で止める (既定の閾値)" deny "$(decision src/c.txt)"
check "  止めたあとも止め続ける" deny "$(decision src/d.txt)"

reset
decision src/a.txt >/dev/null
decision src/a.txt >/dev/null
decision src/a.txt >/dev/null
check "同じファイルの反復は 1 件として数える" pass "$(decision src/a.txt)"

reset
decision src/a.txt >/dev/null
decision src/b.txt >/dev/null
check "触ったファイルを差し戻し文面に並べる" 0 \
  "$(reason src/c.txt | grep -q 'src/b.txt'; echo $?)"
check "  次に何をすべきかを伝える" 0 \
  "$(reason src/c.txt | grep -q 'EnterPlanMode'; echo $?)"

# 承認済みプランがあれば以降このセッションでは何も言わない
reset
mkdir -p "$gate_dir"
: > "$gate_dir/sess1.approved"
check "承認済みプランの印があれば素通し" pass "$(decision src/a.txt)"
check "  何ファイル触っても素通し" pass "$(decision src/b.txt)"
check "  さらに触っても素通し" pass "$(decision src/c.txt)"

reset
check "plan モード中は素通し (プラン機構が抑えている)" pass "$(decision src/a.txt plan)"
check "  plan モードの編集は数にも入れない" pass "$(decision src/b.txt plan)"
check "  数えていないので既定モードでもまだ 1 件目" pass "$(decision src/c.txt)"

# 数えるのは作業ツリー内の実ファイルだけ。除外リストを持たない設計の確認 (境界値)
reset
decision "$repo/.git/config" >/dev/null
decision "$sandbox/outside/x.md" >/dev/null
decision "$HOME/.claude/plans/dummy-plan.md" >/dev/null
check ".git 配下・リポ外・プランファイルは数えない" pass "$(decision src/a.txt)"

reset
check "NotebookEdit の notebook_path も拾う" pass "$(decision src/n.ipynb default notebook_path)"
decision src/b.txt >/dev/null
check "  同じ台帳で数える" deny "$(decision src/c.txt)"

reset
check "閾値は RS_PLAN_GATE_THRESHOLD で変えられる" deny \
  "$(RS_PLAN_GATE_THRESHOLD=1 decision src/a.txt)"

reset
decision src/a.txt >/dev/null
decision src/b.txt >/dev/null
check "RS_PLAN_GATE=0 なら黙る (逃げ道)" pass "$(RS_PLAN_GATE=0 decision src/c.txt)"

# git 管理外のディレクトリから呼ばれても落ちない (全プロジェクトで動くため。境界値)
printf '{"session_id":"sess1","cwd":"%s","permission_mode":"default","tool_input":{"file_path":"x.md"}}' \
  "$sandbox/outside" | bash "$gate_hook" >/dev/null 2>&1
check "git リポでなくても落ちない" 0 $?

echo
echo "plan-gate-mark.sh (PostToolUse: プラン承認で印を置く):"

reset
printf '{"session_id":"sess1","cwd":"%s"}' "$repo" | bash "$mark_hook" >/dev/null 2>&1
check "ExitPlanMode が通ったら印を置く" present \
  "$([ -f "$gate_dir/sess1.approved" ] && echo present || echo absent)"

reset
printf '{"session_id":"sess1","cwd":"%s"}' "$repo" | RS_PLAN_GATE=0 bash "$mark_hook" >/dev/null 2>&1
check "RS_PLAN_GATE=0 なら印を置かない" absent \
  "$([ -f "$gate_dir/sess1.approved" ] && echo present || echo absent)"

reset
printf '{"session_id":"sess2","cwd":"%s"}' "$repo" | bash "$mark_hook" >/dev/null 2>&1
decision src/a.txt >/dev/null
decision src/b.txt >/dev/null
check "印はセッション単位 (並行セッションに漏れない)" deny "$(decision src/c.txt)"

printf '{"session_id":"sess1","cwd":"%s"}' "$sandbox/outside" | bash "$mark_hook" >/dev/null 2>&1
check "git リポでなくても落ちない" 0 $?

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK"
