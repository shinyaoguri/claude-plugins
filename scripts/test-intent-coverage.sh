#!/usr/bin/env bash
# check-intent-coverage.sh の判定テスト。
# 一時ディレクトリに marketplace.json・hooks.json・skills/ と台帳の最小構成を組み立て、
# 正本のスクリプトをそのまま実行して exit code と指摘の文言を検証する
# (hooks.json からパスを抜く sed と jq ごと守るため、関数を source しない)。
#
#   bash scripts/test-intent-coverage.sh
#
# 台帳は $INTENTS_JSON で渡す。gh で setup から取る経路はネットワークが要るのでここでは
# 検証しない (週次 CI が実挙動)。
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
target="$repo_root/scripts/check-intent-coverage.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

failures=0
seq_no=0

# shellcheck disable=SC2016  # hooks.json に書かれる字面そのもの。シェルに展開させない
HOOKS_TWO='{"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}\"/hooks/scripts/gate.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}\"/hooks/scripts/watch.sh --flag"}]}]}}'
# shellcheck disable=SC2016
HOOKS_ONE='{"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}\"/hooks/scripts/gate.sh"}]}]}}'

# ledger <ref...> : plugin-self の手段として ref を持つ最小の台帳
ledger() {
  local refs
  refs=$(printf '%s\n' "$@" | jq -R '{kind: "plugin-self", ref: .}' | jq -s .)
  jq -n --argjson means "$refs" '{version: 1, intents: [
    {id: "a", means: $means},
    {id: "b", means: [{kind: "self", ref: "claude/x.sh"}, {kind: "plugin-third", ref: "other@elsewhere"}]}
  ]}'
}

# case_run <ケース名> <期待 (ok|ng)> <指摘に含まれるはずの語 (ok なら "")> <hooks.json> <スキル名 (空白区切り)> <台帳の JSON>
case_run() {
  local name=$1 want=$2 expect=$3 hooks=$4 skills=$5 ledger_json=$6
  seq_no=$((seq_no + 1))
  local dir="$tmp/case-$seq_no"

  mkdir -p "$dir/scripts" "$dir/.claude-plugin" "$dir/plugins/sample/hooks"
  # スクリプトは自身の親ディレクトリを作業ディレクトリにするので、コピー先が疑似リポになる
  cp "$target" "$dir/scripts/check-intent-coverage.sh"
  printf '{"name": "mine", "plugins": [{"name": "sample"}]}\n' > "$dir/.claude-plugin/marketplace.json"
  [ -n "$hooks" ] && printf '%s\n' "$hooks" > "$dir/plugins/sample/hooks/hooks.json"
  local skill
  for skill in $skills; do
    mkdir -p "$dir/plugins/sample/skills/$skill"
    : > "$dir/plugins/sample/skills/$skill/SKILL.md"
  done
  printf '%s\n' "$ledger_json" > "$dir/intents.json"

  local out got
  if out=$(INTENTS_JSON="$dir/intents.json" bash "$dir/scripts/check-intent-coverage.sh" 2>&1); then
    got=ok
  else
    got=ng
  fi

  if [ "$got" != "$want" ]; then
    echo "FAIL: $name — 期待 $want / 実際 $got"
    printf '%s\n' "$out" | sed 's/^/      /'
    failures=$((failures + 1))
  elif [ -n "$expect" ] && ! grep -qF -- "$expect" <<<"$out"; then
    # exit code だけで見ると「狙った指摘」と「別の理由の NG」を区別できない
    echo "FAIL: $name — NG にはなったが、指摘に「${expect}」が無い"
    printf '%s\n' "$out" | sed 's/^/      /'
    failures=$((failures + 1))
  else
    echo "ok: $name"
  fi
}

ALL=(sample@mine#hooks/scripts/gate.sh sample@mine#hooks/scripts/watch.sh sample@mine#skills/audit)

case_run "手段と台帳が一致する" ok "" "$HOOKS_TWO" "audit" "$(ledger "${ALL[@]}")"

case_run "command の引数は ref に含めない (watch.sh --flag)" ok "" "$HOOKS_TWO" "audit" "$(ledger "${ALL[@]}")"

case_run "台帳に無いフックを足した" ng "sample@mine#hooks/scripts/watch.sh が台帳の" \
  "$HOOKS_TWO" "audit" "$(ledger sample@mine#hooks/scripts/gate.sh sample@mine#skills/audit)"

case_run "台帳に無いスキルを足した" ng "sample@mine#skills/fresh が台帳の" \
  "$HOOKS_TWO" "audit fresh" "$(ledger "${ALL[@]}")"

case_run "台帳が指すフックを撤去した" ng "台帳が指す sample@mine#hooks/scripts/watch.sh の実体" \
  "$HOOKS_ONE" "audit" "$(ledger "${ALL[@]}")"

case_run "台帳が指すスキルを撤去した" ng "台帳が指す sample@mine#skills/gone の実体" \
  "$HOOKS_TWO" "audit" "$(ledger "${ALL[@]}" sample@mine#skills/gone)"

case_run "登録されていないスクリプトは手段に数えない (hooks.json が正)" ng "台帳が指す sample@mine#hooks/scripts/unregistered.sh の実体" \
  "$HOOKS_TWO" "audit" "$(ledger "${ALL[@]}" sample@mine#hooks/scripts/unregistered.sh)"

case_run "別の marketplace の ref は見ない" ok "" \
  "$HOOKS_TWO" "audit" "$(ledger "${ALL[@]}" sample@elsewhere#skills/unrelated)"

case_run "プラグインそのものを指す ref (# なし) は単位が違うので見ない" ok "" \
  "$HOOKS_TWO" "audit" "$(ledger "${ALL[@]}" sample@mine)"

case_run "SKILL.md の無いディレクトリはスキルに数えない" ok "" \
  "$HOOKS_TWO" "audit" "$(ledger "${ALL[@]}")"
mkdir -p "$tmp/case-$seq_no/plugins/sample/skills/empty-dir"
if ! INTENTS_JSON="$tmp/case-$seq_no/intents.json" bash "$tmp/case-$seq_no/scripts/check-intent-coverage.sh" >/dev/null 2>&1; then
  echo "FAIL: SKILL.md の無いディレクトリを手段として数えた"
  failures=$((failures + 1))
fi

case_run "台帳の形が変わって読めない" ng "台帳を読めない" \
  "$HOOKS_TWO" "audit" '{"version": 2, "goals": []}'

case_run "手段を 1 つも拾えないのは走査の故障として落とす" ng "1 つも拾えなかった" \
  "" "" "$(ledger sample@mine#skills/audit)"

# 台帳のファイルが無い
seq_no=$((seq_no + 1))
if out=$(INTENTS_JSON="$tmp/nowhere.json" bash "$tmp/case-1/scripts/check-intent-coverage.sh" 2>&1); then
  echo "FAIL: 読めない台帳を OK にした"
  failures=$((failures + 1))
elif ! grep -qF "読めない" <<<"$out"; then
  echo "FAIL: 読めない台帳の指摘が出ていない: $out"
  failures=$((failures + 1))
else
  echo "ok: 台帳のファイルが無い"
fi

if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK: $seq_no ケース"
