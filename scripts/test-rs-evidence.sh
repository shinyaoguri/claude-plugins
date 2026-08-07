#!/usr/bin/env bash
# repo-standards プラグインの rs-evidence.sh のテスト。
# 一時 git リポジトリと最小 manifest を用意し、集めた材料 (プレーンテキスト) を検証する。
#
# ここで守るのは「安く判定するための材料の質」と「材料に載せてはいけないもの」:
#   秘密の値を出さないこと、対象外を skip と明示すること (判定側に推測させない)、
#   未実装 id で落ちないこと、日本語が壊れないこと。
#
#   bash scripts/test-rs-evidence.sh
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
target="$repo_root/plugins/repo-standards/scripts/rs-evidence.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export GIT_AUTHOR_NAME=rs-test GIT_AUTHOR_EMAIL=rs-test@example.invalid
export GIT_COMMITTER_NAME=rs-test GIT_COMMITTER_EMAIL=rs-test@example.invalid

failures=0
ok()   { echo "  [ok]   $1"; }
fail() { echo "  [FAIL] $1"; failures=$((failures + 1)); }

# 正本の llm 項目だけを持つ最小 manifest (id は正本と同じものを使う)
manifest="$tmp/standards.json"
cat > "$manifest" <<'EOF'
{
  "version": 1,
  "kinds": [{ "id": "generic", "marker": null }],
  "items": [
    { "id": "adr-covers-decisions", "layer": "repo", "level": "required", "applies_to": ["all"],
      "check": { "type": "llm", "prompt": "ADR の網羅性を判定する" }, "why": "テスト用", "fix": "テスト用" },
    { "id": "work-log-externalized", "layer": "repo", "level": "required", "applies_to": ["all"],
      "check": { "type": "llm", "prompt": "作業ログの外部化を判定する" }, "why": "テスト用", "fix": "テスト用" },
    { "id": "claude-md-quality", "layer": "claude", "level": "recommended", "applies_to": ["all"],
      "check": { "type": "llm", "prompt": "CLAUDE.md の質を判定する" }, "why": "テスト用", "fix": "テスト用" },
    { "id": "claude-mcp-config-sane", "layer": "claude", "level": "recommended", "applies_to": ["all"],
      "check": { "type": "llm", "prompt": "MCP 設定の妥当性を判定する" }, "why": "テスト用", "fix": "テスト用" },
    { "id": "future-llm-item", "layer": "repo", "level": "recommended", "applies_to": ["all"],
      "check": { "type": "llm", "prompt": "将来 setup リポ側で足される項目" }, "why": "テスト用", "fix": "テスト用" }
  ]
}
EOF

# mk_repo <name> <セットアップコマンド...> — 一時 git リポを作って echo でパスを返す
mk_repo() {
  local name=$1; shift
  local dir="$tmp/$name"
  mkdir -p "$dir"
  ( cd "$dir" && git init -q -b main && "$@" ) >/dev/null 2>&1 \
    || { echo "セットアップ失敗: $name" >&2; return 1; }
  printf '%s\n' "$dir"
}

run() { # <dir> [id...]
  local dir=$1; shift
  ( cd "$dir" && REPO_STANDARDS_JSON="$manifest" bash "$target" "$@" )
}

echo "秘密情報を材料に載せない (.mcp.json):"

SECRET='sk-live-DO-NOT-LEAK-0123456789'
dir=$(mk_repo mcp-literal git commit -q --allow-empty -m init) || exit 1
# fixture は heredoc の入れ子を避けてホスト側で書く (${...} の多重エスケープで
# 壊れた JSON になると「読めないから漏れない」だけのテストになり、検査が空振りする)
cat > "$dir/.mcp.json" <<JSON
{"mcpServers": {
  "leaky": {"command": "node", "env": {"API_KEY": "$SECRET"}},
  "clean": {"command": "node", "env": {"API_KEY": "\${MY_TOKEN}"}}
}}
JSON
jq -e . "$dir/.mcp.json" >/dev/null || { echo "fixture の .mcp.json が不正"; exit 1; }

out=$(run "$dir")
grep -qF "$SECRET" <<<"$out" \
  && fail "秘密の値が材料に出ている (サブエージェントへ持ち出される)" \
  || ok "リテラル直書きでも値そのものは出さない"
grep -q 'env API_KEY = リテラル直書き' <<<"$out" \
  && ok "直書きは「リテラル直書き」として報告する" \
  || fail "直書きを報告していない: $(grep -A4 '^### claude-mcp' <<<"$out")"
grep -q 'env API_KEY = 環境変数参照' <<<"$out" \
  && ok "\${VAR} 参照は「環境変数参照」として報告する" \
  || fail "環境変数参照を報告していない"

echo
echo "対象外は skip と明示する (判定側に推測させない):"

dir=$(mk_repo empty bash -c 'echo hi > README.md && git add -A && git commit -q -m init') || exit 1
out=$(run "$dir")
grep -q '### claude-mcp-config-sane' <<<"$out" && grep -q '\.mcp\.json が無い (対象外)' <<<"$out" \
  && ok ".mcp.json が無ければ「対象外」と書く" || fail ".mcp.json 不在の扱いが曖昧: $out"
grep -q 'ADR ディレクトリが無い' <<<"$out" \
  && ok "ADR が無ければ skip の根拠を書く" || fail "ADR 不在の扱いが曖昧"

# 30 日以上コミットが無いリポは work-log を打ち切る (gh を呼ばずに返る)
old=$(( $(date +%s) - 60 * 86400 ))
dir=$(mk_repo stale bash -c "GIT_AUTHOR_DATE='@$old +0000' GIT_COMMITTER_DATE='@$old +0000' \
  git commit -q --allow-empty -m old") || exit 1
out=$(run "$dir" work-log-externalized)
grep -q '動いていないリポなので skip' <<<"$out" \
  && ok "30 日動いていないリポは work-log を skip する" \
  || fail "stale リポで skip していない: $out"

echo
echo "材料の中身:"

dir=$(mk_repo full bash -c '
  mkdir -p docs/decisions
  printf "# 0001: テストの決定\n\n- **状態**: 採用\n- **文脈**: x\n- **決定**: y\n- **影響**: z\n" > docs/decisions/0001-x.md
  printf "# 0002: 節が欠けた決定\n\n- **決定**: y\n" > docs/decisions/0002-y.md
  printf "# テスト規約\n\n## 検証\n\nbash scripts/test.sh で回す\n" > CLAUDE.md
  git add -A && git commit -q -m init') || exit 1
out=$(run "$dir")

grep -q '0001-x.md .*状態: 採用.*節: 影響/決定/context\|0001-x.md .*状態: 採用' <<<"$out" \
  && ok "ADR のファイル名と状態を出す" || fail "ADR の行が想定と違う: $(grep '0001-x' <<<"$out")"
grep -q '0002-y.md .*節: 決定$' <<<"$out" \
  && ok "節が欠けた ADR は欠けたまま報告する (判定材料になる)" \
  || fail "0002 の節が想定と違う: $(grep '0002-y' <<<"$out")"
grep -q 'bash scripts/test.sh で回す' <<<"$out" \
  && ok "CLAUDE.md は全文を渡す (質の判定には本文が要る)" || fail "CLAUDE.md 本文が無い"

echo
echo "正本とのずれで落ちない:"

out=$(run "$dir" future-llm-item); code=$?
if [ "$code" -eq 0 ] && grep -q '未実装' <<<"$out" && grep -q '将来 setup リポ側で足される項目' <<<"$out"; then
  ok "材料収集が未実装の id は判定観点だけ渡して degrade する"
else
  fail "未実装 id の degrade → exit=$code / 出力: $out"
fi

out=$(run "$dir" no-such-item); code=$?
if [ "$code" -eq 0 ] && grep -q '正本に no-such-item が無い' <<<"$out"; then
  ok "正本に無い id は skip として報告する"
else
  fail "未知 id → exit=$code / 出力: $out"
fi

echo
echo "出力の健全性:"

out=$(run "$dir")
if printf '%s' "$out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
  ok "UTF-8 として妥当 (バイト単位の切り詰めで日本語を割っていない)"
else
  fail "UTF-8 が壊れている"
fi
n=$(grep -c '^### ' <<<"$out")
[ "$n" -eq 5 ] && ok "manifest の llm 項目ぶんだけブロックを出す (5 件)" \
  || fail "ブロック数が想定外 → $n"

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK"
