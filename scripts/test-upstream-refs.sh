#!/usr/bin/env bash
# check-upstream-refs.sh --coverage の判定テスト。
# 一時ディレクトリに plugins/ と upstream-refs.json の最小構成を組み立て、
# 正本のスクリプトをそのまま実行して exit code を検証する
# (トークン抽出の正規表現ごと守るため、関数を source しない)。
#
#   bash scripts/test-upstream-refs.sh
#
# --exists は上流リポへのネットワークアクセスが要るためここでは検証しない (週次 CI が実挙動)。
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
target="$repo_root/scripts/check-upstream-refs.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

failures=0
seq_no=0

# case_run <ケース名> <期待 (ok|ng)> <SKILL.md 本文> <upstream-refs.json の中身> [同梱ファイル...]
#   ok = マニフェストが本文の参照を網羅している / ng = 未登録の参照を検出する
#   同梱ファイル = plugins/sample/ からの相対パス。疑似リポに空ファイルとして置く
#   (実体が同梱されているトークンは定義上「上流参照」ではないので検査対象から外れる)
case_run() {
  local name=$1 want=$2 body=$3 manifest=$4
  shift 4
  seq_no=$((seq_no + 1))
  local dir="$tmp/case-$seq_no"

  mkdir -p "$dir/scripts" "$dir/plugins/sample/skills/sample"
  # スクリプトは自身の親ディレクトリを作業ディレクトリにするので、コピー先が疑似リポになる
  cp "$target" "$dir/scripts/check-upstream-refs.sh"
  printf '%s\n' "$body" > "$dir/plugins/sample/skills/sample/SKILL.md"
  printf '%s\n' "$manifest" > "$dir/upstream-refs.json"

  local bundled_file
  for bundled_file in "$@"; do
    mkdir -p "$dir/plugins/sample/$(dirname "$bundled_file")"
    : > "$dir/plugins/sample/$bundled_file"
  done

  # exit code だけで判定すると「NG 検出」と「スクリプト自体の異常終了」が区別できないので、
  # 未検出の異常終了は error として必ず落とす
  local out got
  if out=$(bash "$dir/scripts/check-upstream-refs.sh" --coverage 2>&1); then
    got=ok
  elif grep -q '^NG:' <<<"$out"; then
    got=ng
  else
    got=error
  fi

  if [ "$got" = "$want" ]; then
    echo "  [ok]   $name → $got"
  else
    echo "  [FAIL] $name → 期待 $want / 実際 $got"
    sed 's/^/         | /' <<<"$out"
    failures=$((failures + 1))
  fi
}

echo "check-upstream-refs --coverage:"

manifest_setup='{"shinyaoguri/setup": ["tasks/claude.yml", "claude/CLAUDE.md"]}'

# --- .yml 参照 (Issue #42: token_re が .yml をほぼ拾えず、未登録でも素通りしていた) ---
case_run "登録済みの .yml 参照" ok \
  '詳細は setup リポの tasks/claude.yml を見る。' \
  "$manifest_setup"
case_run "未登録の .yml 参照" ng \
  'setup リポで `ansible-playbook playbook_sillicon_mac.yml --tags claude`。' \
  "$manifest_setup"
case_run "未登録の .yml 参照 (ディレクトリ付きで言及)" ng \
  '起票テンプレートは .github/ISSUE_TEMPLATE/improvement.yml に従う。' \
  "$manifest_setup"
case_run "未登録の .yaml 参照 (拡張子ゆれ)" ng \
  'ワークフローの正本は .github/workflows/release.yaml。' \
  "$manifest_setup"

# --- 既存トークン種別の回帰確認 ---
case_run "登録済みの docs 参照" ok \
  'リリース手順は docs/releasing.md にある。' \
  '{"shinyaoguri/metaphor": ["docs/releasing.md"]}'
case_run "未登録の docs 参照" ng \
  'リリース手順は docs/releasing.md にある。' \
  '{"shinyaoguri/metaphor": ["CONTRACT.md"]}'
case_run "プラグイン同梱スクリプト (rs-) は上流参照ではない" ok \
  'bash "${CLAUDE_PLUGIN_ROOT}/scripts/rs-doctor-env.sh" を実行する。' \
  "$manifest_setup"
case_run "上流参照を含まない本文" ok \
  'cwd は問わない。診断結果を一覧で提示する。' \
  "$manifest_setup"

# --- 同梱ファイル判定 (rs- プレフィックスを持たない hooks/scripts/*.sh を本文が指した回) ---
case_run "同梱 hook スクリプト (rs- なし) は上流参照ではない" ok \
  '掃除は SessionStart hook の hooks/scripts/stale-branch-sweep.sh が行う。' \
  "$manifest_setup" \
  hooks/scripts/stale-branch-sweep.sh
case_run "同梱されていない scripts/*.sh は従来どおり検出する" ng \
  '契約の検査は scripts/check-contract.sh が担当する。' \
  "$manifest_setup"

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK"
