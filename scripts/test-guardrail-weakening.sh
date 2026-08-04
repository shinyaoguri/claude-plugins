#!/usr/bin/env bash
# check-guardrail-weakening.sh の検出テスト。
# 一時 git リポジトリに base コミットと変更コミットを作り、検出結果を検証する。
#
#   bash scripts/test-guardrail-weakening.sh
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
target="$repo_root/scripts/check-guardrail-weakening.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

failures=0

# case <ケース名> <期待 (detect|clean)> <変更を作るコマンド...>
# base コミットには「守り」のファイル一式を置いてある
case_run() {
  local name=$1 want=$2; shift 2
  local dir="$tmp/case-$RANDOM"
  mkdir -p "$dir/scripts" "$dir/.github/workflows"

  (
    cd "$dir" || exit 1
    git init -q -b main
    git config user.email t@example.com
    git config user.name t
    # 署名設定はグローバルから継承される。1Password の SSH agent がロック状態だと
    # プロンプトで commit が落ちるので、テスト用リポでは明示的に切る
    git config commit.gpgsign false
    git config tag.gpgsign false

    # base: テスト・チェックスクリプト・CI が揃っている状態。
    # foo_test.py を 20 行にしてあるのは、行数減少のしきい値 (差し引き 10 行) の
    # 上下を撃ち分けるため
    seq 1 20 | sed 's/^/assert /' > scripts/foo_test.py
    printf '#!/bin/sh\nexit 0\n' > scripts/check-foo.sh
    printf 'jobs:\n  a:\n    steps:\n      - name: test\n        run: ./scripts/check-foo.sh\n' \
      > .github/workflows/ci.yml
    git add -A && git commit -qm base
    git branch base-ref
  ) || { echo "  [ERROR] $name: base 作成失敗"; failures=$((failures + 1)); return; }

  ( cd "$dir" && "$@" && git add -A && git commit -qm change ) >/dev/null 2>&1 \
    || { echo "  [ERROR] $name: 変更コミット失敗"; failures=$((failures + 1)); return; }

  local out got
  out=$( cd "$dir" && BASE_REF=base-ref bash "$target" 2>&1 )
  if grep -q '^WEAKENING:' <<<"$out"; then got=detect; else got=clean; fi

  if [ "$got" = "$want" ]; then
    echo "  [ok]   $name → $got"
  else
    echo "  [FAIL] $name → 期待 $want / 実際 $got"
    sed 's/^/         | /' <<<"$out"
    failures=$((failures + 1))
  fi
}

echo "check-guardrail-weakening:"

# --- 検出されるべき変更 ---
case_run "テストファイルの削除" detect rm scripts/foo_test.py
case_run "チェックスクリプトの削除" detect rm scripts/check-foo.sh
case_run "テストの行数が大きく減る" detect \
  bash -c 'seq 1 3 | sed "s/^/assert /" > scripts/foo_test.py'
case_run "continue-on-error の追加" detect \
  bash -c 'printf "jobs:\n  a:\n    steps:\n      - name: test\n        continue-on-error: true\n        run: ./scripts/check-foo.sh\n" > .github/workflows/ci.yml'
case_run "|| true の追加" detect \
  bash -c 'printf "#!/bin/sh\n./scripts/check-foo.sh || true\n" > scripts/check-foo.sh'
case_run "pytest の skip 追加" detect \
  bash -c '{ echo "@pytest.mark.skip"; seq 1 20 | sed "s/^/assert /"; } > scripts/foo_test.py'
case_run "CI ステップの削除" detect \
  bash -c 'printf "jobs:\n  a:\n    steps: []\n" > .github/workflows/ci.yml'

# --- 検出されるべきでない変更 (誤検知の確認) ---
case_run "テストを増やす" clean \
  bash -c 'seq 1 21 | sed "s/^/assert /" > scripts/foo_test.py'
case_run "守りと無関係なファイルの追加" clean \
  bash -c 'printf "# doc\n" > README.md'
case_run "テストの小さな書き換え" clean \
  bash -c 'seq 1 20 | sed "s/^/assert /" | sed "s/^assert 9$/assert 99/" > scripts/foo_test.py'

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK"
