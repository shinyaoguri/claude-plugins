#!/usr/bin/env bash
# marketplace.json ↔ plugins/*/plugin.json ↔ README のプラグイン表の整合検査。
# CI (ci.yml) とローカルで共用。要 jq。
set -euo pipefail
cd "$(dirname "$0")/.."

mp=.claude-plugin/marketplace.json
fail=0
err() { echo "NG: $*" >&2; fail=1; }

jq -e . "$mp" >/dev/null || { echo "NG: $mp が JSON として不正" >&2; exit 1; }

# version の正は plugin.json のみ。marketplace.json に書くと plugin.json が
# 無警告で優先されるため公式非推奨 (二重管理の再発をここで止める)
jq -e '[.plugins[] | select(has("version"))] | length == 0' "$mp" >/dev/null \
  || err "marketplace.json のエントリに version がある (version は plugin.json のみに書く)"

# marketplace 登録エントリ → 実体との一致
while IFS=$'\t' read -r name source; do
  dir="${source#./}"
  pj="$dir/.claude-plugin/plugin.json"
  if [ ! -f "$pj" ]; then
    err "$name: $pj が無い"
    continue
  fi
  pj_name=$(jq -r .name "$pj")
  [ "$pj_name" = "$name" ] || err "$name: plugin.json の name ($pj_name) が marketplace.json と不一致"
  grep -q "plugins/$name" README.md || err "$name: README.md のプラグイン表に載っていない"

  # keywords は両方に書ける (version と違い優先順位が公式に定義されていない)。
  # どちらが読まれても同じになるよう一致を強制し、二重管理のずれをここで止める
  mp_kw=$(jq -cS --arg n "$name" '.plugins[] | select(.name == $n) | .keywords // []' "$mp")
  pj_kw=$(jq -cS '.keywords // []' "$pj")
  [ "$mp_kw" = "$pj_kw" ] \
    || err "$name: keywords が marketplace.json ($mp_kw) と plugin.json ($pj_kw) で不一致"
done < <(jq -r '.plugins[] | [.name, .source] | @tsv' "$mp")

# テストスクリプト → CI への登録漏れ。書いても呼ばれなければ無いのと同じで、
# 退行は誰かが手で回すまで分からない (実際 test-guardrail-weakening.sh が漏れていた)
for t in scripts/test-*.sh; do
  grep -qrF -- "$t" .github/workflows/ || err "$t が .github/workflows/ のどこからも実行されていない"
done

# plugins/ 直下のディレクトリ → marketplace への登録漏れ
for d in plugins/*/; do
  name=$(basename "$d")
  jq -e --arg n "$name" '.plugins[] | select(.name == $n)' "$mp" >/dev/null \
    || err "plugins/$name が marketplace.json に未登録"
done

[ "$fail" -eq 0 ] && echo "OK: consistency"
exit "$fail"
