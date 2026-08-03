#!/usr/bin/env bash
# 上流リポ参照 (upstream-refs.json) の検査。要 jq、--exists は要 gh (認証済み or GH_TOKEN)。
#
#   --coverage : plugins/**/*.md から上流パス風トークンを抽出し、全トークンが
#                upstream-refs.json のいずれかのエントリに含まれるか検査 (PR CI 用)。
#                プラグイン本文に新しい上流参照を書いたのにマニフェスト追記を忘れる事故を防ぐ。
#   --exists   : upstream-refs.json の各エントリが上流リポの default branch に
#                実在するか検査 (週次 freshness 用)。上流のリネーム・削除ドリフトを検知する。
#
# エントリの書式: "path" = 完全一致 / "dir/" = プレフィックス一致 / "*" を含む = glob パターン
set -euo pipefail
cd "$(dirname "$0")/.."

manifest=upstream-refs.json
mode="${1:---coverage}"
fail=0

# 上流ドキュメント・実装ファイルを指す典型トークン。プラグインの語彙が増えたらここも育てる
token_re='(CONTRACT\.md|AGENTS\.md|DEVELOPMENT\.md|CLAUDE\.md|llms[a-z-]*\.txt|examples-index\.(md|json)|docs/ai/[A-Za-z0-9._/-]+|docs/[a-z-]+\.md|scripts/[A-Za-z0-9_-]+\.sh|check-contract[a-z-]*\.sh|[A-Za-z][A-Za-z0-9]*\.swift|[a-z.-]+\.schema\.json|templates\.json|syphon-bump\.yml|ShaderSources|Shaders/Metal)'
# metaphor new が各プロジェクトに生成するファイル等、上流リポの実体ではないトークンと、
# プラグイン同梱スクリプト (rs- プレフィックス。repo-standards の ${CLAUDE_PLUGIN_ROOT}/scripts/)
ignore_re='^(PROJECT_BRIEF\.md|App\.swift|scripts/rs-[a-z-]+\.sh)$'

coverage() {
  local entries tokens t hit e
  entries=$(jq -r '.[] | .[]' "$manifest")
  tokens=$(grep -rhoE "$token_re" plugins --include='*.md' | sort -u)
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    [[ "$t" =~ $ignore_re ]] && continue
    hit=0
    while IFS= read -r e; do
      case "$e" in *"$t"*) hit=1; break ;; esac
    done <<<"$entries"
    if [ "$hit" -eq 0 ]; then
      echo "NG: プラグイン本文が参照する「${t}」が $manifest に無い (該当箇所: $(grep -rlE "$token_re" plugins --include='*.md' | xargs grep -l "$t" | paste -sd, -))" >&2
      fail=1
    fi
  done <<<"$tokens"
  [ "$fail" -eq 0 ] && echo "OK: coverage ($(wc -l <<<"$tokens" | tr -d ' ') トークン検査)"
}

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

case "$mode" in
  --coverage) coverage ;;
  --exists)   exists ;;
  *) echo "usage: $0 [--coverage|--exists]" >&2; exit 2 ;;
esac
exit "$fail"
