#!/usr/bin/env bash
# マーカー付き PR コメントを 1 件へ収束させる (upsert)。CI の guardrail ジョブ用。要 gh。
#
#   MARKER='<!-- x -->' PR=12 REPO=owner/name ./scripts/upsert-pr-comment.sh body.md [--update-only]
#
# 既存のマーカー付きコメントがあれば最古の 1 件を body.md で更新し、残り (並行実行で
# 二重投稿された分) を削除する。無ければ新規投稿する。--update-only なら投稿しない。
#
# 「初回だけ投稿する」方式だと (a) 後の push で検出内容が変わってもコメントが古いまま
# 残り、(b) 同一 PR で run が並行すると check-then-act がすり抜けて重複する (Issue #63)。
# 毎回 upsert すれば、何本走っても結果は最新内容の 1 件に収束する。
set -euo pipefail

body_file="${1:?body ファイルを指定する}"
mode="${2:-}"
: "${MARKER:?MARKER が必要}" "${PR:?PR が必要}" "${REPO:?REPO が必要}"

# 対象コメントの id (古い順。GitHub の issue comments は作成順に返る)
ids=$(gh api "repos/$REPO/issues/$PR/comments" --paginate \
  --jq '.[] | select(.body | contains(env.MARKER)) | .id')

first=$(printf '%s\n' "$ids" | sed -n '1p')

if [ -z "$first" ]; then
  if [ "$mode" = "--update-only" ]; then
    echo "マーカー付きコメントが無いので何もしない"
    exit 0
  fi
  gh pr comment "$PR" --repo "$REPO" --body-file "$body_file"
  exit 0
fi

gh api --method PATCH "repos/$REPO/issues/comments/$first" -F "body=@$body_file" --silent
echo "コメント $first を更新した"

printf '%s\n' "$ids" | sed -n '2,$p' | while IFS= read -r id; do
  [ -n "$id" ] || continue
  gh api --method DELETE "repos/$REPO/issues/comments/$id" --silent
  echo "重複コメント $id を削除した"
done
