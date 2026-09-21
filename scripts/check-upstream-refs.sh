#!/usr/bin/env bash
# 上流リポ参照 (upstream-refs.json) の実在検査。要 jq と gh (認証済み or GH_TOKEN)。
#
# upstream-refs.json の各エントリが上流リポの default branch に実在するかを見る
# (週次 freshness 用)。上流のリネーム・削除ドリフトを検知する。
# プラグイン本文のトークンとマニフェストを突き合わせる --coverage は撤去した (ADR 0028)。
#
# エントリの書式: "path" = 完全一致 / "dir/" = プレフィックス一致 / "*" を含む = glob パターン
set -euo pipefail
cd "$(dirname "$0")/.."

manifest=upstream-refs.json
fail=0

# $1=エントリ $2=ツリー内パス
match() {
  case "$1" in
    *\**) [[ "$2" == $1 ]] ;;
    */)   [[ "$2" == "$1"* ]] ;;
    *)    [ "$2" = "$1" ] ;;
  esac
}

exists() {
  local repo default tree entry hit p
  for repo in $(jq -r 'keys[]' "$manifest"); do
    if ! default=$(gh api "repos/$repo" --jq .default_branch 2>/dev/null); then
      echo "NG: 上流リポ $repo にアクセスできない (リネーム/削除/権限を確認)" >&2
      fail=1
      continue
    fi
    if ! tree=$(gh api "repos/$repo/git/trees/$default?recursive=1" --jq '.tree[].path' 2>/dev/null); then
      echo "NG: $repo の $default ブランチのツリーを取得できない" >&2
      fail=1
      continue
    fi
    while IFS= read -r entry; do
      hit=0
      while IFS= read -r p; do
        if match "$entry" "$p"; then hit=1; break; fi
      done <<<"$tree"
      if [ "$hit" -eq 0 ]; then
        echo "NG: $repo に「${entry}」が見つからない (上流でリネーム/削除された可能性。参照元プラグインと $manifest を更新する)" >&2
        fail=1
      fi
    done < <(jq -r --arg r "$repo" '.[$r][]' "$manifest")
    echo "checked: $repo@$default"
  done
  [ "$fail" -eq 0 ] && echo "OK: exists"
}

# 旧 CI や手元の癖で渡される --exists は受け付ける (唯一のモードなので意味は変わらない)
case "${1:---exists}" in
  --exists) exists ;;
  *) echo "usage: $0 [--exists]" >&2; exit 2 ;;
esac
exit "$fail"
