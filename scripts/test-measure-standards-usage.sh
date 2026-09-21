#!/usr/bin/env bash
# measure-standards-usage.sh の判定テスト。
# gh をスタブへ差し替え、リポごとの応答をファイルで組み立てて、集計 (installed / used / skipped) を
# 検証するエンドツーエンド方式。GitHub には一切問い合わせない。
#
#   bash scripts/test-measure-standards-usage.sh
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
target="$repo_root/scripts/measure-standards-usage.sh"

failures=0
check() { # <ケース名> <期待> <実際>
  if [ "$2" = "$3" ]; then
    echo "  [ok]   $1 → $3"
  else
    echo "  [FAIL] $1 → 期待 $2 / 実際 $3"
    failures=$((failures + 1))
  fi
}

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

# --- gh スタブ ---------------------------------------------------------------
# 応答は $GH_STUB_DIR/<owner>__<repo>/ に置く。無いファイルを引かれたら exit 1 (= gh の失敗)。
#   tree                        git/trees の path 一覧 (1 行 1 パス)
#   contents/<パスの / を __ に>  contents API の raw
#   issues.json / prs.json / dependabot.json / runs.json
#   release                     releases/latest の published_at
#   commits/<パスの / を __ に>   commits?path= の先頭コミットの日付
# 本物の gh と同じく --jq は gh の中で当たるので、JSON を返す分岐ではスタブ側で jq に通す。
mkdir -p "$sandbox/bin"
cat > "$sandbox/bin/gh" <<'STUB'
#!/usr/bin/env bash
jqf=""; repo=""; author=""; prev=""
for a in "$@"; do
  case "$prev" in --jq) jqf=$a ;; -R) repo=$a ;; --author) author=$a ;; esac
  prev=$a
done
out() { [ -f "$1" ] || exit 1; if [ -n "$jqf" ]; then jq -r "$jqf" "$1"; else cat "$1"; fi; }
raw() { [ -f "$1" ] || exit 1; cat "$1"; }
slug() { printf '%s' "${1//\//__}"; }
case "$1 $2" in
  "api repos/"*)
    path=${2#repos/}; repo=$(cut -d/ -f1-2 <<<"$path"); rest=${path#"$repo"/}
    d="$GH_STUB_DIR/$(slug "$repo")"
    case "$rest" in
      git/trees/*)       raw "$d/tree" ;;
      contents/*)        raw "$d/contents/$(slug "${rest#contents/}")" ;;
      releases/latest)   raw "$d/release" ;;
      commits\?path=*)   p=${rest#commits?path=}; raw "$d/commits/$(slug "${p%%&*}")" ;;
      *) exit 1 ;;
    esac ;;
  "issue list") out "$GH_STUB_DIR/$(slug "$repo")/issues.json" ;;
  "pr list")
    if [ -n "$author" ]; then out "$GH_STUB_DIR/$(slug "$repo")/dependabot.json"
    else out "$GH_STUB_DIR/$(slug "$repo")/prs.json"; fi ;;
  "run list") out "$GH_STUB_DIR/$(slug "$repo")/runs.json" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$sandbox/bin/gh"
export GH_STUB_DIR="$sandbox/gh"
export PATH="$sandbox/bin:$PATH"

today=$(date -u +%Y-%m-%d)
old="2020-01-01"

# mkrepo <owner/repo> — 空のリポ (何も設置していない) を作る
mkrepo() {
  d="$GH_STUB_DIR/${1//\//__}"
  mkdir -p "$d/contents" "$d/commits"
  : > "$d/tree"; echo '[]' > "$d/issues.json"; echo '[]' > "$d/prs.json"
  echo '[]' > "$d/dependabot.json"; echo '[]' > "$d/runs.json"
}
bodies() { # <見出しに沿う件数> <沿わない件数> <沿う本文> → [{body,author}]
  jq -cn --argjson a "$1" --argjson b "$2" --arg good "$3" \
    '[range($a) | {body: $good, author: {is_bot: false}}] + [range($b) | {body: "自由に書いた本文", author: {is_bot: false}}]'
}
field() { jq -r --arg id "$2" --arg f "$3" 'select(.id == $id) | .[$f]' <<<"$1"; }

echo "measure-standards-usage:"

# --- 正常系: 全部設置して、全部使っている ---
mkrepo o/good
cat > "$d/tree" <<'EOF'
.github/ISSUE_TEMPLATE/improvement.yml
.github/ISSUE_TEMPLATE/config.yml
.github/pull_request_template.md
.github/dependabot.yml
CHANGELOG.md
docs/decisions/README.md
docs/decisions/0001-first.md
EOF
printf 'body:\n  - type: textarea\n    attributes:\n      label: 背景\n  - type: textarea\n    attributes:\n      label: "提案内容"\n' > "$d/contents/.github__ISSUE_TEMPLATE__improvement.yml"
printf '## 目的\n\n## 変更点\n\n## 確認方法\n' > "$d/contents/.github__pull_request_template.md"
bodies 3 0 $'### 背景\nx\n### 提案内容\ny' > "$d/issues.json"
bodies 2 0 $'## 目的\nx\n## 変更点\ny\nhttps://gyazo.com/abc' > "$d/prs.json"
echo '[{"state":"MERGED"},{"state":"CLOSED"}]' > "$d/dependabot.json"
echo "${today}T00:00:00Z" > "$d/release"
echo "${today}T00:00:00Z" > "$d/commits/CHANGELOG.md"
echo "${today}T00:00:00Z" > "$d/commits/docs__decisions"
echo "[{\"conclusion\":\"success\",\"createdAt\":\"${today}T00:00:00Z\"}]" > "$d/runs.json"

out=$(REPOS="o/good" bash "$target"); rc=$?
check "exit 0" "0" "$rc"
for id in issue-template-exists pr-template-exists dependabot-config changelog-exists adr-exists scheduled-freshness pr-visual-evidence; do
  check "全部使っているリポ: $id" "1/1" "$(field "$out" "$id" installed)/$(field "$out" "$id" used)"
done

# --- 設置していないリポは母数に入らない ---
mkrepo o/bare
out=$(REPOS="o/good o/bare" bash "$target")
check "未設置のリポは installed に数えない" "1" "$(field "$out" issue-template-exists installed)"
check "PR が 0 件のリポは pr-visual-evidence の対象外" "1" "$(field "$out" pr-visual-evidence installed)"

# --- 設置したが使われていない ---
mkrepo o/unused
cp "$GH_STUB_DIR/o__good/tree" "$d/tree"
cp -R "$GH_STUB_DIR/o__good/contents/." "$d/contents/"
bodies 0 5 "" > "$d/issues.json"
bodies 0 5 "" > "$d/prs.json"
echo '[{"state":"CLOSED"}]' > "$d/dependabot.json"
echo "${today}T00:00:00Z" > "$d/release"
echo "${old}T00:00:00Z" > "$d/commits/CHANGELOG.md"
echo "${old}T00:00:00Z" > "$d/commits/docs__decisions"
echo "[{\"conclusion\":\"failure\",\"createdAt\":\"${today}T00:00:00Z\"}]" > "$d/runs.json"
out=$(REPOS="o/unused" bash "$target")
for id in issue-template-exists pr-template-exists dependabot-config changelog-exists adr-exists scheduled-freshness pr-visual-evidence; do
  check "設置したが使われていない: $id" "1/0" "$(field "$out" "$id" installed)/$(field "$out" "$id" used)"
done

# --- 境界値: 使用が 1/3 ちょうどは「使われている」、下回れば「使われていない」 ---
mkrepo o/third
printf '.github/pull_request_template.md\n' > "$d/tree"
printf '## 目的\n\n## 変更点\n' > "$d/contents/.github__pull_request_template.md"
bodies 1 2 $'## 目的\nx\n## 変更点\ny' > "$d/prs.json"
out=$(REPOS="o/third" bash "$target" pr-template-exists)
check "1/3 ちょうどは used" "1" "$(field "$out" pr-template-exists used)"
bodies 1 3 $'## 目的\nx\n## 変更点\ny' > "$d/prs.json"
out=$(REPOS="o/third" bash "$target" pr-template-exists)
check "1/4 は unused" "0" "$(field "$out" pr-template-exists used)"

# --- 境界値: bot の PR は母数から外す ---
jq -c '. + [range(10) | {body: "bump", author: {is_bot: true}}]' <<<"$(bodies 1 2 $'## 目的\nx\n## 変更点\ny')" > "$d/prs.json"
out=$(REPOS="o/third" bash "$target" pr-template-exists)
check "bot の PR を足しても判定は変わらない" "1" "$(field "$out" pr-template-exists used)"

# --- 境界値: テンプレートはあるが Issue が 0 件 ---
mkrepo o/quiet
printf '.github/ISSUE_TEMPLATE/bug.md\n' > "$d/tree"
printf '## 再現手順\n\n## 期待する動作\n' > "$d/contents/.github__ISSUE_TEMPLATE__bug.md"
out=$(REPOS="o/quiet" bash "$target" issue-template-exists)
check "Issue 0 件は設置済み・未使用" "1/0" "$(field "$out" issue-template-exists installed)/$(field "$out" issue-template-exists used)"

# --- 失敗系: gh が失敗するリポは skipped に数え、測定全体は止めない ---
out=$(REPOS="o/good o/does-not-exist" bash "$target"); rc=$?
check "gh が失敗しても exit 0" "0" "$rc"
check "失敗したリポは skipped" "1" "$(field "$out" adr-exists skipped)"
check "他のリポの集計は続く" "1" "$(field "$out" adr-exists used)"

# --- 失敗系: リリースの無いリポの CHANGELOG は対象外 (監査側の skip と同じ) ---
rm "$GH_STUB_DIR/o__good/release"
out=$(REPOS="o/good" bash "$target" changelog-exists)
check "リリースが無ければ changelog-exists は対象外" "0" "$(field "$out" changelog-exists installed)"

# --- 正本が when.visibility で絞っている項目は、合わないリポを母数に入れない ---
# 絞ったあとの再測定が、絞る前と同じ母数で測られないようにする。REPOS は <owner/repo>:<可視性> で渡せる
echo "${today}T00:00:00Z" > "$GH_STUB_DIR/o__good/release"
printf '{"items":[{"id":"issue-template-exists","when":{"visibility":"public"}},{"id":"adr-exists"}]}' > "$sandbox/manifest.json"
out=$(REPO_STANDARDS_JSON="$sandbox/manifest.json" REPOS="o/good:private" bash "$target" issue-template-exists adr-exists)
check "public 限定の項目は private リポを母数に入れない" "0" "$(field "$out" issue-template-exists installed)"
check "when を持たない項目は可視性を問わない" "1" "$(field "$out" adr-exists installed)"
out=$(REPO_STANDARDS_JSON="$sandbox/manifest.json" REPOS="o/good:public" bash "$target" issue-template-exists)
check "public 限定の項目は public リポを数える" "1" "$(field "$out" issue-template-exists installed)"
out=$(REPO_STANDARDS_JSON="$sandbox/manifest.json" REPOS="o/good" bash "$target" issue-template-exists)
check "可視性が分からないリポは外さない (境界値)" "1" "$(field "$out" issue-template-exists installed)"

# --- 失敗系: 測り方を持たない項目 ---
REPOS="o/good" bash "$target" gh-squash-only >/dev/null 2>&1
check "測り方を持たない項目は exit 2" "2" "$?"

# --- detail にはリポ名の末尾だけが入る (owner を含めない) ---
out=$(REPOS="o/good" bash "$target" adr-exists)
check "detail はリポ名 + ○× + 内訳" "good ○ 1 本 / 最終 $today" "$(field "$out" adr-exists detail)"

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK"
