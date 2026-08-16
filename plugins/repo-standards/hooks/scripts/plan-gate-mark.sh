#!/usr/bin/env bash
# PostToolUse(ExitPlanMode) hook — プランが承認されたら「合意済み」の印を置く。
#
# 印があるあいだ plan-gate.sh は素通しする。ExitPlanMode はユーザーが却下すると
# tool_result が is_error になり PostToolUse は発火しない (PostToolUseFailure へ回る)
# ため、**この印が置かれた = プランが承認された**と等価に扱える。
#
# 置き場は **cwd を一切見ない**。承認はセッションの事実であって、そのとき偶然どこに
# いたかとは関係がないため。以前はリポジトリの git common-dir へ置いていたが、
# Bash ツールの cd で cwd が別リポへドリフトしていると印がそちらの .git へ落ち、
# 承認済みなのに plan-gate.sh が deny を返した (ADR 0017 の「印はセッション単位」参照)。
#
# stdin: PostToolUse の JSON (.session_id)
# 出力なし・常に exit 0 (この hook は判断を下さない)
set -uo pipefail

[ "${RS_PLAN_GATE:-1}" = "0" ] && exit 0

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

session=$(printf '%s' "$input" | jq -r '.session_id // ""')
[ -n "$session" ] || exit 0

dir="${RS_PLAN_GATE_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plan-gate}"
mkdir -p "$dir" 2>/dev/null || exit 0
: > "$dir/$session.approved"

# 0 バイトの印が溜まり続けないよう掃除する。セッションはこれより長く生きない
# (掃除された後に --resume で戻ってきたら、プランを出し直すだけで済む)
find "$dir" -type f -name '*.approved' -mtime +30 -delete 2>/dev/null

exit 0
