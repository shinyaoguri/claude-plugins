#!/usr/bin/env bash
# PreToolUse(Edit|Write|NotebookEdit) hook — 同じリポジトリの**別 worktree** へ書き込む
# 取り違えを水際で止める。
#
# worktree を常用すると、並行するセッションがそれぞれ自分のツリーを持ち、同名のファイルが
# 同じ相対パスで何本も存在する。その状態でメイン作業ツリーの絶対パスで Read → Edit して
# しまうと、変更はブランチではなくメインツリーへ落ちる (mokume-metal/mokume#499 で実際に
# 起きた)。Edit の「事前に Read が必要」というガードは、同じ (間違った) ファイルを読んで
# いれば通ってしまうので取り違えを検知できない。パスは自己申告で、しかも両ツリーに同名の
# ファイルがあるため、間違いが目に見えない。
#
# 「編集先はいまのセッションの worktree の中」はリポジトリの状態から機械的に決まり、
# どのリポジトリでも判定が変わらない。リポジトリの規約ではなく道具なので、ここで配る
# (ADR 0021 決定 2)。mokume が持っていた scripts/worktree-path-guard.sh を移したもの。
#
# 判定は「同じリポジトリの別 worktree か」だけを見る:
#   - 同じ worktree の中             → 素通し
#   - 別のリポジトリ (submodule 含む) → 素通し (正当な作業。ここで止める理由がない)
#   - git 管理外                     → 素通し (スクラッチパッド・セッションの記録など)
#   - 同じリポジトリの別 worktree     → deny (訂正後のパスを添えて返す)
#
# ask ではなく deny なのは、取り違えなら正しいパスへ直せばその場で続行できるから
# (人を呼ぶ必要がない)。本当に別ツリーを触りたいときは、そのツリーで作業している
# セッションから行う — 並行セッションが同じファイルを取り合う状況こそ避けたい。
#
# 読めないものはすべて素通し (fail open)。ガードが壊れて書き込みが一切できなくなるほうが
# 害が大きい。
#
# 契約: stdin に PreToolUse の JSON。素通しは無出力 + 終了コード 0。
# 呼び出し口は hooks/hooks.json、テストは scripts/test-rs-worktree-guard.sh。
set -uo pipefail

# 一時的に止めたいときの逃げ道 (このフックは全リポで動くため。RS_PLAN_GATE と対称)
[ "${RS_WORKTREE_GUARD:-1}" = "0" ] && exit 0

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

# payload に cwd が無いホストでも効くよう、プロセスの cwd へ倒す
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)
[ -n "$cwd" ] || cwd=$PWD

# Edit/Write は file_path、NotebookEdit は notebook_path。書き込み先を持たないツールは素通し
target=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' 2>/dev/null)
[ -n "$target" ] || exit 0

# 実在する最も近い親ディレクトリの物理パス (新規ファイルの作成にも効かせるため、
# ファイル自身の実在は前提にしない)
resolve_dir() {
  local dir=$1 parent
  while [ ! -d "$dir" ]; do
    parent=$(dirname "$dir")
    [ "$parent" = "$dir" ] && return 1
    dir=$parent
  done
  (cd "$dir" 2>/dev/null && pwd -P)
}

case $target in
  /*) ;;
  *) target=$cwd/$target ;;
esac

target_dir=$(resolve_dir "$(dirname "$target")") || exit 0
cwd_dir=$(resolve_dir "$cwd") || exit 0

target_root=$(git -C "$target_dir" rev-parse --show-toplevel 2>/dev/null) || exit 0
current_root=$(git -C "$cwd_dir" rev-parse --show-toplevel 2>/dev/null) || exit 0
target_root=$(resolve_dir "$target_root") || exit 0
current_root=$(resolve_dir "$current_root") || exit 0

[ "$target_root" = "$current_root" ] && exit 0

# worktree は共通の .git ディレクトリを指す。ここが一致するときだけ「同じリポジトリの
# 別 worktree」= 取り違え。別リポジトリ (submodule やまったく別のプロジェクト) は素通し
common_of() {
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null
}
target_common=$(common_of "$target_dir")
current_common=$(common_of "$cwd_dir")
[ -n "$target_common" ] && [ -n "$current_common" ] || exit 0
target_common=$(resolve_dir "$target_common") || exit 0
current_common=$(resolve_dir "$current_common") || exit 0
[ "$target_common" = "$current_common" ] || exit 0

# 訂正後のパスを添える。取り違えの実体は「同じ相対パスを別のツリーに向けた」なので、
# ツリーの根だけ差し替えれば意図した先になる
relative=${target_dir#"$target_root"/}
[ "$relative" = "$target_dir" ] && relative=""  # 対象がツリー直下
suggested=$current_root${relative:+/$relative}/$(basename "$target")

note="（訂正先はまだ存在しません。新規作成ならこのままで問題ありません）"
[ -e "$suggested" ] && note="（訂正先は存在します）"

reason=$(cat <<EOF
同じリポジトリの**別 worktree** へ書き込もうとしています。パスの取り違えです。

  このセッションの worktree : $current_root
  書き込もうとした worktree : $target_root

このまま書くと、変更はいまのブランチではなく別のツリーへ落ちます (同名のファイルが
両方にあるため、差分を見るまで気付けません)。

訂正後のパス:
  $suggested
$note

本当に別の worktree を変更する必要があるなら、そのツリーで作業しているセッションから
行ってください。一時的に止めるなら RS_WORKTREE_GUARD=0。
EOF
)

jq -n --arg r "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
exit 0
