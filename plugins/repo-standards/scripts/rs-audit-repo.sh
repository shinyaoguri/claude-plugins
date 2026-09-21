#!/usr/bin/env bash
# リポジトリ構成 (layer: repo) + リポ内 .claude 設定 (layer: claude) の機械判定。
# cwd の git リポジトリを正本 repo-standards.json と突き合わせ、JSON Lines で報告する。
# 出力契約・正本の解決チェーンは rs-lib.sh 冒頭を参照。
set -uo pipefail
. "$(dirname "$0")/rs-lib.sh"

# --cadence <bootstrap|drift> で項目を絞る。既定は全件 — 絞るのは「定期的に見直す」
# 用途のためで、リポを初めて見るときに設置漏れが隠れては困る (ADR 0025)
cadence_filter=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --cadence)
      cadence_filter="${2:-}"
      case "$cadence_filter" in
        bootstrap|drift) ;;
        *) echo "$(basename "$0"): --cadence は bootstrap か drift" >&2; exit 2 ;;
      esac
      shift 2 ;;
    *) echo "$(basename "$0"): 不明な引数: $1" >&2; exit 2 ;;
  esac
done

root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  emit not-a-git-repo meta required ng "git リポジトリではない (リポジトリ内で実行する)"
  exit 0
}
cd "$root"

manifest=$(resolve_standards) || { emit_manifest_missing; exit 0; }

# リポ種別: marker ファイルが存在する最初の kind。どれも無ければ generic。
# 出力の _meta に載り、repo-audit-fix が「エコシステムを聞くか」の分岐に使う。
# 正本でなくここに置くのは、言語ごとの知識 (テストディレクトリの命名・package.json の
# 特別扱い) が既にこのスクリプトにあり、同じ関心を 2 箇所へ散らさないため (ADR 0023)
kind=generic
for pair in "swift:Package.swift" "web:package.json" "python:pyproject.toml"; do
  if [ -e "${pair#*:}" ]; then kind="${pair%%:*}"; break; fi
done

# 可視性を引けなかった理由。gh 認証・remote の有無まで見て切り分ける — 原因が何であれ
# 「gh 未認証」と言ってしまうと、受け手は gh auth login を疑って時間を使う。
# 文言は同じ状況を切り分けている rs-audit-github.sh の skip_all と揃える。
# gh repo view が失敗した経路でしか呼ばない (正常系の gh 呼び出しは 1 回のまま)
visibility_unknown_reason() {
  gh auth status >/dev/null 2>&1 || { echo "gh 未認証 (gh auth login)"; return; }
  [ -n "$(git remote 2>/dev/null)" ] \
    || { echo "remote が無い (git remote add origin ... して push する)"; return; }
  echo "GitHub 上のリポジトリを特定できない (origin が github.com か・push 済みか確認)"
}

# when.visibility を評価するために可視性を引く。引けなければ "unknown" とし、
# 可視性を条件にした項目だけを skip する (層全体は gh 無しでも動き続ける)
visibility=unknown vis_reason=""
if ! command -v gh >/dev/null 2>&1; then
  vis_reason="gh が無い (brew install gh)"
else
  case "$(gh repo view --json isPrivate --jq .isPrivate 2>/dev/null)" in
    true) visibility=private ;;
    false) visibility=public ;;
    *) vis_reason=$(visibility_unknown_reason) ;;
  esac
fi

jq -cn --arg kind "$kind" --arg root "$root" --arg vis "$visibility" --arg manifest "$manifest" \
  --arg vis_reason "$vis_reason" \
  '{id:"_meta",layer:"repo",kind:$kind,root:$root,visibility:$vis,manifest:$manifest}
   + (if $vis_reason != "" then {visibility_reason:$vis_reason} else {} end)'

# コミットが 1 件も無いリポは監査でなく生成の対象。全項目を並べても「まだ何も無い」の
# 言い換えにしかならず、README・CLAUDE.md・CI のようにリポの実体を材料にする生成的 fix は
# 空虚な雛形しか作れない。判定を打ち切って repo-bootstrap へ渡す (LLM の裁量に委ねず
# ここで決める — 空リポでは LLM 判定と反証が全件空振りし、そのぶんがまるごと無駄になる)
if ! git rev-parse --verify -q HEAD >/dev/null 2>&1; then
  emit repo-uninitialized meta required ng \
    "コミットが 1 件も無い — 標準と突き合わせる対象がまだ無い (監査ではなく雛形生成の段階)" \
    "repo-bootstrap スキルで個人標準どおりの雛形を生成する (git init 済みなので初期化は飛ばし、未追跡ファイルは残したまま追加する)"
  exit 0
fi

# ---- builtin 検査 (正本の check.name から呼ばれる) ----

builtin_gitignore_covers_env() { # ok / fail / skip:<理由> / blocked:<理由>
  [ -f .gitignore ] || { echo "blocked:.gitignore がまだ無い (gitignore-exists 待ち)"; return; }
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

# workflow ファイルの一覧 (.yml / .yaml 両対応。片方だけの glob では取りこぼす)
workflow_files() {
  find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null
}

builtin_ci_workflow_exists() {
  [ -n "$(workflow_files)" ] && echo ok || echo fail
}

builtin_license_exists() {
  local p
  for p in LICENSE LICENSE.md LICENSE.txt COPYING; do
    [ -f "$p" ] && { echo ok; return; }
  done
  echo fail
}

# ディレクトリだけ作って空のまま放置されると記録の実体が無いので、ADR 本体が
# 1 件以上あることまで見る。README.md は索引なので ADR としては数えない
builtin_adr_exists() {
  local p
  for p in docs/decisions docs/adr docs/architecture-decisions; do
    [ -d "$p" ] || continue
    if [ -n "$(find "$p" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' -print -quit 2>/dev/null)" ]; then
      echo ok
    else
      echo "fail:$p はあるが ADR が 1 件も無い"
    fi
    return
  done
  echo fail
}

# CHANGELOG はリリースするリポだけの関心事なので、タグが無ければ対象外
builtin_changelog_exists() {
  [ -n "$(git tag 2>/dev/null | head -1)" ] || { echo "skip:タグが無い (リリースしないリポは対象外)"; return; }
  local p
  for p in CHANGELOG.md CHANGELOG docs/CHANGELOG.md; do
    [ -f "$p" ] && { echo ok; return; }
  done
  echo fail
}

# テストの置き場は言語ごとに違い、Web 系はソースと同じ場所に *.test.ts を置くことも多い。
# ディレクトリとファイル名の両方を見ないと取りこぼす
builtin_test_dir_exists() {
  local p
  for p in Tests test tests spec __tests__ src/test src/tests; do
    [ -d "$p" ] && { echo ok; return; }
  done
  git ls-files 2>/dev/null \
    | grep -qiE '(^|/)(test[-_][^/]+\.(py|sh|bash)|[^/]+_test\.(py|go|ts|js|rb|sh)|[^/]+\.(test|spec)\.(ts|tsx|js|jsx|mjs)|[^/]+\.bats|[^/]*Tests?\.swift)$' \
    && { echo ok; return; }
  echo fail
}

# 代表的なテスト実行コマンドの語彙。言語が増えたらここも育てる
# (bash はテストランナーでなくスクリプトの直接実行 ./scripts/test-*.sh が慣習)
TEST_CMD_RE='(swift test|npm (run )?test|pnpm (run )?test|yarn test|pytest|unittest|go test|cargo test|bun test|vitest|jest|(^|[ /])(test[-_][^ ]*|[^ /]*_test)\.(sh|bash)|(^| )bats )'

# workflow の run: が呼ぶ npm/pnpm/yarn script を package.json で展開した本文を返す。
# CI とローカルで同一の集約コマンド (npm run check が lint と test をまとめて呼ぶ形)
# を使い、チェック列の正本を package.json に置く構成は珍しくないため、YAML の文字列
# 検索だけでは追えない。集約の集約まで届くよう 2 段たどる
expand_ci_npm_scripts() {
  [ -f package.json ] || return 0
  local files names seen="" body="" round name val next
  files=$(workflow_files)
  [ -n "$files" ] || return 0
  names=$(grep -hoE '(npm|pnpm|yarn)( +run)? +[A-Za-z0-9:@._-]+' $files | awk '{print $NF}' | sort -u)
  for round in 1 2; do
    next=""
    for name in $names; do
      case " $seen " in *" $name "*) continue ;; esac
      seen="$seen $name"
      val=$(jq -r --arg n "$name" '.scripts[$n] // empty' package.json 2>/dev/null) || continue
      [ -n "$val" ] || continue
      body="$body
$val"
      next="$next $(grep -oE '(npm|pnpm|yarn)( +run)? +[A-Za-z0-9:@._-]+' <<<"$val" | awk '{print $NF}')"
    done
    names=$next
    [ -n "$names" ] || break
  done
  printf '%s\n' "$body"
}

# テストディレクトリがあっても CI で呼ばれていなければ「置いてあるだけ」になる
# (setup リポ issue #36 の実例: 手元でしか流さず 1 件赤いまま数日放置された)
builtin_tests_run_in_ci() {
  [ "$(builtin_test_dir_exists)" = ok ] \
    || { echo "blocked:テストがまだ無い (test-dir-exists 待ち)"; return; }
  local files
  files=$(workflow_files)
  [ -n "$files" ] || { echo "blocked:CI workflow がまだ無い (ci-workflow-exists 待ち)"; return; }
  if grep -qhE "$TEST_CMD_RE" $files; then
    echo ok
    return
  fi
  local expanded
  expanded=$(expand_ci_npm_scripts)
  if [ -n "$expanded" ] && grep -qE "$TEST_CMD_RE" <<<"$expanded"; then
    echo "ok:package.json の集約 script 経由でテストが走っている"
    return
  fi
  # package.json があるのに見つからないときは、さらに深い集約や外部ツール経由の
  # 可能性が残る。「テストが無い」と断定せず、確認先を添えて返す
  if [ -f package.json ]; then
    echo "fail:CI にテスト実行コマンドが見当たらない (package.json の script を 2 段たどっても見つからない。さらに深い集約なら実 run のログで確認する)"
    return
  fi
  echo fail
}

builtin_pr_title_lint_configured() {
  local files
  files=$(workflow_files)
  [ -n "$files" ] || { echo "blocked:CI workflow がまだ無い (ci-workflow-exists 待ち)"; return; }
  if grep -qhiE '(pr-title|pr_title|PR_TITLE|conventional|commitlint|semantic-pull-request)' $files; then
    echo ok
  else
    echo fail
  fi
}

# 週次・月次で上流や依存のドリフトを拾う仕組み (schedule トリガ) があるか
builtin_scheduled_workflow_exists() {
  local files
  files=$(workflow_files)
  [ -n "$files" ] || { echo "blocked:CI workflow がまだ無い (ci-workflow-exists 待ち)"; return; }
  grep -qhE '^\s*schedule:' $files && echo ok || echo fail
}

# 秘密ファイルが追跡対象に入っていないか。履歴の書き換えは不可逆なので検出のみ
builtin_no_committed_secrets() {
  local hits
  # 追跡ファイルが 1 件も無ければ検査対象がゼロ。「秘密が混ざっていない」ではない
  [ -n "$(git ls-files 2>/dev/null | head -1)" ] \
    || { echo "skip:追跡中のファイルが無い (突き合わせる対象がゼロ)"; return; }
  hits=$(git ls-files 2>/dev/null | grep -iE '(^|/)(\.env(\.[a-z]+)?|.*\.pem|.*\.p12|.*\.key|id_rsa|.*\.keystore|.*credentials\.json)$' \
    | grep -viE '(\.env\.(example|sample|template)|\.lock)' | head -5)
  [ -z "$hits" ] && { echo ok; return; }
  echo "fail:追跡中の秘密ファイル候補: $(tr '\n' ' ' <<<"$hits")"
}

# ---- 項目ループ ----

while IFS= read -r item; do
  # cadence フィルタ (--cadence 指定時のみ絞る。既定は全件)
  if [ -n "$cadence_filter" ] && [ "$(jq -r '.cadence // "bootstrap"' <<<"$item")" != "$cadence_filter" ]; then
    continue
  fi

  id=$(jq -r .id <<<"$item")
  layer=$(jq -r .layer <<<"$item")
  level=$(jq -r .level <<<"$item")
  why=$(jq -r .why <<<"$item")
  fix=$(jq -r '.fix // ""' <<<"$item")
  fix_kind=$(jq -r '.fix_kind // ""' <<<"$item")
  ctype=$(jq -r .check.type <<<"$item")


  # 可視性の条件 (when.visibility)
  want_vis=$(jq -r '.when.visibility // ""' <<<"$item")
  if [ -n "$want_vis" ] && [ "$want_vis" != "$visibility" ]; then
    if [ "$visibility" = unknown ]; then
      emit "$id" "$layer" "$level" skip "$want_vis リポのみ対象だが可視性を判定できない — $vis_reason"
    else
      emit "$id" "$layer" "$level" skip "$want_vis リポのみ対象 (このリポは $visibility)"
    fi
    continue
  fi

  case "$ctype" in
    file_exists)
      path=$(jq -r .check.path <<<"$item")
      if [ -e "$path" ]; then emit "$id" "$layer" "$level" ok "$path"
      else emit "$id" "$layer" "$level" "$(fail_status "$level")" "$path が無い — $why" "$fix" "$fix_kind"; fi
      ;;
    file_absent)
      path=$(jq -r .check.path <<<"$item")
      if [ ! -e "$path" ]; then emit "$id" "$layer" "$level" ok "$path は無い (期待どおり)"
      else emit "$id" "$layer" "$level" "$(fail_status "$level")" "$path が存在する — $why" "$fix" "$fix_kind"; fi
      ;;
    glob_exists)
      pattern=$(jq -r .check.path <<<"$item")
      if compgen -G "$pattern" >/dev/null; then emit "$id" "$layer" "$level" ok "$pattern に一致あり"
      else emit "$id" "$layer" "$level" "$(fail_status "$level")" "$pattern に一致なし — $why" "$fix" "$fix_kind"; fi
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
        # ok:<詳細> は適合と判定した根拠が自明でない場合 (どう回り道して見つけたか)
        ok:*) emit "$id" "$layer" "$level" ok "${result#ok:}" ;;
        skip:*) emit "$id" "$layer" "$level" skip "${result#skip:}" ;;
        # blocked:<理由> は別の標準項目が未達で判定できない場合 (前提が解消されれば判定対象に
        # 戻る)。fix は渡さない — 当てる先はこの項目でなく前提側の項目にある
        blocked:*) emit "$id" "$layer" "$level" blocked "${result#blocked:}" ;;
        # fail:<詳細> は検査が具体的な違反箇所を掴んでいる場合 (どのブランチ・どのファイルか)
        fail:*) emit "$id" "$layer" "$level" "$(fail_status "$level")" "${result#fail:} — $why" "$fix" "$fix_kind" ;;
        *) emit "$id" "$layer" "$level" "$(fail_status "$level")" "$why" "$fix" "$fix_kind" ;;
      esac
      ;;
    llm)
      prompt=$(jq -r .check.prompt <<<"$item")
      emit "$id" "$layer" "$level" manual "$prompt" "$fix" "$fix_kind"
      ;;
    *)
      emit "$id" "$layer" "$level" skip "check.type '$ctype' はこのスクリプトの対象外"
      ;;
  esac
done < <(jq -c '.items[] | select(.layer == "repo" or .layer == "claude")' "$manifest")

exit 0
