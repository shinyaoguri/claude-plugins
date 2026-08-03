#!/usr/bin/env bash
# GitHub リポジトリ設定 (layer: github) の機械判定。gh api で cwd のリポの設定を取得し、
# 正本 repo-standards.json と突き合わせて JSON Lines で報告する。
# gh 不在・未認証・GitHub 外リポでは全項目 skip (層②③の監査は rs-audit-repo.sh が継続する)。
# 出力契約・正本の解決チェーンは rs-lib.sh 冒頭を参照。
set -uo pipefail
. "$(dirname "$0")/rs-lib.sh"

manifest=$(resolve_standards) || { emit_manifest_missing; exit 0; }

# 前提が満たせないとき: layer=github の全項目を同じ理由で skip して正常終了
skip_all() {
  local reason=$1
  while IFS=$'\t' read -r id level; do
    emit "$id" github "$level" skip "$reason"
  done < <(jq -r '.items[] | select(.layer == "github") | [.id, .level] | @tsv' "$manifest")
  exit 0
}

root=$(git rev-parse --show-toplevel 2>/dev/null) || skip_all "git リポジトリではない"
cd "$root"
command -v gh >/dev/null 2>&1 || skip_all "gh が無い (brew install gh)"
gh auth status >/dev/null 2>&1 || skip_all "gh 未認証 (gh auth login)"
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
  || skip_all "GitHub 上のリポジトリを特定できない (origin が github.com か・push 済みか確認)"
repo_json=$(gh api "repos/$repo" 2>/dev/null) || skip_all "repos/$repo を取得できない (トークン権限を確認)"

visibility=$(jq -r 'if .private then "private" else "public" end' <<<"$repo_json")
default_branch=$(jq -r .default_branch <<<"$repo_json")

jq -cn --arg repo "$repo" --arg vis "$visibility" --arg db "$default_branch" --arg manifest "$manifest" \
  '{id:"_meta",layer:"github",repo:$repo,visibility:$vis,default_branch:$db,manifest:$manifest}'

if [ "$(jq -r .archived <<<"$repo_json")" = "true" ]; then
  emit gh-archived github required skip "アーカイブ済みリポジトリのため GitHub 設定の監査を打ち切る"
  exit 0
fi

# ---- ruleset / classic protection の情報は複数の builtin で使うため一度だけ収集 ----
# default branch を対象にした enforcement=active な ruleset の rules[].type を集める
ruleset_rule_types=""
if rids=$(gh api "repos/$repo/rulesets" --jq '.[] | select(.enforcement == "active") | .id' 2>/dev/null); then
  for rid in $rids; do
    rs=$(gh api "repos/$repo/rulesets/$rid" 2>/dev/null) || continue
    if jq -e --arg b "refs/heads/$default_branch" \
      '.conditions.ref_name.include // [] | any(. == "~DEFAULT_BRANCH" or . == $b)' >/dev/null <<<"$rs"; then
      ruleset_rule_types="$ruleset_rule_types $(jq -r '[.rules[].type] | join(" ")' <<<"$rs")"
    fi
  done
fi
classic_json=$(gh api "repos/$repo/branches/$default_branch/protection" 2>/dev/null) || classic_json=""

has_rule() { case " $ruleset_rule_types " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ---- builtin 検査 (正本の check.name から呼ばれる) ----

builtin_main_branch_protected() { # ruleset か classic protection のどちらか成立で ok
  if has_rule deletion && has_rule non_fast_forward; then echo ok; return; fi
  if [ -n "$classic_json" ] && jq -e \
    '((.allow_deletions.enabled // false) | not) and ((.allow_force_pushes.enabled // false) | not)' \
    >/dev/null <<<"$classic_json"; then echo ok; return; fi
  echo fail
}

builtin_main_pr_required() {
  if has_rule pull_request; then echo ok; return; fi
  if [ -n "$classic_json" ] && jq -e '.required_pull_request_reviews' >/dev/null 2>&1 <<<"$classic_json"; then
    echo ok; return
  fi
  echo fail
}

builtin_required_checks_configured() {
  compgen -G ".github/workflows/*.yml" >/dev/null || { echo "skip:CI workflow が無いため対象外"; return; }
  if has_rule required_status_checks; then echo ok; return; fi
  if [ -n "$classic_json" ] && jq -e '.required_status_checks' >/dev/null 2>&1 <<<"$classic_json"; then
    echo ok; return
  fi
  echo fail
}

builtin_vulnerability_alerts_enabled() { # 204=有効 / 404=無効
  local err
  if err=$(gh api "repos/$repo/vulnerability-alerts" 2>&1 >/dev/null); then echo ok; return; fi
  case "$err" in *403*) echo "skip:トークン権限不足 (HTTP 403)" ;; *) echo fail ;; esac
}

builtin_automated_security_fixes_enabled() {
  local enabled
  enabled=$(gh api "repos/$repo/automated-security-fixes" --jq .enabled 2>/dev/null) \
    || { echo "skip:取得できない (トークン権限を確認)"; return; }
  [ "$enabled" = "true" ] && echo ok || echo fail
}

builtin_actions_default_permissions_read() {
  local perm
  perm=$(gh api "repos/$repo/actions/permissions/workflow" --jq .default_workflow_permissions 2>/dev/null) \
    || { echo "skip:取得できない (トークン権限を確認)"; return; }
  [ "$perm" = "read" ] && echo ok || echo fail
}

# ---- 項目ループ ----

while IFS= read -r item; do
  id=$(jq -r .id <<<"$item")
  level=$(jq -r .level <<<"$item")
  why=$(jq -r .why <<<"$item")
  fix=$(jq -r '.fix // ""' <<<"$item")
  fix=${fix//\{repo\}/$repo}
  ctype=$(jq -r .check.type <<<"$item")

  # 可視性の条件 (when.visibility) が合わない項目は対象外
  want_vis=$(jq -r '.when.visibility // ""' <<<"$item")
  if [ -n "$want_vis" ] && [ "$want_vis" != "$visibility" ]; then
    emit "$id" github "$level" skip "$want_vis リポのみ対象 (このリポは $visibility)"
    continue
  fi

  case "$ctype" in
    gh_api)
      endpoint=$(jq -r .check.endpoint <<<"$item")
      endpoint=${endpoint//\{repo\}/$repo}
      expect=$(jq -r .check.expect <<<"$item")
      jq_expr=$(jq -r .check.jq <<<"$item")
      if [ "$endpoint" = "repos/$repo" ]; then
        body=$repo_json
      elif ! body=$(gh api "$endpoint" 2>/dev/null); then
        emit "$id" github "$level" skip "$endpoint を取得できない (トークン権限を確認)"
        continue
      fi
      actual=$(jq -r "$jq_expr" <<<"$body" 2>/dev/null) || actual="(jq 評価エラー)"
      if [ "$actual" = "$expect" ]; then
        emit "$id" github "$level" ok "値: $actual"
      else
        emit "$id" github "$level" "$(fail_status "$level")" "期待 $expect / 実際 $actual — $why" "$fix"
      fi
      ;;
    builtin)
      name=$(jq -r .check.name <<<"$item")
      if ! declare -F "builtin_$name" >/dev/null; then
        emit "$id" github "$level" skip "builtin '$name' はこのスクリプトに未実装 (正本との契約ずれ。プラグイン更新が必要)"
        continue
      fi
      result=$("builtin_$name")
      case "$result" in
        ok) emit "$id" github "$level" ok "" ;;
        skip:*) emit "$id" github "$level" skip "${result#skip:}" ;;
        *) emit "$id" github "$level" "$(fail_status "$level")" "$why" "$fix" ;;
      esac
      ;;
    *)
      emit "$id" github "$level" skip "check.type '$ctype' はこのスクリプトの対象外"
      ;;
  esac
done < <(jq -c '.items[] | select(.layer == "github")' "$manifest")

exit 0
