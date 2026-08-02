#!/usr/bin/env bash
# plugins/<name>/ に差分がある PR で plugin.json の version bump を強制する。
# 比較先は $BASE_REF (既定 origin/main)。CI (ci.yml の pull_request) とローカルで共用。要 jq。
# version の marketplace.json との同期は check-consistency.sh が検査する。
set -euo pipefail
cd "$(dirname "$0")/.."

base="${BASE_REF:-origin/main}"
git rev-parse --verify -q "$base^{commit}" >/dev/null \
  || { echo "NG: 比較先 $base が解決できない (fetch 済みか確認)" >&2; exit 1; }

fail=0
for d in plugins/*/; do
  name=$(basename "$d")
  if git diff --quiet "$base" -- "$d"; then
    continue # 差分なし
  fi
  pj="${d}.claude-plugin/plugin.json"
  head_ver=$(jq -r .version "$pj")
  base_pj=$(git show "$base:$pj" 2>/dev/null) || {
    echo "OK: $name は新規プラグイン (version $head_ver)"
    continue
  }
  base_ver=$(jq -r .version <<<"$base_pj")
  if [ "$head_ver" = "$base_ver" ]; then
    echo "NG: plugins/$name に差分があるのに version が $base_ver のまま (plugin.json と marketplace.json を同時に bump する)" >&2
    fail=1
  else
    echo "OK: $name $base_ver -> $head_ver"
  fi
done

[ "$fail" -eq 0 ] && echo "OK: version-bump"
exit "$fail"
