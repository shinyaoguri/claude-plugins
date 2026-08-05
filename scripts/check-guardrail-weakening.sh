#!/usr/bin/env bash
# 「守り」(テスト・CI・チェックスクリプト) を弱める変更を PR の diff から検出する。
# 比較先は $BASE_REF (既定 origin/main)。
#
# 他の check-*.sh と規約が違う。これはゲートではなくレポートであり、検出しても
# exit 0 を保つ (非 0 で落ちるのはスクリプト自体の異常のみ)。
# 理由: 正当な理由で検査を消すことはある。止めるのではなく「こっそり緩めることが
# 成立しない」状態を作るのが目的なので、ブロックせず可視化に倒す (Issue #18)。
#
# 誤検知は許容する。ブロックしない以上ノイズの実害は小さく、検出漏れの方が問題。
#
# 検出項目:
#   1. テスト・チェックスクリプト・CI workflow の削除
#   2. テストファイルの行数の顕著な減少 (差し引き 10 行以上)
#   3. 検査を素通しさせる指示の新規追加 (continue-on-error / skip / xfail / || true 等)
#   4. CI workflow からのステップ削除
#
# CI 用に $GITHUB_OUTPUT があれば found=true|false を書く (ローカルでは無視される)。
set -uo pipefail
# 他の check-*.sh はこのリポ専用なので $0 基準で cd するが、これは PR の diff を見る
# 検査なので cwd の git リポジトリを対象にする (rs-audit-repo.sh と同じ方式)
cd "$(git rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "NG: git リポジトリではない" >&2; exit 1; }

base="${BASE_REF:-origin/main}"
git rev-parse --verify -q "$base^{commit}" >/dev/null \
  || { echo "NG: 比較先 $base が解決できない (fetch 済みか確認)" >&2; exit 1; }

# 守りに当たるファイルか。テスト本体・チェックスクリプト・CI・hook・監査スクリプト
is_guard() {
  case "$1" in
    *test*|*Test*|*spec*|*_test.py|*.test.ts|*.test.js|*.spec.ts) return 0 ;;
    scripts/check-*.sh|.github/workflows/*) return 0 ;;
    # プラグイン同梱スクリプト。監査ロジック (rs-audit-*.sh の builtin など) を
    # 削る変更も「守りを弱める」に当たる
    plugins/*/scripts/*.sh) return 0 ;;
    *hooks/*) return 0 ;;
    *) return 1 ;;
  esac
}

found=0
report() { echo "WEAKENING: $*"; found=1; }

# --- 1. 守りのファイルそのものの削除 -------------------------------------------
while IFS= read -r f; do
  [ -n "$f" ] || continue
  is_guard "$f" && report "削除: $f"
done < <(git diff --diff-filter=D --name-only "$base"...HEAD)

# --- 2. テストファイルの行数の顕著な減少 ---------------------------------------
# リファクタで減ることもあるので、差し引き 10 行以上のときだけ拾う
while IFS=$'\t' read -r added removed path; do
  [ -n "${path:-}" ] || continue
  [ "$added" = "-" ] && continue          # バイナリ
  is_guard "$path" || continue
  if [ $((removed - added)) -ge 10 ]; then
    report "行数の減少: $path (+$added / -$removed)"
  fi
done < <(git diff --numstat --diff-filter=M "$base"...HEAD)

# --- 3. 検査を素通しさせる指示の新規追加 ---------------------------------------
# 追加行 (^+) だけを見る。既存の記述は対象外。
# パターンにバックスラッシュを使わないのは、awk -v の変数展開でエスケープが
# 解釈され (\| が | になり) 正規表現が壊れるため。文字クラスで代用する。
# \b も mawk (ubuntu runner の awk) に無いので、前後の文字種で代用する
skip_re='continue-on-error|--no-verify|[|][|] *true|@unittest[.]skip|@pytest[.]mark[.](skip|xfail)|(^|[^a-zA-Z_.])(it|test|describe)[.](skip|todo)|XCTSkip|t[.]Skip[(]|--ignore-scripts|SKIP=|skipTests'
while IFS= read -r line; do
  [ -n "$line" ] || continue
  report "検査の素通し: $line"
done < <(
  # 検査ロジック自身とそのテストは、パターン文字列を含むため自己検出になるので除く
  git diff -U0 "$base"...HEAD -- '*.sh' '*.py' '*.ts' '*.js' '*.swift' '*.go' '*.yml' '*.yaml' \
    ':(exclude)scripts/check-guardrail-weakening.sh' \
    ':(exclude)scripts/test-guardrail-weakening.sh' \
    | awk -v re="$skip_re" '
        /^\+\+\+ b\// { path = substr($0, 7); next }
        /^\+/ && !/^\+\+\+/ {
          line = substr($0, 2)
          if (line ~ re) printf "%s: %s\n", path, substr(line, 1, 120)
        }'
)

# --- 4. CI workflow からのステップ削除 -----------------------------------------
while IFS= read -r line; do
  [ -n "$line" ] || continue
  report "CI ステップの削除: $line"
done < <(
  git diff -U0 "$base"...HEAD -- '.github/workflows/*' \
    | awk '
        /^--- a\// { path = substr($0, 7); next }
        /^-/ && !/^---/ {
          line = substr($0, 2)
          if (line ~ /^[[:space:]]*-[[:space:]]+name:/ || line ~ /^[[:space:]]*run:/)
            printf "%s: %s\n", path, substr(line, 1, 120)
        }'
)

echo
if [ "$found" -eq 1 ]; then
  echo "守りを弱める変更を検出した。意図的なら PR 本文に理由を書く (ブロックはしない)"
else
  echo "OK: guardrail-weakening (検出なし)"
fi

[ -n "${GITHUB_OUTPUT:-}" ] && echo "found=$([ "$found" -eq 1 ] && echo true || echo false)" >> "$GITHUB_OUTPUT"
exit 0
