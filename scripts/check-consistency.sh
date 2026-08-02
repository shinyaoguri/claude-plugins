#!/usr/bin/env bash
# marketplace.json ↔ plugins/*/plugin.json ↔ README のプラグイン表の整合検査。
# CI (ci.yml) とローカルで共用。要 jq。
set -euo pipefail
cd "$(dirname "$0")/.."

mp=.claude-plugin/marketplace.json
fail=0
err() { echo "NG: $*" >&2; fail=1; }

jq -e . "$mp" >/dev/null || { echo "NG: $mp が JSON として不正" >&2; exit 1; }

# marketplace 登録エントリ → 実体との一致
while IFS=$'\t' read -r name source version; do
  dir="${source#./}"
  pj="$dir/.claude-plugin/plugin.json"
  if [ ! -f "$pj" ]; then
    err "$name: $pj が無い"
    continue
  fi
  pj_name=$(jq -r .name "$pj")
  pj_ver=$(jq -r .version "$pj")
  [ "$pj_name" = "$name" ] || err "$name: plugin.json の name ($pj_name) が marketplace.json と不一致"
  [ "$pj_ver" = "$version" ] || err "$name: version 不一致 (plugin.json=$pj_ver / marketplace.json=$version)"
  grep -q "plugins/$name" README.md || err "$name: README.md のプラグイン表に載っていない"
done < <(jq -r '.plugins[] | [.name, .source, .version] | @tsv' "$mp")

# plugins/ 直下のディレクトリ → marketplace への登録漏れ
for d in plugins/*/; do
  name=$(basename "$d")
  jq -e --arg n "$name" '.plugins[] | select(.name == $n)' "$mp" >/dev/null \
    || err "plugins/$name が marketplace.json に未登録"
done

[ "$fail" -eq 0 ] && echo "OK: consistency"
exit "$fail"
