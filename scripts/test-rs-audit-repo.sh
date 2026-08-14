#!/usr/bin/env bash
# repo-standards プラグインの rs-audit-repo.sh の builtin 判定テスト。
# 一時 git リポジトリと最小 manifest を用意し、出力 (JSON Lines) の status を検証する。
# 関数を source せずエンドツーエンドで見るのは、正本との契約 (出力スキーマ) ごと守るため。
#
#   bash scripts/test-rs-audit-repo.sh
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
target="$repo_root/plugins/repo-standards/scripts/rs-audit-repo.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# コミットを作るケースがあるので ident を注入する。CI ランナーには user.name /
# user.email が無く、開発機の設定にも依存させない (どこで回しても同じ結果にする)
export GIT_AUTHOR_NAME=rs-test GIT_AUTHOR_EMAIL=rs-test@example.invalid
export GIT_COMMITTER_NAME=rs-test GIT_COMMITTER_EMAIL=rs-test@example.invalid

failures=0

# 検証対象の builtin だけを持つ最小 manifest。level は recommended なので違反時の status は warn
manifest="$tmp/standards.json"
cat > "$manifest" <<'EOF'
{
  "version": 1,
  "kinds": [{ "id": "generic", "marker": null }],
  "items": [
    {
      "id": "adr-exists",
      "layer": "repo",
      "level": "recommended",
      "applies_to": ["all"],
      "check": { "type": "builtin", "name": "adr_exists" },
      "why": "テスト用",
      "fix": "テスト用"
    },
    {
      "id": "test-dir-exists",
      "layer": "repo",
      "level": "recommended",
      "applies_to": ["all"],
      "check": { "type": "builtin", "name": "test_dir_exists" },
      "why": "テスト用",
      "fix": "テスト用"
    },
    {
      "id": "tests-run-in-ci",
      "layer": "repo",
      "level": "recommended",
      "applies_to": ["all"],
      "check": { "type": "builtin", "name": "tests_run_in_ci" },
      "why": "テスト用",
      "fix": "テスト用"
    },
    {
      "id": "no-committed-secrets",
      "layer": "repo",
      "level": "recommended",
      "applies_to": ["all"],
      "check": { "type": "builtin", "name": "no_committed_secrets" },
      "why": "テスト用",
      "fix": "テスト用"
    },
    {
      "id": "no-stale-branches",
      "layer": "repo",
      "level": "recommended",
      "applies_to": ["all"],
      "check": { "type": "builtin", "name": "no_stale_branches" },
      "why": "テスト用",
      "fix": "テスト用"
    },
    {
      "id": "worktrees-clean",
      "layer": "repo",
      "level": "recommended",
      "applies_to": ["all"],
      "check": { "type": "builtin", "name": "worktrees_clean" },
      "why": "テスト用",
      "fix": "テスト用"
    },
    {
      "id": "gitignore-covers-env",
      "layer": "repo",
      "level": "recommended",
      "applies_to": ["all"],
      "check": { "type": "builtin", "name": "gitignore_covers_env" },
      "why": "テスト用",
      "fix": "テスト用"
    },
    {
      "id": "pr-title-lint",
      "layer": "repo",
      "level": "recommended",
      "applies_to": ["all"],
      "check": { "type": "builtin", "name": "pr_title_lint_configured" },
      "why": "テスト用",
      "fix": "テスト用"
    },
    {
      "id": "scheduled-freshness",
      "layer": "repo",
      "level": "recommended",
      "applies_to": ["all"],
      "check": { "type": "builtin", "name": "scheduled_workflow_exists" },
      "why": "テスト用",
      "fix": "テスト用"
    },
    {
      "id": "changelog-exists",
      "layer": "repo",
      "level": "recommended",
      "applies_to": ["all"],
      "check": { "type": "builtin", "name": "changelog_exists" },
      "why": "テスト用",
      "fix": "テスト用"
    }
  ]
}
EOF

# assert が検証する項目 id (セクションごとに切り替える)
check_id=adr-exists

# 初回コミットを打つか。コミットが 1 件も無いリポは監査を打ち切る仕様なので、個々の
# builtin を見るケースでは必ず打つ (未初期化の打ち切りそのものを見るセクションだけ 0 にする)
init_commit=1

# assert <期待 status> <ケース名> <セットアップコマンド...>
assert() {
  local want=$1 name=$2; shift 2
  local dir="$tmp/case-$RANDOM"
  mkdir -p "$dir"
  ( cd "$dir" && git init -q -b main \
      && { [ "$init_commit" -eq 0 ] || git commit -q --allow-empty -m init; } \
      && "$@" ) || { echo "  [ERROR] $name: セットアップ失敗"; failures=$((failures + 1)); return; }

  local got
  got=$( cd "$dir" && REPO_STANDARDS_JSON="$manifest" bash "$target" \
    | jq -r --arg id "$check_id" 'select(.id == $id) | .status' )

  if [ "$got" = "$want" ]; then
    echo "  [ok]   $name → $got"
  else
    echo "  [FAIL] $name → 期待 $want / 実際 $got"
    failures=$((failures + 1))
  fi
}

echo "builtin_adr_exists:"

# 正常系: ADR が 1 件ある
assert ok "ADR が 1 件ある" \
  bash -c 'mkdir -p docs/decisions && echo "# 0001" > docs/decisions/0001-x.md'

# 正常系: 別名のディレクトリでも拾う
assert ok "docs/adr/ でも拾う" \
  bash -c 'mkdir -p docs/adr && echo "# 0001" > docs/adr/0001-x.md'

# 失敗系: ディレクトリ自体が無い
assert warn "docs/decisions/ が無い" true

# 失敗系: ディレクトリはあるが空 (この PR で塞いだ穴)
assert warn "ディレクトリはあるが空" \
  bash -c 'mkdir -p docs/decisions'

# 境界値: 索引の README.md だけでは ADR 本体が無いとみなす
assert warn "README.md しか無い" \
  bash -c 'mkdir -p docs/decisions && echo "# 索引" > docs/decisions/README.md'

# 境界値: サブディレクトリの .md は数えない (maxdepth 1)
assert warn "サブディレクトリの .md のみ" \
  bash -c 'mkdir -p docs/decisions/drafts && echo "# 草案" > docs/decisions/drafts/0001-x.md'

echo
echo "builtin_test_dir_exists (bash テスト):"
check_id=test-dir-exists

# 正常系: scripts/test-*.sh 形式 (このリポ自身の形。#47 で塞いだ穴)
assert ok "scripts/test-*.sh を認識する" \
  bash -c 'mkdir -p scripts && touch scripts/test-foo.sh && git add -A'

# 正常系: *_test.sh 形式
assert ok "*_test.sh を認識する" \
  bash -c 'mkdir -p scripts && touch scripts/foo_test.sh && git add -A'

# 境界値: 名前に test を含むだけのスクリプトは誤検出しない
assert warn "latest-build.sh は誤検出しない" \
  bash -c 'mkdir -p scripts && touch scripts/latest-build.sh && git add -A'

echo
echo "builtin_tests_run_in_ci (bash テスト):"
check_id=tests-run-in-ci

# 正常系: workflow がテストスクリプトを直接実行している (このリポ自身の形)
assert ok "CI で ./scripts/test-*.sh を実行している" \
  bash -c 'mkdir -p scripts .github/workflows && touch scripts/test-foo.sh &&
           printf "jobs:\n  t:\n    steps:\n      - run: ./scripts/test-foo.sh\n" > .github/workflows/ci.yml &&
           git add -A'

# 失敗系: テストはあるが CI が実行していない
assert warn "テストはあるが CI で実行していない" \
  bash -c 'mkdir -p scripts .github/workflows && touch scripts/test-foo.sh &&
           printf "jobs:\n  t:\n    steps:\n      - run: echo build\n" > .github/workflows/ci.yml &&
           git add -A'

# 正常系: 集約 npm script 経由 (CI は npm run check だけを呼び、実体は package.json)
assert ok "集約 npm script を package.json までたどる" \
  bash -c 'mkdir -p scripts .github/workflows && touch scripts/test-foo.sh &&
           printf "jobs:\n  t:\n    steps:\n      - run: npm ci\n      - run: npm run check\n" > .github/workflows/ci.yml &&
           printf "{\"scripts\":{\"check\":\"npm run lint && npm test\",\"test\":\"vitest run\"}}\n" > package.json &&
           git add -A'

# 正常系: 集約の集約 (2 段) までは届く
assert ok "集約 script の 2 段目でも見つける" \
  bash -c 'mkdir -p scripts .github/workflows && touch scripts/test-foo.sh &&
           printf "jobs:\n  t:\n    steps:\n      - run: npm run ci\n" > .github/workflows/ci.yml &&
           printf "{\"scripts\":{\"ci\":\"npm run check\",\"check\":\"npm run lint && npm test\"}}\n" > package.json &&
           git add -A'

# 境界値: 3 段以上の入れ子は追わない (無制限に展開せず、確認先を添えた warn に落とす)
assert warn "3 段の入れ子は追わない" \
  bash -c 'mkdir -p scripts .github/workflows && touch scripts/test-foo.sh &&
           printf "jobs:\n  t:\n    steps:\n      - run: npm run a\n" > .github/workflows/ci.yml &&
           printf "{\"scripts\":{\"a\":\"npm run b\",\"b\":\"npm run c\",\"c\":\"vitest run\"}}\n" > package.json &&
           git add -A'

# 失敗系: package.json はあるが、呼ばれている script にテストが無い
assert warn "呼ばれている script にテストが無い" \
  bash -c 'mkdir -p scripts .github/workflows && touch scripts/test-foo.sh &&
           printf "jobs:\n  t:\n    steps:\n      - run: npm run build\n" > .github/workflows/ci.yml &&
           printf "{\"scripts\":{\"build\":\"tsc -p .\"}}\n" > package.json &&
           git add -A'

# 集約経由で ok にした項目は、どう見つけたかを detail に残す (ok:<詳細> の出力契約)
agg_dir="$tmp/aggregate-detail"
mkdir -p "$agg_dir"
( cd "$agg_dir" && git init -q -b main && git commit -q --allow-empty -m init &&
  mkdir -p scripts .github/workflows && touch scripts/test-foo.sh &&
  printf "jobs:\n  t:\n    steps:\n      - run: npm run check\n" > .github/workflows/ci.yml &&
  printf '{"scripts":{"check":"npm test"}}\n' > package.json &&
  git add -A ) >/dev/null 2>&1
got=$( cd "$agg_dir" && REPO_STANDARDS_JSON="$manifest" bash "$target" \
  | jq -r 'select(.id == "tests-run-in-ci") | .detail // ""' )
if [ -n "$got" ]; then
  echo "  [ok]   集約経由の ok は根拠を detail に残す → $got"
else
  echo "  [FAIL] 集約経由の ok の detail → 期待 非空 / 実際 空"
  failures=$((failures + 1))
fi

echo
echo "前提未達の保留 (blocked) と恒久的な対象外 (skip) の切り分け:"

# 前提が「別の標準項目」なら blocked。前提が埋まれば判定対象に戻るので、skip に落とすと
# 拾い直す契機が消える (#97 / ADR 0019)。前提がリポの性質なら skip のまま

check_id=tests-run-in-ci
assert blocked "テストが無い → test-dir-exists 待ち" \
  bash -c 'mkdir -p .github/workflows &&
           printf "jobs:\n  t:\n    steps:\n      - run: echo build\n" > .github/workflows/ci.yml &&
           git add -A'
assert blocked "CI workflow が無い → ci-workflow-exists 待ち" \
  bash -c 'mkdir -p scripts && touch scripts/test-foo.sh && git add -A'

check_id=pr-title-lint
assert blocked "CI workflow が無ければ PR タイトル lint は判定できない" true

check_id=scheduled-freshness
assert blocked "CI workflow が無ければ定期実行は判定できない" true

check_id=gitignore-covers-env
assert blocked ".gitignore が無い → gitignore-exists 待ち" true

# 境界: 前提がリポの性質 (タグを打つかどうか) の項目は blocked にしない。前提が埋まる契機が
# 標準の側に無く、blocked にすると「いつか判定される」保留が永久に溜まる
check_id=changelog-exists
assert skip "タグが無いリポの CHANGELOG は skip のまま" true

# 保留の行は前提の id を detail に持ち、fix は持たない (当てる先は前提側の項目にある)
blocked_dir="$tmp/blocked-detail"
mkdir -p "$blocked_dir"
( cd "$blocked_dir" && git init -q -b main && git commit -q --allow-empty -m init ) >/dev/null 2>&1
out=$( cd "$blocked_dir" && REPO_STANDARDS_JSON="$manifest" bash "$target" )
got=$(jq -r 'select(.id == "gitignore-covers-env") | .detail' <<<"$out")
if grep -q 'gitignore-exists 待ち' <<<"$got"; then
  echo "  [ok]   blocked の detail に前提の id が入る → $got"
else
  echo "  [FAIL] blocked の detail → 期待 gitignore-exists 待ち を含む / 実際 $got"
  failures=$((failures + 1))
fi
got=$(jq -r 'select(.id == "gitignore-covers-env") | .fix // ""' <<<"$out")
if [ -z "$got" ]; then
  echo "  [ok]   blocked に fix は付かない"
else
  echo "  [FAIL] blocked に fix が付いている → $got"
  failures=$((failures + 1))
fi

# 出力契約: status は語彙の内側だけ (blocked を足したので契約側も追随する)
bad=$(jq -r 'select(.id != "_meta") | .status' <<<"$out" \
  | grep -cvE '^(ok|ng|warn|blocked|skip|manual)$')
if [ "$bad" = "0" ]; then
  echo "  [ok]   契約外の status が無い"
else
  echo "  [FAIL] 契約外の status が $bad 件"
  failures=$((failures + 1))
fi

echo
echo "builtin_no_committed_secrets (除外パターンの境界):"
check_id=no-committed-secrets

# 正常系: 秘密ファイル候補が追跡されていない
assert ok "普通のファイルだけ" \
  bash -c 'echo hi > README.md && git add -A'

# 失敗系: .env そのもの / 拡張子つき / 深い階層の秘密ファイル
assert warn ".env を追跡している" \
  bash -c 'echo "K=v" > .env && git add -f .env'

assert warn ".env.production を追跡している" \
  bash -c 'echo "K=v" > .env.production && git add -f .env.production'

assert warn "サブディレクトリの秘密鍵 (*.pem)" \
  bash -c 'mkdir -p certs && echo x > certs/server.pem && git add -A'

assert warn "credentials.json を追跡している" \
  bash -c 'mkdir -p config && echo "{}" > config/gcp-credentials.json && git add -A'

# 境界値: 雛形は秘密でないので除外する (3 つの綴りすべて)
assert ok ".env.example / .sample / .template は除外" \
  bash -c 'for s in example sample template; do echo "K=" > ".env.$s"; done && git add -A'

# 境界値: 公開鍵は秘密ではない (id_rsa の前方一致で拾わない)
assert ok "id_rsa.pub は拾わない" \
  bash -c 'mkdir -p keys && echo x > keys/id_rsa.pub && git add -A'

# 境界値: 追跡されていなければ検出しない (ローカルに置くのは正しい運用)
assert ok "追跡していない .env は対象外" \
  bash -c 'echo "K=v" > .env'

echo
echo "builtin_no_stale_branches (30 日境界):"
check_id=no-stale-branches

# リモート追跡 ref を任意の日付で作る。@<epoch> 形式は macOS / GNU 双方で通る
mk_remote_branch() { # <name> <何日前>
  local ts; ts=$(( $(date +%s) - $2 * 86400 ))
  GIT_COMMITTER_DATE="@$ts +0000" GIT_AUTHOR_DATE="@$ts +0000" \
    git commit -q --allow-empty -m "$1" &&
    git update-ref "refs/remotes/origin/$1" HEAD
}
export -f mk_remote_branch

# 正常系: リモートブランチが無い
assert ok "リモートブランチが無い" true

# 境界値: 29 日前は「作業中」の範囲
assert ok "29 日前のブランチは残骸としない" \
  bash -c 'mk_remote_branch feature-recent 29'

# 失敗系: 31 日前は残骸
assert warn "31 日前のブランチは残骸" \
  bash -c 'mk_remote_branch feature-old 31'

# 境界値: main / master / HEAD は長命ブランチなので古くても対象外
assert ok "origin/main は古くても対象外" \
  bash -c 'mk_remote_branch main 400'

assert ok "origin/master は古くても対象外" \
  bash -c 'mk_remote_branch master 400'

echo
echo "builtin_worktrees_clean (orphan 判定):"
check_id=worktrees-clean

# 正常系: worktree を使っていない
assert ok ".claude/worktrees が無い" true

# 正常系: ディレクトリはあるが中身が無い
assert ok ".claude/worktrees が空" mkdir -p .claude/worktrees

# 失敗系: git に登録されていないディレクトリが残っている (worktree remove を忘れた状態)
assert warn "git 未登録のディレクトリが残っている" mkdir -p .claude/worktrees/leftover

echo
echo "builtin_worktrees_clean (容量と安全に消せる候補):"

# しきい値 (本体 + 3) を超える worktree を用意し、消せる / 消せないを 1 リポに揃える。
#   gone-clean    : upstream が消えていて未コミットの変更も無い     → 候補
#   gone-dirty    : upstream は消えているが未コミットの変更がある   → 候補外
#   gone-env      : upstream は消えているが .env (ignored) を持つ   → 候補外 (再生成できない)
#   alive         : upstream が生きている (作業中)                  → 候補外
wt_dir="$tmp/worktrees"
mkdir -p "$wt_dir"
(
  cd "$wt_dir" && git init -q -b main && git commit -q --allow-empty -m init &&
  echo ".env" > .gitignore && git add -A && git commit -q -m gitignore &&
  mkdir -p .claude/worktrees && git remote add origin . &&
  for b in gone-clean gone-dirty gone-env alive; do
    git branch -q "$b"
    # upstream は config で直接張る (--set-upstream-to は remote-tracking ref を
    # 手で作っただけでは「ブランチではない」と拒否される)
    git config "branch.$b.remote" origin
    git config "branch.$b.merge" "refs/heads/$b"
    git worktree add -q ".claude/worktrees/$b" "$b"
  done &&
  # alive だけ remote-tracking ref を残す。他は PR がマージされて head ブランチが
  # 削除された後の状態 (upstream:track → [gone])
  git update-ref refs/remotes/origin/alive HEAD &&
  echo dirty > .claude/worktrees/gone-dirty/uncommitted.txt &&
  echo "K=v" > .claude/worktrees/gone-env/.env
) >/dev/null 2>&1
line=$( cd "$wt_dir" && REPO_STANDARDS_JSON="$manifest" bash "$target" \
  | jq -c 'select(.id == "worktrees-clean")' )
got=$(jq -r .status <<<"$line")
detail=$(jq -r .detail <<<"$line")

if [ "$got" = warn ]; then
  echo "  [ok]   しきい値を超えた worktree → warn"
else
  echo "  [FAIL] しきい値を超えた worktree → 期待 warn / 実際 $got"
  failures=$((failures + 1))
fi

if grep -qE '[0-9]+ MB' <<<"$detail"; then
  echo "  [ok]   個数だけでなく容量を添える → $(grep -oE '[0-9]+ MB' <<<"$detail")"
else
  echo "  [FAIL] 容量が detail に無い → $detail"
  failures=$((failures + 1))
fi

if grep -q 'gone-clean' <<<"$detail"; then
  echo "  [ok]   upstream が [gone] で clean な worktree を候補に挙げる"
else
  echo "  [FAIL] gone-clean が候補に無い → $detail"
  failures=$((failures + 1))
fi

for ng in gone-dirty gone-env alive; do
  if grep -q "$ng" <<<"$detail"; then
    echo "  [FAIL] $ng を候補に挙げてはいけない → $detail"
    failures=$((failures + 1))
  else
    echo "  [ok]   $ng は候補に挙げない"
  fi
done

check_id=adr-exists

echo
echo "正本の fix_kind を素通しする (修正側の承認粒度を決める契約):"

# 正本がまだ持たない項目では落ちる / 持つ項目ではそのまま載る、の両方を固定する
fk_dir="$tmp/fix-kind"
mkdir -p "$fk_dir"
cat > "$fk_dir/m.json" <<'EOF'
{
  "version": 1,
  "kinds": [{ "id": "generic", "marker": null }],
  "items": [
    { "id": "with-kind", "layer": "repo", "level": "required", "applies_to": ["all"],
      "check": { "type": "file_exists", "path": "README.md" },
      "why": "テスト用", "fix": "テスト用", "fix_kind": "generative" },
    { "id": "without-kind", "layer": "repo", "level": "required", "applies_to": ["all"],
      "check": { "type": "file_exists", "path": "README.md" },
      "why": "テスト用", "fix": "テスト用" }
  ]
}
EOF
mkdir -p "$fk_dir/repo"
( cd "$fk_dir/repo" && git init -q -b main && git commit -q --allow-empty -m init ) >/dev/null 2>&1
out=$( cd "$fk_dir/repo" && REPO_STANDARDS_JSON="$fk_dir/m.json" bash "$target" )
got=$(jq -r 'select(.id == "with-kind") | .fix_kind // "-"' <<<"$out")
if [ "$got" = "generative" ]; then
  echo "  [ok]   fix_kind がある項目は素通しする → $got"
else
  echo "  [FAIL] fix_kind がある項目 → 期待 generative / 実際 $got"
  failures=$((failures + 1))
fi
got=$(jq -r 'select(.id == "without-kind") | has("fix_kind")' <<<"$out")
if [ "$got" = "false" ]; then
  echo "  [ok]   fix_kind が無い項目には付けない → 出力に無い"
else
  echo "  [FAIL] fix_kind が無い項目 → 期待 false / 実際 $got"
  failures=$((failures + 1))
fi

echo
echo "前提不足時の報告 (出力契約の範囲内で):"

# git リポ外でも契約内の status/level で報告する (#34 で塞いだ穴: error/- を出していた)
dir="$tmp/not-a-repo"
mkdir -p "$dir"
line=$( cd "$dir" && REPO_STANDARDS_JSON="$manifest" bash "$target" \
  | jq -c 'select(.id == "not-a-git-repo")' )
if [ "$(jq -r .status <<<"$line")" = "ng" ] && [ "$(jq -r .level <<<"$line")" = "required" ]; then
  echo "  [ok]   git リポ外 → required/ng で報告"
else
  echo "  [FAIL] git リポ外 → 期待 required/ng / 実際 $(jq -r '"\(.level)/\(.status)"' <<<"$line")"
  failures=$((failures + 1))
fi

# コミットが 1 件も無いリポは監査でなく雛形生成の段階。全項目を並べても「まだ何も無い」の
# 言い換えにしかならず、LLM 判定と反証がまるごと空振りするので、ここで打ち切って
# repo-bootstrap へ渡す。「打ち切る」ことまで固定しないと空振りのコストが戻ってくる
uninit_out() { # <セットアップコマンド...>
  local dir="$tmp/uninit-$RANDOM"
  mkdir -p "$dir"
  ( cd "$dir" && git init -q -b main && "$@" ) >/dev/null 2>&1
  ( cd "$dir" && REPO_STANDARDS_JSON="$manifest" bash "$target" )
}

out=$(uninit_out true)
line=$(jq -c 'select(.id == "repo-uninitialized")' <<<"$out")
if [ "$(jq -r .status <<<"$line")" = "ng" ] && [ "$(jq -r .level <<<"$line")" = "required" ]; then
  echo "  [ok]   コミットが 1 件も無い → required/ng で報告"
else
  echo "  [FAIL] コミットが 1 件も無い → 期待 required/ng / 実際 $(jq -r '"\(.level)/\(.status)"' <<<"$line")"
  failures=$((failures + 1))
fi

# fix が次の一手 (repo-bootstrap) を指していないと、受け手はどこへ行けばよいか分からない
if grep -q 'repo-bootstrap' <<<"$(jq -r .fix <<<"$line")"; then
  echo "  [ok]   fix が repo-bootstrap を指す"
else
  echo "  [FAIL] fix が repo-bootstrap を指していない → $(jq -r .fix <<<"$line")"
  failures=$((failures + 1))
fi

# 打ち切りの実効: _meta (レポートのヘッダ) 以外はこの 1 件だけ
n=$(jq -r 'select(.id != "_meta") | .id' <<<"$out" | grep -c .)
if [ "$n" = "1" ]; then
  echo "  [ok]   他の項目は並べずに打ち切る"
else
  echo "  [FAIL] 打ち切っていない → $n 件出力: $(jq -r 'select(.id != "_meta") | .id' <<<"$out" | tr '\n' ' ')"
  failures=$((failures + 1))
fi

# レポートのヘッダは残す (打ち切っても対象リポがどれかは示す)
if [ "$(jq -r 'select(.id == "_meta") | .kind' <<<"$out")" = "generic" ]; then
  echo "  [ok]   打ち切っても _meta は出す"
else
  echo "  [FAIL] _meta が出ていない"
  failures=$((failures + 1))
fi

# 境界値: git init しただけの既存ディレクトリ (未追跡ファイルはあるがコミットは無い)
got=$(jq -r 'select(.id == "repo-uninitialized") | .status' <<<"$(uninit_out bash -c 'echo hi > README.md')")
if [ "$got" = "ng" ]; then
  echo "  [ok]   未追跡ファイルがあってもコミット 0 件なら打ち切る"
else
  echo "  [FAIL] 未追跡ファイルがあるケース → 期待 ng / 実際 $got"
  failures=$((failures + 1))
fi

# 正常系: コミットが 1 件でもあれば通常の監査に戻る (打ち切りが広がりすぎないこと)
got=$(jq -r 'select(.id == "repo-uninitialized") | .id' <<<"$(uninit_out git commit -q --allow-empty -m init)")
if [ -z "$got" ]; then
  echo "  [ok]   コミットが 1 件あれば打ち切らない"
else
  echo "  [FAIL] コミットがあるのに打ち切った"
  failures=$((failures + 1))
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK"
