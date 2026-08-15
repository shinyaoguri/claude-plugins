#!/usr/bin/env bash
# repo-standards プラグインの rs-inflight.sh の収集テスト。
# 実際の gh 認証・API とマシンのセッション状態に依存させないため、PATH 先頭に fake gh を
# 置いて応答を注入し、セッション JSON は $RS_INFLIGHT_SESSIONS_DIR で一時ディレクトリへ
# 逃がす。関数を source せずエンドツーエンドで見るのは、正本との契約 (出力スキーマ) ごと
# 守るため。
#
#   bash scripts/test-rs-inflight.sh
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
target="$repo_root/plugins/repo-standards/scripts/rs-inflight.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

failures=0

# fake gh。RS_TEST_GH_AUTH=0 で未認証、RS_TEST_LABEL_EXISTS=1 で着手印ラベルが実在。
# --jq を使う呼び出し (repo view / label list) は gh 側で絞り込まれた結果を返す
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status")  [ "${RS_TEST_GH_AUTH:-1}" = "1" ] || exit 1; exit 0 ;;
  "repo view")    echo "acme/demo" ;;
  "label list")   [ "${RS_TEST_LABEL_EXISTS:-0}" = "1" ] && echo "status: in progress"; exit 0 ;;
  "pr list")      cat "${RS_TEST_PR_JSON:-/dev/null}" ;;
  "issue list")   cat "${RS_TEST_ISSUE_JSON:-/dev/null}" ;;
  *)              exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

cat > "$tmp/pr.json" <<'EOF'
[{"number":42,"title":"fix(core): 何かを直す","headRefName":"fix/thing","isDraft":false,
  "files":[{"path":"Sources/Core/Thing.swift"},{"path":"Tests/ThingTests.swift"}]}]
EOF
cat > "$tmp/issue.json" <<'EOF'
[{"number":7,"title":"着手中の Issue","url":"https://github.com/acme/demo/issues/7"}]
EOF

# 一時 git リポと、そこに紐づく別 worktree を 1 本
main="$tmp/repo"
git init -q "$main"
# 既定ブランチ名は git の版と実行環境の設定で master / main に割れるので固定する
git -C "$main" symbolic-ref HEAD refs/heads/main
git -C "$main" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$main" worktree add -q -b other "$tmp/other" >/dev/null 2>&1

sessions="$tmp/sessions"
mkdir -p "$sessions"
now=$(date +%s)
printf '{"session_id":"a","updated_at":%s,"project":"demo","branch":"other","title":"稼働中","pr":null}\n' \
  "$now" > "$sessions/a.json"
printf '{"session_id":"b","updated_at":%s,"project":"demo","branch":"old","title":"古い","pr":null}\n' \
  "$((now - 7200))" > "$sessions/b.json"
printf 'これは JSON ではない\n' > "$sessions/broken.json"

# run … 対象を tmp リポの中で実行して stdout を返す。
# cwd とセッション置き場はケースごとに $RS_TEST_CWD / $RS_TEST_SESSIONS_DIR で差し替える
run() {
  ( cd "${RS_TEST_CWD:-$main}" && PATH="$tmp/bin:$PATH" \
      RS_INFLIGHT_SESSIONS_DIR="${RS_TEST_SESSIONS_DIR:-$sessions}" \
      RS_TEST_PR_JSON="$tmp/pr.json" RS_TEST_ISSUE_JSON="$tmp/issue.json" \
      bash "$target" 2>/dev/null )
}

# assert <期待> <ケース名> <jq フィルタ>
assert() {
  local want=$1 name=$2 filter=$3 got
  got=$(printf '%s\n' "$out" | jq -r "$filter" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')
  if [ "$got" = "$want" ]; then
    echo "  [ok]   $name → ${got:-(空)}"
  else
    # 変数展開は必ず ${} で閉じる。bash 3.2 (macOS 既定) は「」のような多バイト文字を
    # 識別子の一部として読み、$want」 が未定義変数エラーになる
    echo "  [FAIL] ${name} → 期待「${want}」/ 実際「${got}」"
    failures=$((failures + 1))
  fi
}

echo "== gh あり・ラベル実在 =="
export RS_TEST_GH_AUTH=1 RS_TEST_LABEL_EXISTS=1
out=$(run)
assert "true true"  "_meta.sources が両方 true"     'select(.kind=="_meta") | "\(.sources.gh) \(.sources.sessions)"'
assert "true"       "ラベルの実在を報告する"          'select(.kind=="_meta") | .label_exists | tostring'
assert "main other" "同一リポの worktree を全部拾う"  'select(.kind=="worktree") | .branch'
assert "main"       "自分の worktree に self が立つ"  'select(.kind=="worktree" and .self) | .branch'
assert "42"         "open PR を拾う"                 'select(.kind=="pr") | .number | tostring'
assert "Sources/Core/Thing.swift Tests/ThingTests.swift" "PR が触るファイルを展開する" 'select(.kind=="pr") | .files[]'
assert "7"          "着手印の付いた Issue を拾う"     'select(.kind=="issue") | .number | tostring'
assert "稼働中"      "新しいセッションだけ拾う"        'select(.kind=="session") | .title'
assert "false"      "別ブランチのセッションは self でない" 'select(.kind=="session") | .self | tostring'

echo "== ラベル未作成 =="
export RS_TEST_LABEL_EXISTS=0
out=$(run)
assert "false" "label_exists が false" 'select(.kind=="_meta") | .label_exists | tostring'
assert ""      "Issue 行を出さない (空の結果と区別できないため引かない)" 'select(.kind=="issue") | .number | tostring'

echo "== gh 未認証 =="
export RS_TEST_GH_AUTH=0 RS_TEST_LABEL_EXISTS=1
out=$(run)
assert "false"      "sources.gh が false"     'select(.kind=="_meta") | .sources.gh | tostring'
assert ""           "PR 行を出さない"          'select(.kind=="pr") | .number | tostring'
assert "main other" "worktree の収集は続く"    'select(.kind=="worktree") | .branch'

echo "== セッション置き場が無い =="
export RS_TEST_GH_AUTH=1
out=$(RS_TEST_SESSIONS_DIR="$tmp/nonexistent" run)
assert "false" "sources.sessions が false" 'select(.kind=="_meta") | .sources.sessions | tostring'
assert ""      "session 行を出さない"       'select(.kind=="session") | .title'

echo "== 自分が別 worktree に居るとき =="
out=$(RS_TEST_CWD="$tmp/other" run)
assert "other" "self がその worktree を指す"          'select(.kind=="worktree" and .self) | .branch'
assert "true"  "同ブランチのセッションを self と見なす" 'select(.kind=="session") | .self | tostring'

echo "== 終了コード =="
( cd "$main" && PATH="$tmp/bin:$PATH" RS_INFLIGHT_SESSIONS_DIR="$sessions" bash "$target" >/dev/null 2>&1 )
code=$?
if [ "$code" = "0" ]; then
  echo "  [ok]   何が取れなくても exit 0 → $code"
else
  echo "  [FAIL] 何が取れなくても exit 0 → 期待 0 / 実際 $code"
  failures=$((failures + 1))
fi

( cd "$tmp" && bash "$target" >/dev/null 2>&1 )
code=$?
if [ "$code" != "0" ]; then
  echo "  [ok]   リポジトリ外では非 0 で落ちる → $code"
else
  echo "  [FAIL] リポジトリ外では非 0 で落ちる → 期待 非 0 / 実際 $code"
  failures=$((failures + 1))
fi

echo
if [ "$failures" = "0" ]; then
  echo "rs-inflight: 全ケース ok"
else
  echo "rs-inflight: $failures 件 FAIL"
  exit 1
fi
