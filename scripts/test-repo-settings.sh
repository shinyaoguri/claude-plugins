#!/usr/bin/env bash
# apply-repo-settings.sh の差分検出テスト。
# 実 API を叩かないよう、現状を $REPO_SETTINGS_CURRENT_JSON / $REPO_RULESETS_JSON /
# $REPO_RULESET_DETAIL_JSON で注入して --check の結果を検証する。
#
#   bash scripts/test-repo-settings.sh
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
target="$repo_root/scripts/apply-repo-settings.sh"
def="$repo_root/.github/repo-settings.json"

failures=0

# 定義どおりの現状を組み立てる (実際の API は他のキーも返すが、定義キーだけ見る)
current_ok=$(jq -c '.repo' "$def")
ruleset_ok=$(jq -c '.ruleset' "$def")
rulesets_ok=$(jq -c '[.ruleset | {id: 1, name: .name}]' "$def")

# assert <期待 exit> <ケース名> <repo の現状> <rulesets 一覧> <ruleset 詳細>
assert() {
  local want=$1 name=$2 cur=$3 list=$4 detail=$5
  local out got
  # リポ名も注入する。gh repo view に落とすと CI (認証なし) で実 API を叩いて落ちる
  out=$( cd "$repo_root" && REPO_SETTINGS_REPO="owner/repo" \
    REPO_SETTINGS_CURRENT_JSON="$cur" REPO_RULESETS_JSON="$list" \
    REPO_RULESET_DETAIL_JSON="$detail" bash "$target" 2>&1 )
  got=$?

  if [ "$got" = "$want" ]; then
    echo "  [ok]   $name → exit $got"
  else
    echo "  [FAIL] $name → 期待 exit $want / 実際 $got"
    sed 's/^/         | /' <<<"$out"
    failures=$((failures + 1))
  fi
}

echo "apply-repo-settings --check:"

# 差分なし
assert 0 "定義どおり" "$current_ok" "$rulesets_ok" "$ruleset_ok"

# repo 設定のドリフト (手で設定を変えられた)。定義の値を反転させて作るので、
# 定義側の値が変わってもこのケースは壊れない
assert 1 "repo 設定が違う" \
  "$(jq -c '.has_wiki = (.has_wiki | not)' <<<"$current_ok")" "$rulesets_ok" "$ruleset_ok"

# 定義したキーが現状に無い (API のレスポンスに含まれない)
assert 1 "repo 設定のキーが欠けている" \
  "$(jq -c 'del(.allow_auto_merge)' <<<"$current_ok")" "$rulesets_ok" "$ruleset_ok"

# ruleset ごと消された
assert 1 "ruleset が存在しない" "$current_ok" "[]" "$ruleset_ok"

# ruleset の enforcement が下げられた (active → evaluate)
assert 1 "ruleset が無効化された" "$current_ok" "$rulesets_ok" \
  "$(jq -c '.enforcement = "evaluate"' <<<"$ruleset_ok")"

# 守りのルールが 1 つ外された
assert 1 "ruleset の rule が減った" "$current_ok" "$rulesets_ok" \
  "$(jq -c '.rules |= map(select(.type != "non_fast_forward"))' <<<"$ruleset_ok")"

# bypass_actors に誰かが追加された (保護を素通しできる状態)
assert 1 "bypass_actors が追加された" "$current_ok" "$rulesets_ok" \
  "$(jq -c '.bypass_actors = [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}]' <<<"$ruleset_ok")"

# 必須チェックが外された
assert 1 "必須チェックが減った" "$current_ok" "$rulesets_ok" \
  "$(jq -c '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) |= [.[0]]' <<<"$ruleset_ok")"

# rules の順序違いは差分としない (API は順序を保証しない)
assert 0 "rules の順序が違うだけ" "$current_ok" "$rulesets_ok" \
  "$(jq -c '.rules |= reverse' <<<"$ruleset_ok")"

# ruleset が読めない環境ではゲートにしない (トークン権限は環境で違う)
assert 0 "ruleset を読めない" "$current_ok" "" "$ruleset_ok"

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK"
