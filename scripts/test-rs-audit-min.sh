#!/usr/bin/env bash
# repo-standards プラグインの rs-audit-min.sh のテスト。
# 一時 git リポジトリと最小 manifest を用意し、出力 (圧縮テキスト) の行と集計を検証する。
# 関数を source せずエンドツーエンドで見るのは、正本との契約 (出力書式) ごと守るため。
#
# このスクリプトが守るのは「トークン最小化のための割り切り」そのもの:
#   ok / skip / manual の項目を行として出さないこと、manual に踏み込まないこと、
#   detail を切り詰めること。ここが緩むと簡易監査である意味が消える。
#
#   bash scripts/test-rs-audit-min.sh
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
target="$repo_root/plugins/repo-standards/scripts/rs-audit-min.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export GIT_AUTHOR_NAME=rs-test GIT_AUTHOR_EMAIL=rs-test@example.invalid
export GIT_COMMITTER_NAME=rs-test GIT_COMMITTER_EMAIL=rs-test@example.invalid

failures=0
ok()   { echo "  [ok]   $1"; }
fail() { echo "  [FAIL] $1"; failures=$((failures + 1)); }

# 5 つの status を 1 つずつ生む最小 manifest。
# ng-item の why は 60 文字を超える (切り詰めの境界を見るため)
manifest="$tmp/standards.json"
cat > "$manifest" <<'EOF'
{
  "version": 1,
  "kinds": [{ "id": "generic", "marker": null }],
  "items": [
    { "id": "ok-item", "layer": "repo", "level": "required", "applies_to": ["all"],
      "check": { "type": "file_exists", "path": "README.md" },
      "why": "テスト用", "fix": "テスト用" },
    { "id": "ng-item", "layer": "repo", "level": "required", "applies_to": ["all"],
      "check": { "type": "file_exists", "path": "MISSING.md" },
      "why": "この理由文はわざと長くしてある。切り詰め幅の境界を越えさせて末尾に省略記号が付くことを確かめるための文字数稼ぎである。",
      "fix": "テスト用" },
    { "id": "warn-item", "layer": "repo", "level": "recommended", "applies_to": ["all"],
      "check": { "type": "file_exists", "path": "MISSING2.md" },
      "why": "テスト用", "fix": "テスト用" },
    { "id": "skip-item", "layer": "repo", "level": "required", "applies_to": ["swift"],
      "check": { "type": "file_exists", "path": "MISSING3.md" },
      "why": "テスト用", "fix": "テスト用" },
    { "id": "manual-item", "layer": "claude", "level": "required", "applies_to": ["all"],
      "check": { "type": "llm", "prompt": "テスト用の LLM 判定プロンプト" },
      "why": "テスト用", "fix": "テスト用" },
    { "id": "gh-item", "layer": "github", "level": "required", "applies_to": ["all"],
      "check": { "type": "gh_api", "path": "has_wiki", "expect": false },
      "why": "テスト用", "fix": "テスト用" }
  ]
}
EOF

# 検証対象のリポジトリ。origin を持たないので層② (GitHub) は gh の有無によらず skip になる
dir="$tmp/repo"
mkdir -p "$dir"
( cd "$dir" && git init -q -b main && echo "# r" > README.md && git add -A \
  && git commit -q -m init ) || { echo "セットアップ失敗"; exit 1; }

run() { ( cd "$dir" && REPO_STANDARDS_JSON="$manifest" bash "$target" "$@" ); }

echo "行に出す項目の絞り込み (ok / skip / manual は出さない):"

out=$(run --no-github)
code=$?

[ "$code" -eq 0 ] && ok "exit 0 を保つ" || fail "exit 0 を保つ → 実際 $code"

grep -q '^NG   *ng-item' <<<"$out" && ok "ng は NG 行として出る" \
  || fail "ng が NG 行として出ない: $out"
grep -q '^WARN ng-item' <<<"$out" && fail "ng を WARN として出している" \
  || ok "ng を WARN と取り違えない"
grep -q '^WARN warn-item' <<<"$out" && ok "warn は WARN 行として出る" \
  || fail "warn が WARN 行として出ない: $out"
grep -q 'ok-item' <<<"$out" && fail "ok 項目を行に出している (トークンの無駄)" \
  || ok "ok 項目は行に出さない"
grep -q 'skip-item' <<<"$out" && fail "skip 項目を行に出している" \
  || ok "skip 項目は行に出さない"
grep -q 'manual-item' <<<"$out" && fail "manual 項目を行に出している (LLM 判定に踏み込んでいる)" \
  || ok "manual 項目は行に出さず件数だけ数える"
grep -q 'LLM 判定 1 件' <<<"$out" && ok "LLM 判定の件数を次アクションに出す" \
  || fail "LLM 判定件数が次アクションに無い: $out"

echo
echo "集計行:"

want="ok=1 ng=1 warn=1 skip=1 manual=1"
got=$(grep -E '^ok=' <<<"$out")
[ "$got" = "$want" ] && ok "集計行 → $got" || fail "集計行 → 期待 [$want] / 実際 [$got]"

echo
echo "並び順 (NG を先に読ませる):"

order=$(grep -E '^(NG|WARN) ' <<<"$out" | head -1)
case "$order" in NG*) ok "NG が WARN より先" ;; *) fail "先頭が NG でない: $order" ;; esac

echo
echo "detail の切り詰め (--width):"

grep -q '…' <<<"$out" && ok "既定幅で長い detail を切り詰める" \
  || fail "長い detail が切り詰められていない: $out"
run --no-github --width 0 | grep -qE '^NG +ng-item *$' \
  && ok "--width 0 で detail を落とす" || fail "--width 0 でも detail が付く"
run --no-github --width 400 | grep -q '…' \
  && fail "--width 400 でも切り詰めている" || ok "--width 400 では切り詰めない"

echo
echo "ヘッダ (GitHub 上のリポを特定できないとき):"

head1=$(head -1 <<<"$out")
case "$head1" in
  dir=repo\ kind=generic\ *) ok "dir= で作業ディレクトリ名だと明示する → $head1" ;;
  repo=*) fail "GitHub リポを特定できないのに repo= を名乗っている → $head1" ;;
  *) fail "ヘッダの書式が想定外 → $head1" ;;
esac

echo
echo "--no-github (層② を丸ごと省く):"

with=$(run | grep -E '^ok=')
[ "$with" = "ok=1 ng=1 warn=1 skip=2 manual=1" ] \
  && ok "既定では layer:github の項目も数える (origin 無しなので skip) → $with" \
  || fail "既定の集計 → 期待 [ok=1 ng=1 warn=1 skip=2 manual=1] / 実際 [$with]"
[ "$got" = "$want" ] && ok "--no-github では層② が集計から消える" \
  || fail "--no-github でも層② が残っている"

echo
echo "前提不足時も報告で止まる (ゲートではない):"

# git リポ外
outside="$tmp/not-a-repo"
mkdir -p "$outside"
o=$( cd "$outside" && REPO_STANDARDS_JSON="$manifest" bash "$target" --no-github ); c=$?
if [ "$c" -eq 0 ] && grep -q '^NG   *not-a-git-repo' <<<"$o"; then
  ok "git リポ外 → exit 0 で NG 行として報告"
else
  fail "git リポ外 → exit=$c / 出力: $o"
fi

# 正本不在 (HOME も潰してフォールバックを断つ)
o=$( cd "$dir" && HOME="$tmp/nohome" REPO_STANDARDS_JSON="$tmp/absent.json" \
       bash "$target" --no-github ); c=$?
if [ "$c" -eq 0 ] && grep -q '正本 repo-standards.json が無い' <<<"$o"; then
  ok "正本不在 → 監査を続けず setup を促す"
else
  fail "正本不在 → exit=$c / 出力: $o"
fi

echo
echo "出力の総量 (簡易監査であり続けるための上限):"

lines=$(wc -l <<<"$out" | tr -d ' ')
bytes=$(wc -c <<<"$out" | tr -d ' ')
# ヘッダ + 逸脱 2 行 + 集計 + 次アクション = 5 行。逸脱が増えてもヘッダ側は増えない
[ "$lines" -eq 5 ] && ok "逸脱 2 件で 5 行 (ヘッダ・集計・次アクション各 1 行)" \
  || fail "行数が想定外 → $lines 行"
[ "$bytes" -lt 700 ] && ok "5 行で ${bytes} バイト (< 700)" \
  || fail "出力が肥大している → ${bytes} バイト"

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK"
