#!/usr/bin/env bash
# rs-doctor-env.sh の gh トークン権限判定のテスト。
# $RS_GH_AUTH_STATUS に gh auth status の出力を注入して status を検証する
# (実際の gh 認証に依存させないため)。他の項目はマシン環境に依存するので対象外。
#
#   bash scripts/test-rs-doctor-env.sh
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
target="$repo_root/plugins/repo-standards/scripts/rs-doctor-env.sh"

failures=0

# assert <期待 status> <ケース名> <gh auth status の出力>
assert() {
  local want=$1 name=$2 status_out=$3
  local got
  got=$( RS_GH_AUTH_STATUS="$status_out" bash "$target" \
    | jq -r 'select(.id == "env-gh-token-admin") | .status' )

  if [ "$got" = "$want" ]; then
    echo "  [ok]   $name → $got"
  else
    echo "  [FAIL] $name → 期待 $want / 実際 $got"
    failures=$((failures + 1))
  fi
}

echo "env-gh-token-admin:"

# 管理権限あり: classic トークンの repo スコープ (ブランチ保護を変更できる)
assert warn "classic の repo スコープ" \
  "  - Token scopes: 'admin:public_key', 'gist', 'read:org', 'repo', 'workflow'"
assert warn "admin:org スコープ" \
  "  - Token scopes: 'admin:org', 'read:user'"
assert warn "delete_repo スコープ" \
  "  - Token scopes: 'delete_repo'"

# 管理権限なし: 読み取り系のみ
assert ok "読み取り系のみ" \
  "  - Token scopes: 'gist', 'read:org', 'read:user'"

# public_repo は repo と別スコープ。部分一致で誤検出しないこと (境界値)
assert ok "public_repo のみ (repo と誤認しない)" \
  "  - Token scopes: 'public_repo', 'workflow'"

# fine-grained PAT はスコープを表示しない
assert ok "スコープ表示なし (fine-grained)" \
  "github.com
  ✓ Logged in to github.com account someone (keyring)
  - Active account: true"

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK"
