#!/usr/bin/env bash
# SessionStart hook: metaphor スケッチプロジェクトで watch 共有セッションが生きていない
# ときだけ、1 行の注意を additionalContext に載せる。
# ガード不成立 (非 metaphor プロジェクト / セッション生存) なら無出力で即終了し、
# 他プロジェクトのセッション開始に影響を与えない。常に exit 0 (非ブロッキング)。
set -eu

dir="${CLAUDE_PROJECT_DIR:-$PWD}"

# ガード 1: metaphor スケッチプロジェクトか
#   - .mcp.json に "metaphor" サーバ定義がある (metaphor new の生成物)
#   - または Package.swift が shinyaoguri/metaphor に依存している (SwiftPM 直依存)
is_metaphor=0
if [ -f "$dir/.mcp.json" ] && grep -q '"metaphor"' "$dir/.mcp.json" 2>/dev/null; then
  is_metaphor=1
elif [ -f "$dir/Package.swift" ] && grep -q 'shinyaoguri/metaphor' "$dir/Package.swift" 2>/dev/null; then
  is_metaphor=1
fi
[ "$is_metaphor" -eq 1 ] || exit 0

# ガード 2: 生存している watch セッション (.metaphor/session.json の pid) が無いこと。
# 判定は metaphor-cli の SharedSession.isProcessAlive と同じ: kill -0 が成功すれば生存、
# 権限エラー (EPERM) でも生存扱い (ps -p で拾う)。
manifest="$dir/.metaphor/session.json"
if [ -f "$manifest" ]; then
  pid="$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$manifest" | head -n1)"
  if [ -n "$pid" ]; then
    if kill -0 "$pid" 2>/dev/null || ps -p "$pid" >/dev/null 2>&1; then
      exit 0
    fi
  fi
fi

cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"metaphor: watch 共有セッションが見つかりません。ライブビューアを観測しながら作業する場合は、先にターミナルで `metaphor watch` を起動し、その後 /mcp で metaphor サーバを再接続してください (逆順だと MCP は watch と別のヘッドレスインスタンスを観測します)。AI 単独で観測する場合はこのままで問題ありません。"}}
EOF
exit 0
