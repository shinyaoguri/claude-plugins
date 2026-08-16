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
other="$sandbox/other"
mkdir -p "$repo/src" "$repo/docs" "$sandbox/outside"
for r in "$repo" "$other"; do
  git -c init.defaultBranch=main init -q "$r"
  git -C "$r" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
done

# 同じリポの linked worktree (親リポと印の置き場が一致するかの検証用)
wt="$sandbox/wt"
git -C "$repo" worktree add -q "$wt" -b wt >/dev/null 2>&1
mkdir -p "$wt/src"

# 台帳はリポジトリ単位 (.git 配下)、承認印はセッション単位 (cwd 非依存の置き場)
gate_dir="$repo/.git/claude-plan-gate"
approved_dir="$sandbox/plan-gate"
export RS_PLAN_GATE_DIR="$approved_dir"

reset() { rm -rf "$gate_dir" "$approved_dir"; }

# stdin の PreToolUse JSON を組んで hook を叩く。$2 で permission_mode、$3 で
# tool_input のキー名 (NotebookEdit は notebook_path) を差し替える。
# cwd は既定で $repo、decision_in で差し替える (bash の動的スコープを使う)
run_gate() {
  printf '{"session_id":"sess1","cwd":"%s","permission_mode":"%s","tool_input":{"%s":"%s"}}' \
    "${gate_cwd:-$repo}" "${2:-default}" "${3:-file_path}" "$1" | bash "$gate_hook" 2>"$sandbox/err"
}

# 素通し (無出力) なら pass、判定を返したらその permissionDecision
decision() {
  local out
  out=$(run_gate "$@")
  if [ -z "$out" ]; then echo pass; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'; fi
}

# decision_in <cwd> <ファイル> — 別ディレクトリから呼ばれたことにする
decision_in() {
  local gate_cwd="$1"
  shift
  decision "$@"
}

reason() { run_gate "$@" | jq -r '.hookSpecificOutput.permissionDecisionReason'; }

# mark <cwd> [session] — ExitPlanMode が通ったときの PostToolUse を再現する
mark() {
  printf '{"session_id":"%s","cwd":"%s"}' "${2:-sess1}" "$1" | bash "$mark_hook" >/dev/null 2>&1
}

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
# 承認済みなのに差し戻されたとき、どこを見て無かったのかを掴めるようにする
check "  印の置き場を文面に出す (誤爆したときの手がかり)" 0 \
  "$(reason src/c.txt | grep -q "$approved_dir/sess1.approved"; echo $?)"

# 承認済みプランがあれば以降このセッションでは何も言わない
reset
mkdir -p "$approved_dir"
: > "$approved_dir/sess1.approved"
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

marker() { [ -f "$approved_dir/${1:-sess1}.approved" ] && echo present || echo absent; }

reset
mark "$repo"
check "ExitPlanMode が通ったら印を置く" present "$(marker)"

reset
printf '{"session_id":"sess1","cwd":"%s"}' "$repo" | RS_PLAN_GATE=0 bash "$mark_hook" >/dev/null 2>&1
check "RS_PLAN_GATE=0 なら印を置かない" absent "$(marker)"

reset
mark "$repo" sess2
decision src/a.txt >/dev/null
decision src/b.txt >/dev/null
check "印はセッション単位 (並行セッションに漏れない)" deny "$(decision src/c.txt)"

mark "$sandbox/outside"
check "git リポでなくても落ちない" 0 $?

echo
echo "印の置き場は cwd に依存しない (承認はセッションの事実であってリポの事実ではない):"

# 回帰: ExitPlanMode の瞬間だけ Bash の cwd が別リポへドリフトしていても印は効く。
# 以前は cwd から引いた git common-dir へ置いていたため、印が別リポの .git へ落ちて
# 承認済みのまま deny が返っていた
reset
mark "$other"
decision src/a.txt >/dev/null
decision src/b.txt >/dev/null
check "別リポの cwd で承認しても印が効く" pass "$(decision src/c.txt)"

reset
mark "$sandbox/outside"
check "git 管理外の cwd で承認しても印が効く" present "$(marker)"

reset
printf '{"session_id":"sess1"}' | bash "$mark_hook" >/dev/null 2>&1
check "cwd キーが無い JSON でも印を置ける (git を引かない)" present "$(marker)"

# worktree ⇄ 親リポ。どちらから承認しても、もう一方の編集が素通しになる
reset
decision_in "$wt" src/a.txt >/dev/null
decision_in "$wt" src/b.txt >/dev/null
check "(対照) 承認が無ければ worktree 側でも 3 ファイル目で止まる" deny "$(decision_in "$wt" src/c.txt)"

reset
mark "$repo"
decision_in "$wt" src/a.txt >/dev/null
decision_in "$wt" src/b.txt >/dev/null
check "親リポで承認 → worktree 側の編集が素通し" pass "$(decision_in "$wt" src/c.txt)"

reset
mark "$wt"
decision src/a.txt >/dev/null
decision src/b.txt >/dev/null
check "worktree で承認 → 親リポ側の編集が素通し" pass "$(decision src/c.txt)"

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK"
