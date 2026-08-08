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
echo "env-linked-checkout-dirty (出力契約: warn を出すなら level は recommended):"

# HOME を隔離し、dirty な checkout を指す symlink を組み立てて再現する
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/setuprepo/claude" "$tmp/home/.claude"
git -C "$tmp/setuprepo" init -q -b main
echo base > "$tmp/setuprepo/claude/CLAUDE.md"
git -C "$tmp/setuprepo" add -A
git -C "$tmp/setuprepo" -c user.email=t@example.com -c user.name=t commit -qm init
echo dirty >> "$tmp/setuprepo/claude/CLAUDE.md"
ln -s "$tmp/setuprepo/claude/CLAUDE.md" "$tmp/home/.claude/CLAUDE.md"

line=$( HOME="$tmp/home" RS_GH_AUTH_STATUS="(認証情報なし)" bash "$target" \
  | jq -c 'select(.id == "env-linked-checkout-dirty")' )
if [ "$(jq -r .status <<<"$line")" = "warn" ] && [ "$(jq -r .level <<<"$line")" = "recommended" ]; then
  echo "  [ok]   dirty な checkout → recommended/warn で報告"
else
  echo "  [FAIL] dirty な checkout → 期待 recommended/warn / 実際 $(jq -r '"\(.level)/\(.status)"' <<<"$line")"
  failures=$((failures + 1))
fi

echo
echo "env-git-fetch-prune / env-git-gone-alias (squash 運用のローカルブランチ掃除):"

# assert_git <id> <期待 status> <ケース名> <グローバル gitconfig の中身>
# $GIT_CONFIG_GLOBAL でグローバル設定を差し替え、実マシンの ~/.gitconfig に依存させない。
# 出力契約 (warn を出すなら level は recommended) もあわせて検証する
assert_git() {
  local id=$1 want=$2 name=$3 conf=$4
  local gc="$tmp/gitconfig-$RANDOM"
  printf '%s\n' "$conf" > "$gc"
  local got
  got=$( GIT_CONFIG_GLOBAL="$gc" RS_GH_AUTH_STATUS="(認証情報なし)" bash "$target" \
    | jq -r --arg id "$id" 'select(.id == $id) | "\(.level)/\(.status)"' )

  if [ "$got" = "recommended/$want" ]; then
    echo "  [ok]   $name → $got"
  else
    echo "  [FAIL] $name → 期待 recommended/$want / 実際 ${got:-出力なし}"
    failures=$((failures + 1))
  fi
}

configured='[fetch]
	prune = true
[alias]
	gone = !git fetch -pq && git for-each-ref
	gone-clean = !git gone | while read -r b; do git branch -D "$b"; done'

assert_git env-git-fetch-prune ok "fetch.prune = true" "$configured"
assert_git env-git-gone-alias  ok "エイリアス両方あり" "$configured"

assert_git env-git-fetch-prune warn "設定が空 (未設定)" ""
assert_git env-git-gone-alias  warn "設定が空 (未設定)" ""

# 明示的な false は「未設定」と別経路だが同じく warn (境界値)
assert_git env-git-fetch-prune warn "fetch.prune = false" '[fetch]
	prune = false'

# 片方だけでは棚卸しが完結しないので warn (境界値)
assert_git env-git-gone-alias warn "gone だけあり gone-clean が無い" '[alias]
	gone = !git for-each-ref'

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK"
