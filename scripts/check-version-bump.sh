#!/usr/bin/env bash
# plugins/<name>/ に差分がある PR の version bump を検査する。要 jq。
# 比較先は $BASE_REF (既定 origin/main)。version の正は plugin.json のみ。
#
# 期待増分の決定 (CI では ci.yml が PR_TITLE / PR_LABELS を渡す):
#   1. release:major|minor|patch|skip ラベル → その増分で上書き (skip は bump 不要)。
#      major はこのラベルでのみ宣言できる (自動判定しない。metaphor と同じ規約)
#   2. ラベルなし → PR タイトルの type から導出: feat → minor / fix → patch。
#      それ以外の type で plugins/** を触る PR は NG (本文 = 製品のため feat/fix に限定)
#   3. PR_TITLE 未設定 (ローカル実行) → 「bump されていること」のみ検査
#
# 注意: version を bump しないマージは他マシンへ伝搬しない (クライアントは
# version 比較で更新判定する)。release:skip はそれを理解した上で使うこと。
set -euo pipefail
cd "$(dirname "$0")/.."

base="${BASE_REF:-origin/main}"
title="${PR_TITLE:-}"
labels_json="${PR_LABELS:-[]}"

git rev-parse --verify -q "$base^{commit}" >/dev/null \
  || { echo "NG: 比較先 $base が解決できない (fetch 済みか確認)" >&2; exit 1; }

# 期待増分: major|minor|patch|skip / any (タイトル情報なし) / invalid-type
expected=any
label_bump=""
for l in major minor patch skip; do
  if jq -e --arg l "release:$l" 'index($l)' <<<"$labels_json" >/dev/null; then
    label_bump="$l"
    break
  fi
done
if [ -n "$label_bump" ]; then
  expected="$label_bump"
elif [ -n "$title" ]; then
  title_type=$(sed -nE 's/^([a-z]+)(\([^)]*\))?!?:.*/\1/p' <<<"$title")
  case "$title_type" in
    feat) expected=minor ;;
    fix)  expected=patch ;;
    *)    expected=invalid-type ;;
  esac
fi

bump() { # $1=version $2=major|minor|patch
  local ma mi pa
  IFS=. read -r ma mi pa <<<"$1"
  case "$2" in
    major) echo "$((ma+1)).0.0" ;;
    minor) echo "$ma.$((mi+1)).0" ;;
    patch) echo "$ma.$mi.$((pa+1))" ;;
  esac
}

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

  case "$expected" in
    invalid-type)
      echo "NG: plugins/$name を変更する PR の type は feat / fix に限定 (現タイトル:「${title}」)。例外は release:major|minor|patch|skip ラベルで宣言する" >&2
      fail=1
      ;;
    skip)
      if [ "$head_ver" = "$base_ver" ]; then
        echo "OK: $name は release:skip (version $base_ver のまま。次の bump まで他マシンへ伝搬しない)"
      else
        echo "NG: release:skip なのに $name の version が変更されている ($base_ver -> $head_ver)" >&2
        fail=1
      fi
      ;;
    major|minor|patch)
      want=$(bump "$base_ver" "$expected")
      if [ "$head_ver" = "$want" ]; then
        echo "OK: $name $base_ver -> $head_ver ($expected)"
      else
        echo "NG: $name の期待 version は $want ($expected bump) だが $head_ver になっている (scripts/bump-version.sh $name $expected で修正)" >&2
        fail=1
      fi
      ;;
    any)
      if [ "$head_ver" = "$base_ver" ]; then
        echo "NG: plugins/$name に差分があるのに version が $base_ver のまま (scripts/bump-version.sh $name <major|minor|patch>)" >&2
        fail=1
      else
        echo "OK: $name $base_ver -> $head_ver"
      fi
      ;;
  esac
done

[ "$changed" -eq 0 ] && echo "OK: プラグイン差分なし"
[ "$fail" -eq 0 ] && echo "OK: version-bump"
exit "$fail"
