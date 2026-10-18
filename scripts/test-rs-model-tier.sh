#!/usr/bin/env bash
# model-tier.sh の分岐テスト。
# hook の契約 (終了コード・stdout の additionalContext・セッション単位の印) をそのまま検証する
# (Claude セッションには触らない。印は砂場へ向ける)。
#
#   bash scripts/test-rs-model-tier.sh
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
hook="$repo_root/plugins/repo-standards/hooks/scripts/model-tier.sh"

failures=0

# check <ケース名> <期待> <実際>
check() {
  if [ "$2" = "$3" ]; then
    echo "  [ok]   $1 → $3"
  else
    echo "  [FAIL] $1 → 期待 $2 / 実際 $3"
    failures=$((failures + 1))
  fi
}

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
export RS_MODEL_TIER_DIR="$sandbox/model-tier"
mark="$RS_MODEL_TIER_DIR/s1.tier"

# start <model|-> — SessionStart を叩いて stdout を返す (- は model を省く)
start() {
  if [ "$1" = "-" ]; then
    printf '{"session_id":"s1","hook_event_name":"SessionStart","source":"startup"}' | bash "$hook"
  else
    printf '{"session_id":"s1","hook_event_name":"SessionStart","source":"startup","model":"%s"}' "$1" | bash "$hook"
  fi
}

# switch <to_model> — PostModelSwitch を叩いて stdout を返す
switch() {
  printf '{"session_id":"s1","hook_event_name":"PostModelSwitch","from_model":"x","to_model":"%s"}' "$1" | bash "$hook"
}

tier_of_mark() { [ -f "$mark" ] && head -n 1 "$mark" || echo none; }

# 注入された文脈の格の名乗り (無出力なら none)
label_of() {
  if [ -z "$1" ]; then echo none; return; fi
  printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext' | grep -oE '格は「[^」]+」' | head -1
}

echo "== SessionStart: 格の判定と注入 =="

out=$(start claude-sonnet-5-5)
check "sonnet → 中を注入" '格は「中」' "$(label_of "$out")"
check "sonnet → 印は mid" mid "$(tier_of_mark)"
check "hookEventName" SessionStart "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')"
check "出口 (上位モデルへの委譲) を書いている" yes \
  "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'model: "opus"' && echo yes || echo no)"
check "出口 (限界報告) を書いている" yes \
  "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext' | grep -q '限界報告' && echo yes || echo no)"

out=$(start claude-haiku-5-5)
check "haiku → 低を注入" '格は「低」' "$(label_of "$out")"
check "haiku → 印は low" low "$(tier_of_mark)"

out=$(start claude-opus-5-5)
check "opus → 何も出さない" none "$(label_of "$out")"
check "opus → 印は high" high "$(tier_of_mark)"

out=$(start claude-fable-5-1)
check "fable → 何も出さない" none "$(label_of "$out")"
check "fable → 印は high" high "$(tier_of_mark)"

out=$(start Sonnet)
check "大文字の別名 (Sonnet) も中" '格は「中」' "$(label_of "$out")"

start claude-sonnet-5-5 >/dev/null
out=$(start -)
check "model が無い → 何も出さない" none "$(label_of "$out")"
check "model が無い → 前の印を消す" none "$(tier_of_mark)"

out=$(start some-other-model)
check "知らないモデル → 何も出さない" none "$(label_of "$out")"
check "知らないモデル → 印を置かない" none "$(tier_of_mark)"

echo
echo "== PostModelSwitch: 印だけを書き換える =="

start claude-opus-5-5 >/dev/null
out=$(switch claude-sonnet-5-5)
check "opus → sonnet で印が mid に変わる" mid "$(tier_of_mark)"
check "PostModelSwitch では何も出さない" none "$(label_of "$out")"
switch claude-opus-5-5 >/dev/null
check "sonnet → opus で印が high に戻る" high "$(tier_of_mark)"

echo
echo "== 逃げ道と上書き =="

rm -f "$mark"
out=$(RS_MODEL_TIER=0 start claude-sonnet-5-5)
check "RS_MODEL_TIER=0 → 何も出さない" none "$(label_of "$out")"
check "RS_MODEL_TIER=0 → 印を置かない" none "$(tier_of_mark)"
out=$(RS_MODEL_TIER=low start claude-opus-5-5)
check "RS_MODEL_TIER=low はモデルより優先" '格は「低」' "$(label_of "$out")"

echo
echo "== 壊れた入力でも黙って終わる =="
check "session_id が無い" 0 "$(printf '{"model":"claude-sonnet-5-5"}' | bash "$hook" >/dev/null 2>&1; echo $?)"
check "JSON でない" 0 "$(printf 'not json' | bash "$hook" >/dev/null 2>&1; echo $?)"

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "すべて通った"
