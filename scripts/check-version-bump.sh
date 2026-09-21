#!/usr/bin/env bash
# plugins/<name>/ に差分がある PR で、version が bump されているかを検査する。要 jq。
# 比較先は $BASE_REF (既定 origin/main)。version の正は plugin.json のみ。
#
# version を bump しないマージは他マシンへ伝搬しない (クライアントは version 比較で更新を
# 判定する)。守るのはこの 1 点だけで、増分の大きさ (major / minor / patch) は検査しない —
# 人が scripts/bump-version.sh で選ぶ (ADR 0028。以前は PR タイトルの type と release:*
# ラベルから期待増分を導出して完全一致を強制していた)。
set -euo pipefail
cd "$(dirname "$0")/.."

base="${BASE_REF:-origin/main}"

git rev-parse --verify -q "$base^{commit}" >/dev/null \
  || { echo "NG: 比較先 $base が解決できない (fetch 済みか確認)" >&2; exit 1; }

fail=0
changed=0
for d in plugins/*/; do
  name=$(basename "$d")
  if git diff --quiet "$base" -- "$d"; then
    continue # 差分なし
  fi
  changed=1
  pj="${d}.claude-plugin/plugin.json"
  head_ver=$(jq -r .version "$pj")
  if ! base_pj=$(git show "$base:$pj" 2>/dev/null); then
    echo "OK: $name は新規プラグイン (version $head_ver)"
    continue
  fi
  base_ver=$(jq -r .version <<<"$base_pj")
  if [ "$head_ver" = "$base_ver" ]; then
    echo "NG: plugins/$name に差分があるのに version が $base_ver のまま (scripts/bump-version.sh $name <major|minor|patch>)" >&2
    fail=1
  else
    echo "OK: $name $base_ver -> $head_ver"
  fi
done

[ "$changed" -eq 0 ] && echo "OK: プラグイン差分なし"
[ "$fail" -eq 0 ] && echo "OK: version-bump"
exit "$fail"
