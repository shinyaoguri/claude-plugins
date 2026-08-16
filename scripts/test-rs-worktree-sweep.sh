#!/usr/bin/env bash
# worktree-sweep.sh (SessionStart hook) の判定テスト。
# 使い捨ての git リポで hook を直接叩く (ネットワークにも実マシンの git 設定にも触らない)。
# 検証対象は Claude Code との契約である**終了コードと stdout の通知**、および
# prune で登録が畳まれたかどうか。gh は呼ばれない (呼ばれたら失敗する PATH で回す)。
#
#   bash scripts/test-rs-worktree-sweep.sh
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
hook="$repo_root/plugins/repo-standards/hooks/scripts/worktree-sweep.sh"

failures=0

# check <ケース名> <期待> <実際>
check() {
  if [ "$2" = "$3" ]; then
    echo "  [ok]   $1 → $3"
  else
    echo "  [FAIL] $1 → 期待 $2 / 実際 $3"
    failures=$((failures + 1))
  fi
}

# git は worktree のパスを symlink 解決済みで返すので (macOS の /var → /private/var)、
# 通知文と突き合わせられるよう最初から解決済みのパスで組み立てる
sandbox=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$sandbox"' EXIT
: > "$sandbox/empty-gitconfig"
export GIT_CONFIG_GLOBAL="$sandbox/empty-gitconfig"

# gh を呼んだら分かるようにする (この hook はネットワークにも GitHub にも触らない契約)
mkdir -p "$sandbox/bin"
cat > "$sandbox/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh called: $*" >> "$GH_STUB_LOG"
exit 1
STUB
chmod +x "$sandbox/bin/gh"
export GH_STUB_LOG="$sandbox/gh.log"
: > "$GH_STUB_LOG"
export PATH="$sandbox/bin:$PATH"

g() { git -C "$repo" -c user.email=t@example.com -c user.name=t "$@"; }
run_hook() { printf '{"cwd":"%s"}' "$repo" | "$hook" 2>/dev/null; }
registered() { g worktree list --porcelain | grep -c '^worktree ' | tr -d ' '; }

# 2 コミットの main と、それを指す origin/HEAD を持つリポを組み立てる
setup_repo() {
  repo="$sandbox/repo-$1"
  mkdir -p "$repo"
  git -c init.defaultBranch=main init -q "$repo"
  g commit -q --allow-empty -m c1
  g commit -q --allow-empty -m c2
  g update-ref refs/remotes/origin/main "$(g rev-parse HEAD)"
  g symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}

echo "worktree-sweep (SessionStart):"

# --- linked worktree が既定ブランチを掴んでいる ---
# メインチェックアウトを別ブランチへ移し、linked worktree 側に main を持たせる
# (gh pr merge の後処理が落ちる実際の形。経緯: #114)
setup_repo holder
g checkout -q -b feat/work
g worktree add -q "$sandbox/wt-holder" main
out=$(run_hook)
check "既定ブランチを掴む worktree を知らせる" "1" "$(printf '%s' "$out" | grep -c '既定ブランチ (main) を掴んでいます (1 個)')"
check "パスと復旧コマンドを添える" "1" "$(printf '%s' "$out" | grep -c "git worktree remove \"$sandbox/wt-holder\"")"
check "知らせても削除しない" "2" "$(registered)"
run_hook >/dev/null 2>&1
check "知らせても exit 0" "0" "$?"

# --- 掴んでいるのがメインチェックアウトだけ (正常な状態) ---
setup_repo main-only
g worktree add -q "$sandbox/wt-side" -b side
out=$(run_hook)
check "メインチェックアウトの既定ブランチは指摘しない" "" "$out"

# --- detached / 別ブランチの linked worktree ---
setup_repo other-branch
g worktree add -q "$sandbox/wt-detached" --detach HEAD
out=$(run_hook)
check "detached な worktree は指摘しない" "" "$out"

# --- origin/HEAD が無いリポ (main へフォールバック) ---
setup_repo no-origin-head
g symbolic-ref -d refs/remotes/origin/HEAD
g update-ref -d refs/remotes/origin/main
g checkout -q -b feat/work
g worktree add -q "$sandbox/wt-fallback" main
out=$(run_hook)
check "origin/HEAD が無くても main を掴む worktree を知らせる" "1" "$(printf '%s' "$out" | grep -c '既定ブランチ (main) を掴んでいます')"

# --- 既定ブランチが main でないリポ ---
setup_repo trunk
g branch -m main trunk
g update-ref -d refs/remotes/origin/main
g update-ref refs/remotes/origin/trunk "$(g rev-parse HEAD)"
g symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
g checkout -q -b feat/work
g worktree add -q "$sandbox/wt-trunk" trunk
out=$(run_hook)
check "既定ブランチが main でなくても判定できる" "1" "$(printf '%s' "$out" | grep -c '既定ブランチ (trunk) を掴んでいます')"

# --- 複数本 ---
setup_repo many
g checkout -q -b feat/work
g worktree add -q "$sandbox/wt-many-1" main
g worktree add -q "$sandbox/wt-many-2" --detach HEAD
out=$(run_hook)
check "掴んでいる本数を数える" "1" "$(printf '%s' "$out" | grep -c '(1 個)')"

# --- prune ---
setup_repo prune
g worktree add -q "$sandbox/wt-gone" -b gone-dir
rm -rf "$sandbox/wt-gone"
run_hook >/dev/null
check "実ディレクトリが消えた登録を畳む" "1" "$(registered)"

# --- 逃げ道 ---
setup_repo optout
g checkout -q -b feat/work
g worktree add -q "$sandbox/wt-optout" main
out=$(printf '{"cwd":"%s"}' "$repo" | RS_WORKTREE_SWEEP=0 "$hook" 2>/dev/null)
check "RS_WORKTREE_SWEEP=0 なら無出力" "" "$out"

# --- GitHub には触らない ---
check "gh を呼ばない" "0" "$(wc -l < "$GH_STUB_LOG" | tr -d ' ')"

# --- 異常系 ---
printf '{"cwd":"%s/does-not-exist"}' "$sandbox" | "$hook" >/dev/null 2>&1
check "git リポでない cwd でも exit 0" "0" "$?"
printf 'not json' | "$hook" >/dev/null 2>&1
check "壊れた JSON でも exit 0" "0" "$?"
printf '{}' | "$hook" >/dev/null 2>&1
check "cwd 欠落でも exit 0" "0" "$?"

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK"
