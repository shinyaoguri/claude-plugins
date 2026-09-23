#!/usr/bin/env bash
# worktree-guard.sh の分岐テスト。
# 使い捨ての git リポ (メイン作業ツリー + linked worktree) と別リポを組み、hook の契約
# (終了コードと stdout の permissionDecision) をそのまま検証する (Claude セッションにも
# GitHub にも触らない)。
#
#   bash scripts/test-rs-worktree-guard.sh
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
hook="$repo_root/plugins/repo-standards/hooks/scripts/worktree-guard.sh"

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

# symlink を挟む環境 (/tmp → /private/tmp) でも hook の返すパスと揃うよう、物理パスで持つ
sandbox=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$sandbox"' EXIT
: > "$sandbox/empty-gitconfig"
export GIT_CONFIG_GLOBAL="$sandbox/empty-gitconfig"
unset RS_WORKTREE_GUARD

# メイン作業ツリー + そこから生やした worktree。実運用と同じく .claude/worktrees/ に置く
main="$sandbox/repo"
git -c init.defaultBranch=main init -q "$main"
printf 'main\n' > "$main/app.swift"
git -C "$main" add -A
git -C "$main" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -q -m init
linked="$main/.claude/worktrees/wt"
git -C "$main" worktree add -q -b feat "$linked"

# まったく別のリポジトリ (別プロジェクトの編集は止めない)
other="$sandbox/other"
git init -q "$other"
printf 'other\n' > "$other/app.swift"

plain="$sandbox/plain"
mkdir -p "$plain"

# run <cwd> <tool> <入力の JSON> — hook を叩いて stdout を返す
run() {
  printf '{"tool_name":"%s","cwd":"%s","tool_input":%s}' "$2" "$1" "$3" \
    | (cd "$1" && bash "$hook") 2>"$sandbox/err"
}

# 素通し (無出力) なら pass、判定を返したらその permissionDecision
decision() {
  local out
  out=$(run "$@")
  if [ -z "$out" ]; then echo pass; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision'; fi
}

# 差し戻しの理由に訂正後のパスが入っているか
suggests() { # $1=cwd $2=file_path $3=期待する訂正先
  run "$1" Edit "{\"file_path\":\"$2\"}" | jq -r '.hookSpecificOutput.permissionDecisionReason' \
    | grep -qF "$3" && echo yes || echo no
}

echo "== 素通し =="

check "同じ worktree の中" pass \
  "$(decision "$linked" Edit "{\"file_path\":\"$linked/app.swift\"}")"
check "同じ worktree の新規ファイル" pass \
  "$(decision "$linked" Write "{\"file_path\":\"$linked/new/x.swift\"}")"
check "別のリポジトリ" pass \
  "$(decision "$linked" Edit "{\"file_path\":\"$other/app.swift\"}")"
check "git 管理外" pass \
  "$(decision "$linked" Write "{\"file_path\":\"$plain/note.md\"}")"
check "書き込み先を持たないツール" pass \
  "$(decision "$linked" Bash '{"command":"ls"}')"
check "セッションが git 管理外" pass \
  "$(decision "$plain" Edit "{\"file_path\":\"$main/app.swift\"}")"
check "逃げ道 RS_WORKTREE_GUARD=0" pass \
  "$(RS_WORKTREE_GUARD=0 decision "$linked" Edit "{\"file_path\":\"$main/app.swift\"}")"

echo "== 止める =="

check "linked からメインツリーを掴む" deny \
  "$(decision "$linked" Edit "{\"file_path\":\"$main/app.swift\"}")"
check "  訂正後のパスを添える" yes \
  "$(suggests "$linked" "$main/app.swift" "$linked/app.swift")"
check "メインから linked を掴む (逆向き)" deny \
  "$(decision "$main" Edit "{\"file_path\":\"$linked/app.swift\"}")"
check "  訂正後のパスを添える" yes \
  "$(suggests "$main" "$linked/app.swift" "$main/app.swift")"
mkdir -p "$main/Sources/Deep"
printf 'x\n' > "$main/Sources/Deep/File.swift"
check "深い位置のファイルは相対位置を保って訂正する" yes \
  "$(suggests "$linked" "$main/Sources/Deep/File.swift" "$linked/Sources/Deep/File.swift")"
check "別ツリーの新規ファイル" deny \
  "$(decision "$linked" Write "{\"file_path\":\"$main/brand-new.swift\"}")"
check "NotebookEdit も見る" deny \
  "$(decision "$linked" NotebookEdit "{\"notebook_path\":\"$main/n.ipynb\"}")"

# cwd を payload に載せないホストでも、プロセスの cwd で判定する
out=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$main/app.swift" \
  | (cd "$linked" && bash "$hook") 2>"$sandbox/err")
check "payload に cwd が無い" deny \
  "$( [ -n "$out" ] && printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' || echo pass)"

echo
if [ "$failures" -eq 0 ]; then
  echo "ok: worktree-guard の分岐はすべて期待どおり"
else
  echo "NG: $failures 件の分岐が期待と違う"
  exit 1
fi
