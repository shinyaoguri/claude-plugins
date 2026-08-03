#!/usr/bin/env bash
# repo-standards プラグインの rs-audit-repo.sh の builtin 判定テスト。
# 一時 git リポジトリと最小 manifest を用意し、出力 (JSON Lines) の status を検証する。
# 関数を source せずエンドツーエンドで見るのは、正本との契約 (出力スキーマ) ごと守るため。
#
#   bash scripts/test-rs-audit-repo.sh
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
target="$repo_root/plugins/repo-standards/scripts/rs-audit-repo.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

failures=0

# 1 項目だけの最小 manifest。level は recommended なので違反時の status は warn
manifest="$tmp/standards.json"
cat > "$manifest" <<'EOF'
{
  "version": 1,
  "kinds": [{ "id": "generic", "marker": null }],
  "items": [
    {
      "id": "adr-exists",
      "layer": "repo",
      "level": "recommended",
      "applies_to": ["all"],
      "check": { "type": "builtin", "name": "adr_exists" },
      "why": "テスト用",
      "fix": "テスト用"
    }
  ]
}
EOF

# assert <期待 status> <ケース名> <セットアップコマンド...>
assert() {
  local want=$1 name=$2; shift 2
  local dir="$tmp/case-$RANDOM"
  mkdir -p "$dir"
  ( cd "$dir" && git init -q -b main && "$@" ) || { echo "  [ERROR] $name: セットアップ失敗"; failures=$((failures + 1)); return; }

  local got
  got=$( cd "$dir" && REPO_STANDARDS_JSON="$manifest" bash "$target" \
    | jq -r 'select(.id == "adr-exists") | .status' )

  if [ "$got" = "$want" ]; then
    echo "  [ok]   $name → $got"
  else
    echo "  [FAIL] $name → 期待 $want / 実際 $got"
    failures=$((failures + 1))
  fi
}

echo "builtin_adr_exists:"

# 正常系: ADR が 1 件ある
assert ok "ADR が 1 件ある" \
  bash -c 'mkdir -p docs/decisions && echo "# 0001" > docs/decisions/0001-x.md'

# 正常系: 別名のディレクトリでも拾う
assert ok "docs/adr/ でも拾う" \
  bash -c 'mkdir -p docs/adr && echo "# 0001" > docs/adr/0001-x.md'

# 失敗系: ディレクトリ自体が無い
assert warn "docs/decisions/ が無い" true

# 失敗系: ディレクトリはあるが空 (この PR で塞いだ穴)
assert warn "ディレクトリはあるが空" \
  bash -c 'mkdir -p docs/decisions'

# 境界値: 索引の README.md だけでは ADR 本体が無いとみなす
assert warn "README.md しか無い" \
  bash -c 'mkdir -p docs/decisions && echo "# 索引" > docs/decisions/README.md'

# 境界値: サブディレクトリの .md は数えない (maxdepth 1)
assert warn "サブディレクトリの .md のみ" \
  bash -c 'mkdir -p docs/decisions/drafts && echo "# 草案" > docs/decisions/drafts/0001-x.md'

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK"

# 一時検証: guardrail ジョブのコメント経路の実証 (直後に戻す)
true || true
