#!/usr/bin/env bash
# upsert-pr-comment.sh の分岐テスト。
# PATH に偽 gh を置いて呼び出しを記録し、既存コメントの有無に応じて
# 投稿 / 更新 / 重複削除のどれが走るかを検証する (実際の GitHub には触らない)。
# 偽 gh はコメント一覧に対し --jq 適用後の出力 (id の並び) を直接返すため、
# jq フィルタ自体は対象外。検証するのは呼び出し側の分岐ロジック。
#
#   bash scripts/test-upsert-pr-comment.sh
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
target="$repo_root/scripts/upsert-pr-comment.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

failures=0

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
# 呼び出しを 1 行ずつ記録する偽 gh。コメント一覧の取得だけ $EXISTING_IDS を返す
echo "$*" >> "$GH_CALLS"
if [ "$1" = api ] && [ "$2" != "--method" ] && [[ "$2" == *"/comments" ]]; then
  [ -n "${EXISTING_IDS:-}" ] && printf '%s\n' $EXISTING_IDS
fi
exit 0
FAKE
chmod +x "$tmp/bin/gh"

echo body > "$tmp/body.md"

# case <ケース名> <既存 id 群 (空文字で無し)> <モード ("" | --update-only)> <期待 (呼び出し種別:回数 の並び)>
case_run() {
  local name=$1 existing=$2 mode=$3 want=$4
  local calls="$tmp/calls-$RANDOM"
  : > "$calls"

  ( PATH="$tmp/bin:$PATH" GH_CALLS="$calls" EXISTING_IDS="$existing" \
    MARKER='<!-- m -->' PR=12 REPO=o/r \
    bash "$target" "$tmp/body.md" ${mode:+"$mode"} >/dev/null 2>&1 )

  local post patch delete got
  post=$(grep -c '^pr comment ' "$calls")
  patch=$(grep -c -- '--method PATCH' "$calls")
  delete=$(grep -c -- '--method DELETE' "$calls")
  got="post:$post patch:$patch delete:$delete"

  if [ "$got" = "$want" ]; then
    echo "  [ok]   $name → $got"
  else
    echo "  [FAIL] $name → 期待 [$want] / 実際 [$got]"
    failures=$((failures + 1))
  fi
}

echo "upsert-pr-comment.sh:"

# 既存が無ければ新規投稿する
case_run "既存なし" "" "" "post:1 patch:0 delete:0"

# --update-only は「解消した」報告用。まだ何も言っていない PR にコメントを生やさない
case_run "既存なし + --update-only" "" "--update-only" "post:0 patch:0 delete:0"

# 既存があれば投稿でなく更新 (毎 push でコメントが増えない)
case_run "既存 1 件" "111" "" "post:0 patch:1 delete:0"
case_run "既存 1 件 + --update-only" "111" "--update-only" "post:0 patch:1 delete:0"

# 並行実行ですり抜けて重複した分は、次の run で最古の 1 件へ畳む (境界値: 3 件)
case_run "既存 3 件 (重複を掃除)" "111 222 333" "" "post:0 patch:1 delete:2"

# 更新対象は最古の 1 件 (コメントの並び順を保つ)
calls="$tmp/calls-order"
: > "$calls"
( PATH="$tmp/bin:$PATH" GH_CALLS="$calls" EXISTING_IDS="111 222" \
  MARKER='<!-- m -->' PR=12 REPO=o/r bash "$target" "$tmp/body.md" >/dev/null 2>&1 )
if grep -q -- '--method PATCH repos/o/r/issues/comments/111' "$calls" \
  && grep -q -- '--method DELETE repos/o/r/issues/comments/222' "$calls"; then
  echo "  [ok]   更新は最古の id (111)、削除は後続 (222)"
else
  echo "  [FAIL] 更新/削除の対象 id が想定と違う:"
  sed 's/^/         /' "$calls"
  failures=$((failures + 1))
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK"
