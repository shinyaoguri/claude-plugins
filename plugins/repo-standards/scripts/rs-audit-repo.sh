#!/usr/bin/env bash
# リポジトリ構成 (layer: repo) + リポ内 .claude 設定 (layer: claude) の機械判定。
# cwd の git リポジトリを正本 repo-standards.json と突き合わせ、JSON Lines で報告する。
# 出力契約・正本の解決チェーンは rs-lib.sh 冒頭を参照。
set -uo pipefail
. "$(dirname "$0")/rs-lib.sh"

root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  emit not-a-git-repo meta required ng "git リポジトリではない (リポジトリ内で実行する)"
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

# when.visibility を評価するために可視性を引く。gh が無ければ "unknown" とし、
# 可視性を条件にした項目だけを skip する (層全体は gh 無しでも動き続ける)
visibility=unknown
if command -v gh >/dev/null 2>&1; then
  case "$(gh repo view --json isPrivate --jq .isPrivate 2>/dev/null)" in
    true) visibility=private ;;
    false) visibility=public ;;
  esac
fi

jq -cn --arg kind "$kind" --arg root "$root" --arg vis "$visibility" --arg manifest "$manifest" \
  '{id:"_meta",layer:"repo",kind:$kind,root:$root,visibility:$vis,manifest:$manifest}'

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

# GitHub Flow「main が唯一の長命ブランチ」の検査。作業中ブランチと区別がつかないため
# 最終コミットから 30 日以上動いていないものだけを残骸とみなす
builtin_no_stale_branches() {
  local now cutoff stale b ts
  now=$(date +%s); cutoff=$((now - 30 * 86400)); stale=""
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    ts=$(git log -1 --format=%ct "$b" 2>/dev/null) || continue
    [ "$ts" -lt "$cutoff" ] && stale="$stale ${b#origin/}"
  done < <(git branch -r 2>/dev/null | tr -d ' ' | grep -vE '^origin/(HEAD|main|master)' )
  [ -z "$stale" ] && { echo ok; return; }
  echo "fail:30 日以上更新の無いリモートブランチ:$stale (ローカルの追跡 ref 基準。fetch していなければ古い可能性)"
}

# 秘密ファイルが追跡対象に入っていないか。履歴の書き換えは不可逆なので検出のみ
builtin_no_committed_secrets() {
  local hits
  hits=$(git ls-files 2>/dev/null | grep -iE '(^|/)(\.env(\.[a-z]+)?|.*\.pem|.*\.p12|.*\.key|id_rsa|.*\.keystore|.*credentials\.json)$' \
    | grep -viE '(\.env\.(example|sample|template)|\.lock)' | head -5)
  [ -z "$hits" ] && { echo ok; return; }
  echo "fail:追跡中の秘密ファイル候補: $(tr '\n' ' ' <<<"$hits")"
}

# 掴んでいるブランチが消えていて、失って困るものを持たない worktree を挙げる。
# 「消して良いか」の判定に祖先関係 (ahead N) を使わないのが要点 — squash merge では
# マージ済みでも元コミットが main の祖先にならず ahead に出続けるため、素直に読むと
# 消せるものを残す。upstream:track が [gone] なら PR がマージされて head ブランチが
# 削除された後なので、内容は remote 側に入っている
removable_worktrees() { # → basename を 1 行ずつ
  local path branch track main_wt
  # リポジトリ本体と、監査を実行している自分自身は候補から外す
  main_wt=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')
  while IFS=$'\t' read -r path branch; do
    [ -n "$path" ] || continue
    case "$path" in "$main_wt" | "$root") continue ;; esac
    # 未コミットの変更があるものは触らない
    [ -z "$(git -C "$path" status --porcelain 2>/dev/null)" ] || continue
    # 再生成できない ignored ファイル (.env 等の設定) は通常の status に出ない。
    # .build や node_modules と違って消すと失われるので、持つものは候補から外す
    git -C "$path" status --porcelain --ignored 2>/dev/null \
      | grep -qE '^!! (.*/)?\.env' && continue
    # detached HEAD は追跡ブランチが無く自動判定できない (PR の head と突き合わせる
    # 手作業が要る) ので候補にしない
    [ -n "$branch" ] || continue
    track=$(git for-each-ref --format='%(upstream:track)' "refs/heads/$branch" 2>/dev/null)
    [ "$track" = "[gone]" ] || continue
    basename "$path"
  done < <(git worktree list --porcelain 2>/dev/null | awk '
    /^worktree /{p=$2; b=""}
    /^branch /{sub(/^refs\/heads\//, "", $2); b=$2}
    /^$/{if (p != "") print p"\t"b; p=""}
    END{if (p != "") print p"\t"b}')
}

# 使い終わった worktree の残骸。~/.claude/ の symlink が worktree を指す事故の温床でもある
builtin_worktrees_clean() {
  [ -d .claude/worktrees ] || { echo ok; return; }
  local dirs registered orphan
  registered=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')
  orphan=""
  for dirs in .claude/worktrees/*/; do
    [ -d "$dirs" ] || continue
    dirs=${dirs%/}
    printf '%s\n' "$registered" | grep -qF "$(cd "$dirs" && pwd)" || orphan="$orphan $(basename "$dirs")"
  done
  local n
  n=$(git worktree list --porcelain 2>/dev/null | grep -c '^worktree ' || echo 0)
  if [ -n "$orphan" ]; then
    echo "fail:git に登録されていない worktree ディレクトリ:$orphan"
  elif [ "$n" -gt 3 ]; then
    # 個数だけでは緊急度が伝わらない (1 リポで 9 GB 超えた実例がある) ので容量を添える
    local mb removable
    mb=$(du -sk .claude/worktrees 2>/dev/null | awk '{printf "%d", $1 / 1024}')
    removable=$(removable_worktrees | tr '\n' ' ')
    if [ -n "${removable// /}" ]; then
      echo "fail:worktree が $((n - 1)) 個 / ${mb} MB ある。upstream が [gone] で未コミットの変更も無い候補: ${removable% }"
    else
      echo "fail:worktree が $((n - 1)) 個 / ${mb} MB ある (自動で安全と判定できる候補は無い。squash merge では ahead N が未マージを意味しないので、PR のマージ状況で確認する)"
    fi
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
  fix_kind=$(jq -r '.fix_kind // ""' <<<"$item")
  ctype=$(jq -r .check.type <<<"$item")

  # リポ種別のフィルタ
  if ! jq -e --arg k "$kind" '.applies_to | index("all") or index($k)' >/dev/null <<<"$item"; then
    emit "$id" "$layer" "$level" skip "リポ種別 $kind は対象外"
    continue
  fi

  # 可視性の条件 (when.visibility)
  want_vis=$(jq -r '.when.visibility // ""' <<<"$item")
  if [ -n "$want_vis" ] && [ "$want_vis" != "$visibility" ]; then
    if [ "$visibility" = unknown ]; then
      emit "$id" "$layer" "$level" skip "$want_vis リポのみ対象だが可視性を判定できない (gh 未認証)"
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
