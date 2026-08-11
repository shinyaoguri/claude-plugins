#!/usr/bin/env bash
# PostToolUse(ExitPlanMode) hook — プランが承認されたら「合意済み」の印を置く。
#
# 印があるあいだ plan-gate.sh は素通しする。ExitPlanMode はユーザーが却下すると
# tool_result が is_error になり PostToolUse は発火しない (PostToolUseFailure へ回る)
# ため、**この印が置かれた = プランが承認された**と等価に扱える。
#
# stdin: PostToolUse の JSON (.cwd / .session_id)
# 出力なし・常に exit 0 (この hook は判断を下さない)
set -uo pipefail

[ "${RS_PLAN_GATE:-1}" = "0" ] && exit 0

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // ""')
session=$(printf '%s' "$input" | jq -r '.session_id // ""')
[ -n "$cwd" ] && [ -n "$session" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0

# worktree からでも同じ場所を指すよう common-dir を使う (ci-watch と同じ置き場の作法)。
# セッション ID で分離するので並行セッション同士は衝突しない
git_dir=$(git rev-parse --git-common-dir 2>/dev/null) || exit 0
dir="$git_dir/claude-plan-gate"
mkdir -p "$dir" 2>/dev/null || exit 0
: > "$dir/$session.approved"

exit 0
