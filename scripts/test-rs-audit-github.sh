#!/usr/bin/env bash
# repo-standards プラグインの rs-audit-github.sh の判定テスト。
# 実際の gh 認証・API に依存しないよう、PATH 先頭に fake gh を置いて応答を注入する。
# 関数を source せずエンドツーエンドで見るのは、正本との契約 (出力スキーマ) ごと守るため。
#
#   bash scripts/test-rs-audit-github.sh
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
target="$repo_root/plugins/repo-standards/scripts/rs-audit-github.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

failures=0

# 1 項目だけの最小 manifest。gh-required-checks は builtin 判定
manifest="$tmp/standards.json"
cat > "$manifest" <<'EOF'
{
  "version": 1,
  "kinds": [{ "id": "generic", "marker": null }],
  "items": [
    {
      "id": "gh-required-checks",
      "layer": "github",
      "level": "required",
      "applies_to": ["all"],
      "check": { "type": "builtin", "name": "required_checks_configured" },
      "why": "テスト用",
      "fix": "テスト用"
    }
  ]
}
EOF

# fake gh: 応答は $FAKE_GH_DIR のファイルで定義する。
#   api <endpoint>       → $FAKE_GH_DIR/<endpoint の / を _ に>.json (無ければ exit 1)
#   --jq EXPR            → 応答ファイルに jq -r を適用
#   auth status          → $FAKE_GH_AUTH_EXIT (既定 0)
bin="$tmp/bin"
mkdir -p "$bin"
cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
cmd=${1:-}; shift || true
case "$cmd" in
  auth) exit "${FAKE_GH_AUTH_EXIT:-0}" ;;
  repo) echo "tester/dummy" ;;
  api)
    endpoint="" jqexpr=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --jq) jqexpr=$2; shift 2 ;;
        -*) shift ;;
        *) endpoint=$1; shift ;;
      esac
    done
    f="$FAKE_GH_DIR/$(printf '%s' "$endpoint" | tr '/' '_').json"
    [ -f "$f" ] || exit 1
    if [ -n "$jqexpr" ]; then jq -r "$jqexpr" "$f"; else cat "$f"; fi
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$bin/gh"

# 共通の API 応答 (public / main / 非アーカイブ、ruleset 無し、classic protection 無し)
gh_dir="$tmp/gh-responses"
mkdir -p "$gh_dir"
cat > "$gh_dir/repos_tester_dummy.json" <<'EOF'
{ "private": false, "default_branch": "main", "archived": false }
EOF
echo '[]' > "$gh_dir/repos_tester_dummy_rulesets.json"

# run <dir> [env VAR=VAL ...] → 対象スクリプトの出力
run() {
  local dir=$1; shift
  ( cd "$dir" && PATH="$bin:$PATH" FAKE_GH_DIR="$gh_dir" \
    REPO_STANDARDS_JSON="$manifest" "$@" bash "$target" )
}

# assert_eq <期待> <実際> <ケース名>
assert_eq() {
  local want=$1 got=$2 name=$3
  if [ "$got" = "$want" ]; then
    echo "  [ok]   $name → $got"
  else
    echo "  [FAIL] $name → 期待 $want / 実際 $got"
    failures=$((failures + 1))
  fi
}

echo "builtin_required_checks_configured:"

# .yml の workflow がある通常ケース: ruleset も classic も無いので ng
dir="$tmp/case-yml"
mkdir -p "$dir/.github/workflows"
git init -q -b main "$dir"
touch "$dir/.github/workflows/ci.yml"
assert_eq ng "$(run "$dir" env | jq -r 'select(.id == "gh-required-checks") | .status')" \
  ".yml の workflow → 保護なしなら ng"

# .yaml のみの workflow でも「CI 無し」扱い (skip) にしない (#34 で塞いだ穴)
dir="$tmp/case-yaml"
mkdir -p "$dir/.github/workflows"
git init -q -b main "$dir"
touch "$dir/.github/workflows/ci.yaml"
assert_eq ng "$(run "$dir" env | jq -r 'select(.id == "gh-required-checks") | .status')" \
  ".yaml のみの workflow でも判定する"

# workflow が無ければ対象外
dir="$tmp/case-none"
git init -q -b main "$dir"
assert_eq skip "$(run "$dir" env | jq -r 'select(.id == "gh-required-checks") | .status')" \
  "workflow が無ければ skip"

echo
echo "前提不足時の skip_all:"

# gh 未認証: 全項目 skip でも _meta 行を出す (レポートのヘッダ材料)
dir="$tmp/case-noauth"
git init -q -b main "$dir"
out=$(run "$dir" env FAKE_GH_AUTH_EXIT=1)
assert_eq skip "$(jq -r 'select(.id == "gh-required-checks") | .status' <<<"$out")" \
  "未認証なら項目は skip"
assert_eq github "$(jq -r 'select(.id == "_meta") | .layer' <<<"$out")" \
  "未認証でも _meta 行がある"

echo
echo "出力契約 (status は ok/ng/warn/skip/manual のみ):"
dir="$tmp/case-contract"
git init -q -b main "$dir"
bad=$(run "$dir" env | jq -r 'select(.id != "_meta") | .status' \
  | grep -cvE '^(ok|ng|warn|skip|manual)$' || true)
assert_eq 0 "$bad" "契約外の status が無い"

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK"
