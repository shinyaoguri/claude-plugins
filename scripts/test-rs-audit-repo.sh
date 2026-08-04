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

# 検証対象の builtin だけを持つ最小 manifest。level は recommended なので違反時の status は warn
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
    },
    {
      "id": "test-dir-exists",
      "layer": "repo",
      "level": "recommended",
      "applies_to": ["all"],
      "check": { "type": "builtin", "name": "test_dir_exists" },
      "why": "テスト用",
      "fix": "テスト用"
    },
    {
      "id": "tests-run-in-ci",
      "layer": "repo",
      "level": "recommended",
      "applies_to": ["all"],
      "check": { "type": "builtin", "name": "tests_run_in_ci" },
      "why": "テスト用",
      "fix": "テスト用"
    }
  ]
}
EOF

# assert が検証する項目 id (セクションごとに切り替える)
check_id=adr-exists

# assert <期待 status> <ケース名> <セットアップコマンド...>
assert() {
  local want=$1 name=$2; shift 2
  local dir="$tmp/case-$RANDOM"
  mkdir -p "$dir"
  ( cd "$dir" && git init -q -b main && "$@" ) || { echo "  [ERROR] $name: セットアップ失敗"; failures=$((failures + 1)); return; }

  local got
  got=$( cd "$dir" && REPO_STANDARDS_JSON="$manifest" bash "$target" \
    | jq -r --arg id "$check_id" 'select(.id == $id) | .status' )

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
echo "builtin_test_dir_exists (bash テスト):"
check_id=test-dir-exists

# 正常系: scripts/test-*.sh 形式 (このリポ自身の形。#47 で塞いだ穴)
assert ok "scripts/test-*.sh を認識する" \
  bash -c 'mkdir -p scripts && touch scripts/test-foo.sh && git add -A'

# 正常系: *_test.sh 形式
assert ok "*_test.sh を認識する" \
  bash -c 'mkdir -p scripts && touch scripts/foo_test.sh && git add -A'

# 境界値: 名前に test を含むだけのスクリプトは誤検出しない
assert warn "latest-build.sh は誤検出しない" \
  bash -c 'mkdir -p scripts && touch scripts/latest-build.sh && git add -A'

echo
echo "builtin_tests_run_in_ci (bash テスト):"
check_id=tests-run-in-ci

# 正常系: workflow がテストスクリプトを直接実行している (このリポ自身の形)
assert ok "CI で ./scripts/test-*.sh を実行している" \
  bash -c 'mkdir -p scripts .github/workflows && touch scripts/test-foo.sh &&
           printf "jobs:\n  t:\n    steps:\n      - run: ./scripts/test-foo.sh\n" > .github/workflows/ci.yml &&
           git add -A'

# 失敗系: テストはあるが CI が実行していない
assert warn "テストはあるが CI で実行していない" \
  bash -c 'mkdir -p scripts .github/workflows && touch scripts/test-foo.sh &&
           printf "jobs:\n  t:\n    steps:\n      - run: echo build\n" > .github/workflows/ci.yml &&
           git add -A'

check_id=adr-exists

echo
echo "正本の fix_kind を素通しする (修正側の承認粒度を決める契約):"

# 正本がまだ持たない項目では落ちる / 持つ項目ではそのまま載る、の両方を固定する
fk_dir="$tmp/fix-kind"
mkdir -p "$fk_dir"
cat > "$fk_dir/m.json" <<'EOF'
{
  "version": 1,
  "kinds": [{ "id": "generic", "marker": null }],
  "items": [
    { "id": "with-kind", "layer": "repo", "level": "required", "applies_to": ["all"],
      "check": { "type": "file_exists", "path": "README.md" },
      "why": "テスト用", "fix": "テスト用", "fix_kind": "generative" },
    { "id": "without-kind", "layer": "repo", "level": "required", "applies_to": ["all"],
      "check": { "type": "file_exists", "path": "README.md" },
      "why": "テスト用", "fix": "テスト用" }
  ]
}
EOF
mkdir -p "$fk_dir/repo"
( cd "$fk_dir/repo" && git init -q -b main ) >/dev/null 2>&1
out=$( cd "$fk_dir/repo" && REPO_STANDARDS_JSON="$fk_dir/m.json" bash "$target" )
got=$(jq -r 'select(.id == "with-kind") | .fix_kind // "-"' <<<"$out")
if [ "$got" = "generative" ]; then
  echo "  [ok]   fix_kind がある項目は素通しする → $got"
else
  echo "  [FAIL] fix_kind がある項目 → 期待 generative / 実際 $got"
  failures=$((failures + 1))
fi
got=$(jq -r 'select(.id == "without-kind") | has("fix_kind")' <<<"$out")
if [ "$got" = "false" ]; then
  echo "  [ok]   fix_kind が無い項目には付けない → 出力に無い"
else
  echo "  [FAIL] fix_kind が無い項目 → 期待 false / 実際 $got"
  failures=$((failures + 1))
fi

echo
echo "前提不足時の報告 (出力契約の範囲内で):"

# git リポ外でも契約内の status/level で報告する (#34 で塞いだ穴: error/- を出していた)
dir="$tmp/not-a-repo"
mkdir -p "$dir"
line=$( cd "$dir" && REPO_STANDARDS_JSON="$manifest" bash "$target" \
  | jq -c 'select(.id == "not-a-git-repo")' )
if [ "$(jq -r .status <<<"$line")" = "ng" ] && [ "$(jq -r .level <<<"$line")" = "required" ]; then
  echo "  [ok]   git リポ外 → required/ng で報告"
else
  echo "  [FAIL] git リポ外 → 期待 required/ng / 実際 $(jq -r '"\(.level)/\(.status)"' <<<"$line")"
  failures=$((failures + 1))
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK"
