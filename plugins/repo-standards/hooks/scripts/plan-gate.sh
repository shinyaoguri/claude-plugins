#!/usr/bin/env bash
# PreToolUse(Edit|Write|NotebookEdit) hook — 合意の無いまま実装が広がるのを止める。
#
# 個人の規約は「複数ステップの作業は着手時に計画を宣言する」だが、文書ルールは advisory
# なので実際には取りこぼす (方向性を確かめないまま実装が進み、まるごと手戻りになる)。
# 一方で、実行の一つひとつに承認を挟むのは OK ボタンを増やすだけで安全性を上げない。
# そこで**人間の確認をプラン承認 1 点に集約する**: 小さい修正は素通しし、合意なしに
# 編集が閾値のファイル数へ広がった時点で deny して、プランを書きに戻らせる。
#
# ask ではなく deny を返すのは、消したかった OK ボタンをここで作らないため。Claude は
# EnterPlanMode でプランを出し、ユーザーがそれを承認すると plan-gate-mark.sh が印を置き、
# 以降このフックは素通しする。
#
# 数えるのは**リポジトリの作業ツリー内の実ファイル**だけ。プランファイル・スクラッチ
# パッド・.git 配下・リポ外はいずれも対象外なので、除外リストを持たずに済む。
#
# 契約: stdin に PreToolUse の JSON。素通しは無出力 + 終了コード 0。
# 呼び出し口は hooks/hooks.json、テストは scripts/test-rs-plan-gate.sh。
set -uo pipefail

# 一時的に止めたいときの逃げ道 (このフックは全リポで動くため)
[ "${RS_PLAN_GATE:-1}" = "0" ] && exit 0

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

# プラン中の編集はプラン機構自身が抑えている (承認前に作業ツリーは触れない)
mode=$(printf '%s' "$input" | jq -r '.permission_mode // ""')
[ "$mode" = "plan" ] && exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
session=$(printf '%s' "$input" | jq -r '.session_id // ""')
target=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""')
[ -n "$cwd" ] && [ -n "$session" ] && [ -n "$target" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0

# --- 対象がこのリポの作業ツリー内か ------------------------------------------
# 判定できないものはすべて素通し (安全側ではなく静かな側へ倒す。止めそこねても
# 失うのは合意のタイミングだけで、取り返しはつく)
toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
toplevel=$(cd "$toplevel" 2>/dev/null && pwd -P) || exit 0

case "$target" in
  /*) abs="$target" ;;
  *) abs="$cwd/$target" ;;
esac
# まだ存在しないファイル (Write の新規作成) も扱うので、親ディレクトリだけを解決する。
# /tmp → /private/tmp のような symlink を挟む環境でも toplevel と同じ形に揃う
parent=$(cd "$(dirname "$abs")" 2>/dev/null && pwd -P) || exit 0
abs="$parent/$(basename "$abs")"

case "$abs" in
  "$toplevel"/*) ;;
  *) exit 0 ;;  # リポ外 (プランファイル・スクラッチパッド・他リポ)
esac
case "$abs" in
  */.git/*) exit 0 ;;
esac

# --- 承認済みプランの印 -------------------------------------------------------
# 置き場は cwd に依存しない (plan-gate-mark.sh の冒頭を参照)。承認はセッションの
# 事実なので、印を置いた側と読む側で cwd が違っても同じ場所を指す必要がある
approved="${RS_PLAN_GATE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plan-gate}/$session.approved"
[ -f "$approved" ] && exit 0

# --- 合意なしに触ったファイル数 -----------------------------------------------
# 台帳はリポジトリ単位でよい (数えるのはこのリポの作業ツリー内のファイルだけで、
# ここへ来る時点で cwd のリポと対象ファイルのリポは一致している)
git_dir=$(git rev-parse --git-common-dir 2>/dev/null) || exit 0
dir="$git_dir/claude-plan-gate"
mkdir -p "$dir" 2>/dev/null || exit 0
ledger="$dir/$session.files"
touch "$ledger" 2>/dev/null || exit 0
grep -Fxq "$abs" "$ledger" 2>/dev/null || printf '%s\n' "$abs" >> "$ledger"

threshold=${RS_PLAN_GATE_THRESHOLD:-3}
count=$(wc -l < "$ledger" 2>/dev/null | tr -d ' ')
[ "$count" -lt "$threshold" ] 2>/dev/null && exit 0

touched=$(sed "s|^$toplevel/||" "$ledger" | sed 's/^/  - /')
jq -n --arg r "承認済みのプランが無いまま、このセッションでの編集が ${count} ファイルに広がっている:

${touched}

ここで手を止めて方向性の合意を取る。EnterPlanMode でプラン (目的・変更点・確認方法) を提示し、ユーザーが承認したら続きを実装する。承認された時点でこのゲートは以降このセッションでは何も言わない。

実行の一つひとつに確認を挟まない代わりに、確認をこの 1 点へ集約している。ユーザーが「プランは要らない」と明示したときだけ RS_PLAN_GATE=0 で外す。

承認印の置き場: ${approved} (未作成)。プランを承認済みなのにこの差し戻しが出たなら印が置かれていないということなので、実装を続けず、このパスごとユーザーへ報告する。" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'

exit 0
