#!/usr/bin/env bash
# リポジトリ構成 (layer: repo) + リポ内 .claude 設定 (layer: claude) の機械判定。
# cwd の git リポジトリを正本 repo-standards.json と突き合わせ、JSON Lines で報告する。
# 出力契約・正本の解決チェーンは rs-lib.sh 冒頭を参照。
set -uo pipefail
. "$(dirname "$0")/rs-lib.sh"

root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  emit not-a-git-repo meta - error "git リポジトリではない (リポジトリ内で実行する)"
  exit 0
}
cd "$root"

manifest=$(resolve_standards) || { emit_manifest_missing; exit 0; }

# リポ種別: marker ファイルが存在する最初の kind。無ければ marker: null の kind
kind="" fallback=""
while IFS=$'\t' read -r kid marker; do
  if [ "$marker" = "__null__" ]; then fallback=$kid; continue; fi
  [ -z "$kind" ] && [ -e "$marker" ] && kind=$kid
done < <(jq -r '.kinds[] | [.id, (.marker // "__null__")] | @tsv' "$manifest")
[ -n "$kind" ] || kind=${fallback:-generic}

jq -cn --arg kind "$kind" --arg root "$root" --arg manifest "$manifest" \
  '{id:"_meta",layer:"repo",kind:$kind,root:$root,manifest:$manifest}'

# ---- builtin 検査 (正本の check.name から呼ばれる) ----

builtin_gitignore_covers_env() { # ok / fail / skip:<理由>
  [ -f .gitignore ] || { echo "skip:.gitignore が無いため判定不能"; return; }
  grep -qE '(^|[/*])\.env' .gitignore && echo ok || echo fail
}

builtin_pr_template_exists() {
  local p
  for p in .github/pull_request_template.md .github/PULL_REQUEST_TEMPLATE.md \
    pull_request_template.md PULL_REQUEST_TEMPLATE.md docs/pull_request_template.md; do
    [ -f "$p" ] && { echo ok; return; }
  done
  echo fail
}

builtin_settings_local_not_committed() {
  if git ls-files --error-unmatch .claude/settings.local.json >/dev/null 2>&1; then
    echo fail
  else
    echo ok
  fi
}

# ---- 項目ループ ----

while IFS= read -r item; do
  id=$(jq -r .id <<<"$item")
  layer=$(jq -r .layer <<<"$item")
  level=$(jq -r .level <<<"$item")
  why=$(jq -r .why <<<"$item")
  fix=$(jq -r '.fix // ""' <<<"$item")
  ctype=$(jq -r .check.type <<<"$item")

  # リポ種別のフィルタ
  if ! jq -e --arg k "$kind" '.applies_to | index("all") or index($k)' >/dev/null <<<"$item"; then
    emit "$id" "$layer" "$level" skip "リポ種別 $kind は対象外"
    continue
  fi

  case "$ctype" in
    file_exists)
      path=$(jq -r .check.path <<<"$item")
      if [ -e "$path" ]; then emit "$id" "$layer" "$level" ok "$path"
      else emit "$id" "$layer" "$level" "$(fail_status "$level")" "$path が無い — $why" "$fix"; fi
      ;;
    file_absent)
      path=$(jq -r .check.path <<<"$item")
      if [ ! -e "$path" ]; then emit "$id" "$layer" "$level" ok "$path は無い (期待どおり)"
      else emit "$id" "$layer" "$level" "$(fail_status "$level")" "$path が存在する — $why" "$fix"; fi
      ;;
    glob_exists)
      pattern=$(jq -r .check.path <<<"$item")
      if compgen -G "$pattern" >/dev/null; then emit "$id" "$layer" "$level" ok "$pattern に一致あり"
      else emit "$id" "$layer" "$level" "$(fail_status "$level")" "$pattern に一致なし — $why" "$fix"; fi
      ;;
    builtin)
      name=$(jq -r .check.name <<<"$item")
      if ! declare -F "builtin_$name" >/dev/null; then
        emit "$id" "$layer" "$level" skip "builtin '$name' はこのスクリプトに未実装 (正本との契約ずれ。プラグイン更新が必要)"
        continue
      fi
      result=$("builtin_$name")
      case "$result" in
        ok) emit "$id" "$layer" "$level" ok "" ;;
        skip:*) emit "$id" "$layer" "$level" skip "${result#skip:}" ;;
        *) emit "$id" "$layer" "$level" "$(fail_status "$level")" "$why" "$fix" ;;
      esac
      ;;
    llm)
      prompt=$(jq -r .check.prompt <<<"$item")
      emit "$id" "$layer" "$level" manual "$prompt" "$fix"
      ;;
    *)
      emit "$id" "$layer" "$level" skip "check.type '$ctype' はこのスクリプトの対象外"
      ;;
  esac
done < <(jq -c '.items[] | select(.layer == "repo" or .layer == "claude")' "$manifest")

exit 0
