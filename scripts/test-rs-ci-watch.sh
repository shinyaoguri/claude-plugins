#!/usr/bin/env bash
# ci-watch-mark.sh / ci-watch-stop.sh の分岐テスト。
# 使い捨ての git リポと、固定 JSON を返す gh スタブで hook を直接叩く
# (GitHub にも Claude セッションにも触らない)。git 設定も $GIT_CONFIG_GLOBAL で
# 差し替えて実マシンに依存させない。
#
#   bash scripts/test-rs-ci-watch.sh
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
hooks="$repo_root/plugins/repo-standards/hooks/scripts"
mark_hook="$hooks/ci-watch-mark.sh"
stop_hook="$hooks/ci-watch-stop.sh"

failures=0

# check <ケース名> <期待> <実際>
check() {
  if [ "$2" = "$3" ]; then
    echo "  [ok]   $1 → $3"
  else
    echo "  [FAIL] $1 → 期待 $2 / 実際 $3"
    [ -s "$sandbox/err" ] && sed 's/^/         | /' "$sandbox/err"
    failures=$((failures + 1))
  fi
}

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
: > "$sandbox/empty-gitconfig"
export GIT_CONFIG_GLOBAL="$sandbox/empty-gitconfig"

repo="$sandbox/repo"
mkdir -p "$repo" "$sandbox/bin"
git -c init.defaultBranch=main init -q "$repo"
git -C "$repo" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$repo" checkout -q -b feature/x

# gh スタブ: $GH_STUB_JSON を返す。$GH_STUB_EXIT で失敗も再現する
cat > "$sandbox/bin/gh" <<'STUB'
#!/bin/bash
[ "${GH_STUB_EXIT:-0}" = "0" ] || exit "$GH_STUB_EXIT"
cat "$GH_STUB_JSON"
STUB
chmod +x "$sandbox/bin/gh"
export PATH="$sandbox/bin:$PATH"

marker_dir="$repo/.git/claude-ci-watch"
marker="$marker_dir/sess1"

rollup() { printf '%s' "$1" > "$sandbox/pr.json"; export GH_STUB_JSON="$sandbox/pr.json"; }

put_marker() {
  mkdir -p "$marker_dir"
  printf 'branch=feature/x\nfixes=%s\nwaits=%s\n' "${1:-0}" "${2:-0}" > "$marker"
}

marker_state() { [ -f "$marker" ] && echo present || echo absent; }

run_stop() {
  printf '{"session_id":"sess1","cwd":"%s"}' "$repo" | bash "$stop_hook" 2>"$sandbox/err"
  echo $?
}

run_mark() {
  printf '{"session_id":"sess1","cwd":"%s","tool_input":{"command":"%s"}}' "$repo" "$1" \
    | bash "$mark_hook" >/dev/null 2>&1
}

# PR の JSON。$2 で author を差し替える (bot 判定の確認用)、$3 で auto-merge の
# 有無を差し替える (載っていれば gh は autoMergeRequest オブジェクトを返す)、
# $4/$5 でマージ可否を差し替える (コンフリクト判定の確認用)
open_pr() {
  cat <<EOF
{"number":1,"state":"OPEN","url":"https://example.com/pr/1",
 "author":{"login":"${2:-shinyaoguri}"},
 "autoMergeRequest":${3:-null},
 "mergeable":"${4:-MERGEABLE}","mergeStateStatus":"${5:-CLEAN}",
 "statusCheckRollup":[$1]}
EOF
}

auto_merge_on='{"enabledAt":"2026-08-16T00:00:00Z","mergeMethod":"SQUASH"}'

green='{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"u"}'
red='{"__typename":"CheckRun","name":"build-and-test","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://example.com/job/42"}'
running='{"__typename":"CheckRun","name":"build","status":"IN_PROGRESS","conclusion":null,"detailsUrl":"u"}'
red_context='{"__typename":"StatusContext","context":"legacy","state":"FAILURE","targetUrl":"u"}'

echo "ci-watch-stop.sh (Stop hook: 赤いまま終わらせない):"

rm -rf "$marker_dir"
rollup "$(open_pr "$red")"
check "印が無ければ何もしない (push していないセッション)" 0 "$(run_stop)"

put_marker
check "CI 失敗 → 継続させる" 2 "$(run_stop)"
check "  失敗ジョブ名を伝える" 0 "$(grep -q 'build-and-test' "$sandbox/err"; echo $?)"
check "  ジョブ URL を伝える" 0 "$(grep -q 'example.com/job/42' "$sandbox/err"; echo $?)"
check "  修正回数を数える" "fixes=1" "$(sed -n 's/^\(fixes=.*\)/\1/p' "$marker")"

# ローカル検証コマンドは hook が持たず CLAUDE.md へ委譲する (#86 の決定)
put_marker
run_stop >/dev/null
check "  ローカル検証は CLAUDE.md へ委譲する" 0 "$(grep -q 'CLAUDE.md に書かれた検証コマンド' "$sandbox/err"; echo $?)"
check "  赤を消すだけの対処を禁じる" 0 "$(grep -q 'テストを削る' "$sandbox/err"; echo $?)"

put_marker 3 0
check "修正 3 回で打ち切る (人間の判断へ返す)" 0 "$(run_stop)"
check "  打ち切ったら印を消す" absent "$(marker_state)"

put_marker
rollup "$(open_pr "$red_context")"
check "StatusContext 形式の失敗も拾う (境界値)" 2 "$(run_stop)"

put_marker
rollup "$(open_pr "$running,$green")"
check "CI 実行中 → 見届けさせる" 2 "$(run_stop)"
check "  待機回数を数える" "waits=1" "$(sed -n 's/^\(waits=.*\)/\1/p' "$marker")"

# 待つのは「赤を残さない」ためであって、マージのためではない。auto-merge に
# 載っていなければ、まず載せさせる (green を待って手で merge させない)
check "  auto-merge 未設定なら載せるよう促す" 0 \
  "$(grep -q 'gh pr merge 1 --squash --auto' "$sandbox/err"; echo $?)"
check "  マージのために待つ必要が無いと伝える" 0 \
  "$(grep -q 'マージのために green を待つ必要はありません' "$sandbox/err"; echo $?)"
check "  auto-merge が禁止なら設定側の問題だと伝える" 0 \
  "$(grep -q 'gh-auto-merge-enabled' "$sandbox/err"; echo $?)"

put_marker
rollup "$(open_pr "$running,$green" shinyaoguri "$auto_merge_on")"
check "CI 実行中 × auto-merge 済み → 見届けだけさせる" 2 "$(run_stop)"
check "  すでに載っているので載せ直させない" 1 \
  "$(grep -q -- '--auto' "$sandbox/err"; echo $?)"
check "  マージのために戻る必要が無いと伝える" 0 \
  "$(grep -q '戻る必要はありません' "$sandbox/err"; echo $?)"

put_marker 0 6
check "待機 6 回で打ち切る" 0 "$(run_stop)"

put_marker
rollup "$(open_pr "$green")"
check "CI 全部 green → 終わってよい" 0 "$(run_stop)"
check "  green なら印を消す" absent "$(marker_state)"

# コンフリクトすると GitHub はマージコミットを作れず、チェックが 1 件も作られない。
# 「赤も pending も無い」を green と区別できず素通りしていた (#111)
put_marker
rollup "$(open_pr "" shinyaoguri null CONFLICTING DIRTY)"
check "コンフリクト → 継続させる (checks 0 件でも素通りしない)" 2 "$(run_stop)"
check "  main の取り込みを指示する" 0 "$(grep -q 'origin/main' "$sandbox/err"; echo $?)"
check "  修正回数に数える" "fixes=1" "$(sed -n 's/^\(fixes=.*\)/\1/p' "$marker")"

# 赤より先にコンフリクトを解消させる (main を取り込むまで CI の赤を論じても仕方がない)
put_marker
rollup "$(open_pr "$red" shinyaoguri null CONFLICTING DIRTY)"
check "コンフリクト × 赤 → コンフリクトを先に差し戻す (順序の境界値)" 2 "$(run_stop)"
check "  失敗ログを読ませる手順は出さない" 1 "$(grep -q 'gh run view' "$sandbox/err"; echo $?)"

put_marker 3 0
rollup "$(open_pr "" shinyaoguri null CONFLICTING DIRTY)"
check "コンフリクトも修正 3 回で打ち切る" 0 "$(run_stop)"
check "  打ち切ったら印を消す" absent "$(marker_state)"

# コンフリクト以外にもチェックが 0 件になる道はある (トリガ条件から外れた / Actions 無効)
put_marker
rollup "$(open_pr "")"
check "チェックが 1 件も無い → green と区別して差し戻す" 2 "$(run_stop)"
check "  待ち受けさせない (0 件では gh pr checks --watch がエラー終了する)" 1 \
  "$(grep -q -- '--watch' "$sandbox/err"; echo $?)"
check "  状態を 1 回で引く手順を案内する" 0 "$(grep -q 'gh pr view 1 --json' "$sandbox/err"; echo $?)"
check "  待機回数に数える" "waits=1" "$(sed -n 's/^\(waits=.*\)/\1/p' "$marker")"

put_marker 0 6
check "チェック 0 件も待機 6 回で打ち切る" 0 "$(run_stop)"

# mergeable は GitHub が非同期に計算するので UNKNOWN を返しうる。誤検知で止めない (境界値)
put_marker
rollup "$(open_pr "$green" shinyaoguri null UNKNOWN UNKNOWN)"
check "mergeable UNKNOWN × green → 誤検知で止めない" 0 "$(run_stop)"

put_marker
rollup "$(open_pr "$red" "dependabot[bot]")"
check "bot の PR は触らない" 0 "$(run_stop)"

put_marker
rollup '{"number":1,"state":"MERGED","url":"u","author":{"login":"shinyaoguri"},"statusCheckRollup":[]}'
check "マージ済みなら終わってよい" 0 "$(run_stop)"

put_marker
export GH_STUB_EXIT=1
check "PR がまだ無いなら黙る" 0 "$(run_stop)"
unset GH_STUB_EXIT

# 全リポで動くフックなので、環境変数で止められること
put_marker
rollup "$(open_pr "$red")"
check "RS_CI_WATCH=0 なら黙る" 0 "$(RS_CI_WATCH=0 run_stop)"

echo
echo "ci-watch-mark.sh (PostToolUse: push を見たときだけ印を置く):"

rm -rf "$marker_dir"
run_mark "swift test"
check "push 以外では印を置かない (GitHub を叩かない)" absent "$(marker_state)"

run_mark "git push -u origin feature/x"
check "push したら印を置く" present "$(marker_state)"
check "  ブランチを記録する" "branch=feature/x" "$(sed -n 's/^\(branch=.*\)/\1/p' "$marker")"

rm -rf "$marker_dir"
RS_CI_WATCH=0 run_mark "git push"
check "RS_CI_WATCH=0 なら印を置かない" absent "$(marker_state)"

rm -rf "$marker_dir"
git -C "$repo" checkout -q main
run_mark "git push"
check "main では印を置かない (PR を経由しない)" absent "$(marker_state)"
git -C "$repo" checkout -q feature/x

# git 管理外のディレクトリから呼ばれても落ちない (全プロジェクトで動くため。境界値)
rm -rf "$marker_dir"
mkdir -p "$sandbox/plain"
printf '{"session_id":"sess1","cwd":"%s","tool_input":{"command":"git push"}}' "$sandbox/plain" \
  | bash "$mark_hook" >/dev/null 2>&1
check "git リポでなくても落ちない" 0 $?

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK"
