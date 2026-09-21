#!/usr/bin/env bash
# setup リポの意図の台帳 (claude/intents.json) と、このリポが供給する手段の突き合わせ。要 jq、
# 台帳を取りに行くときは要 gh (認証済み or GH_TOKEN)。
#
# 台帳は「Claude まわりで何をしたいか」の正本で、このリポのフックとスキルはその手段として
# `plugin-self` の ref (`repo-standards@shinyaoguri#hooks/scripts/plan-gate.sh`) で載っている。
# 本体が更新されるたびに、台帳に載った手段は「まだ要るか」を問われる。載っていない手段は
# 問われないまま残るので、両方向を見る (ADR 0027):
#
#   手段 → 台帳   hooks.json の全 command と skills/* が、どれかの意図の手段として載っている
#   台帳 → 手段   台帳が指す plugin-self の ref の実体が、このリポに在る
#
# **PR CI では流さない。週次の freshness だけ。** フックを足す PR は台帳が未更新なので赤くなり、
# 台帳へ先に ref を足す PR は実体が無いので赤くなる — 2 つのリポの PR が互いを待って詰まる
# (跨ぎの契約を PR CI に置いて踏んだ ADR 0022 と同じ形)。
#
# 台帳の在処: $INTENTS_JSON (ファイル。テストと手元の確認用) → 無ければ gh で setup の
# default branch から取る。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

ledger_repo=shinyaoguri/setup
ledger_path=claude/intents.json
fail=0

marketplace=$(jq -r '.name' .claude-plugin/marketplace.json)

if [ -n "${INTENTS_JSON:-}" ]; then
  if ! ledger=$(cat "$INTENTS_JSON" 2>/dev/null); then
    echo "NG: 台帳 $INTENTS_JSON を読めない" >&2
    exit 1
  fi
elif ! ledger=$(gh api "repos/$ledger_repo/contents/$ledger_path" -H 'Accept: application/vnd.github.raw' 2>/dev/null); then
  echo "NG: $ledger_repo の $ledger_path を取得できない (リネーム/削除/権限を確認)" >&2
  exit 1
fi

# 台帳が指すこの marketplace の手段。`#` の無い ref (プラグインそのもの) は単位が違うので外す
if ! declared=$(jq -r --arg m "@$marketplace#" '
    [.intents[].means[] | select(.kind == "plugin-self") | .ref | select(contains($m))] | unique[]
  ' <<<"$ledger" 2>/dev/null); then
  echo "NG: 台帳を読めない (intents[].means[] の形が変わった可能性)" >&2
  exit 1
fi

# このリポが実際に供給している手段。フックは hooks.json の command から (登録されていない
# スクリプトは発火しないので手段ではない)、スキルは skills/ 直下のディレクトリから
supplied=$(
  for plugin_dir in plugins/*/; do
    plugin=$(basename "$plugin_dir")
    if [ -f "$plugin_dir/hooks/hooks.json" ]; then
      # shellcheck disable=SC2016  # jq のフィルタ。シェルに展開させない
      jq -r '.hooks[][]?.hooks[]?.command // empty' "$plugin_dir/hooks/hooks.json" |
        sed -E 's#^"?\$\{CLAUDE_PLUGIN_ROOT\}"?/##; s#[[:space:]].*$##' |
        while IFS= read -r path; do
          [ -n "$path" ] && printf '%s@%s#%s\n' "$plugin" "$marketplace" "$path"
        done
    fi
    for skill_dir in "$plugin_dir"skills/*/; do
      [ -f "$skill_dir/SKILL.md" ] && printf '%s@%s#skills/%s\n' "$plugin" "$marketplace" "$(basename "$skill_dir")"
    done
  done | sort -u
)

if [ -z "$supplied" ]; then
  echo "NG: 供給している手段を 1 つも拾えなかった (hooks.json / skills の走査が壊れている)" >&2
  exit 1
fi

while IFS= read -r ref; do
  [ -z "$ref" ] && continue
  if ! grep -qxF "$ref" <<<"$declared"; then
    echo "NG: $ref が台帳のどの意図の手段にも載っていない ($ledger_repo の $ledger_path に、何をしたくて在るのかと sunset を書く)" >&2
    fail=1
  fi
done <<<"$supplied"

while IFS= read -r ref; do
  [ -z "$ref" ] && continue
  if ! grep -qxF "$ref" <<<"$supplied"; then
    echo "NG: 台帳が指す $ref の実体がこのリポに無い (撤去・改名したなら $ledger_repo の $ledger_path を直す)" >&2
    fail=1
  fi
done <<<"$declared"

[ "$fail" -eq 0 ] && echo "OK: intent coverage ($(wc -l <<<"$supplied" | tr -d ' ') 件)"
exit "$fail"
