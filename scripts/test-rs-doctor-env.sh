#!/usr/bin/env bash
# rs-doctor-env.sh の判定テスト。マシン環境に依存させないため、$HOME を一時ディレクトリへ
# 隔離して ~/.claude と ~/.setup を組み立て、$GIT_CONFIG_GLOBAL で git 設定を差し替え、
# $RS_GH_AUTH_STATUS に gh auth status の出力を注入して status を検証する。
#
#   bash scripts/test-rs-doctor-env.sh
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
target="$repo_root/plugins/repo-standards/scripts/rs-doctor-env.sh"

failures=0

# assert <期待 status> <ケース名> <gh auth status の出力>
assert() {
  local want=$1 name=$2 status_out=$3
  local got
  got=$( RS_GH_AUTH_STATUS="$status_out" bash "$target" \
    | jq -r 'select(.id == "env-gh-token-admin") | .status' )

  if [ "$got" = "$want" ]; then
    echo "  [ok]   $name → $got"
  else
    echo "  [FAIL] $name → 期待 $want / 実際 $got"
    failures=$((failures + 1))
  fi
}

echo "env-gh-token-admin:"

# 管理権限あり: classic トークンの repo スコープ (ブランチ保護を変更できる)
assert warn "classic の repo スコープ" \
  "  - Token scopes: 'admin:public_key', 'gist', 'read:org', 'repo', 'workflow'"
assert warn "admin:org スコープ" \
  "  - Token scopes: 'admin:org', 'read:user'"
assert warn "delete_repo スコープ" \
  "  - Token scopes: 'delete_repo'"

# 管理権限なし: 読み取り系のみ
assert ok "読み取り系のみ" \
  "  - Token scopes: 'gist', 'read:org', 'read:user'"

# public_repo は repo と別スコープ。部分一致で誤検出しないこと (境界値)
assert ok "public_repo のみ (repo と誤認しない)" \
  "  - Token scopes: 'public_repo', 'workflow'"

# fine-grained PAT はスコープを表示しない
assert ok "スコープ表示なし (fine-grained)" \
  "github.com
  ✓ Logged in to github.com account someone (keyring)
  - Active account: true"

echo
echo "env-linked-checkout-dirty (出力契約: warn を出すなら level は recommended):"

# HOME を隔離し、dirty な checkout を指す symlink を組み立てて再現する
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
: > "$tmp/empty-gitconfig"
mkdir -p "$tmp/setuprepo/claude" "$tmp/home/.claude"
git -C "$tmp/setuprepo" init -q -b main
echo base > "$tmp/setuprepo/claude/CLAUDE.md"
git -C "$tmp/setuprepo" add -A
git -C "$tmp/setuprepo" -c user.email=t@example.com -c user.name=t commit -qm init
echo dirty >> "$tmp/setuprepo/claude/CLAUDE.md"
ln -s "$tmp/setuprepo/claude/CLAUDE.md" "$tmp/home/.claude/CLAUDE.md"

line=$( HOME="$tmp/home" RS_GH_AUTH_STATUS="(認証情報なし)" bash "$target" \
  | jq -c 'select(.id == "env-linked-checkout-dirty")' )
if [ "$(jq -r .status <<<"$line")" = "warn" ] && [ "$(jq -r .level <<<"$line")" = "recommended" ]; then
  echo "  [ok]   dirty な checkout → recommended/warn で報告"
else
  echo "  [FAIL] dirty な checkout → 期待 recommended/warn / 実際 $(jq -r '"\(.level)/\(.status)"' <<<"$line")"
  failures=$((failures + 1))
fi

echo
echo "env-symlink-* (~/.claude の配布ファイルが正しい symlink か):"

# HOME ごと隔離し、~/.setup に setup リポ (tasks/claude.yml + claude/) を組み立てて
# ~/.claude/<name> の状態だけを差し替えて検証する。この判定は「実効設定と正本が食い違って
# いる」を唯一検知する層なので、各分岐と期待リストの解決経路を固定する (経緯: #84)。
# 組み立て側の git 操作も $GIT_CONFIG_GLOBAL を空にして実マシンの設定に依存させない
gitq() {
  GIT_CONFIG_GLOBAL="$tmp/empty-gitconfig" \
    git -c user.email=t@example.com -c user.name=t "$@"
}

# new_home <期待リストに並べる名前...> → 組み立てた HOME のパスを返す
new_home() {
  local h="$tmp/symhome-$RANDOM$RANDOM" n
  mkdir -p "$h/.claude" "$h/.setup/tasks" "$h/.setup/claude"
  {
    echo "    claude_config_files:"
    for n in "$@"; do echo "      - $n"; done
    echo "    claude_owner: someone"
  } > "$h/.setup/tasks/claude.yml"
  gitq -C "$h/.setup" init -q -b main >/dev/null
  for n in "$@"; do echo x > "$h/.setup/claude/$n"; done
  gitq -C "$h/.setup" add -A >/dev/null
  gitq -C "$h/.setup" commit -qm init >/dev/null
  printf '%s' "$h"
}

# assert_sym <id> <期待 level/status> <ケース名> <HOME>
# 期待を "なし" にすると「その id の行が出ないこと」を検証する
assert_sym() {
  local id=$1 want=$2 name=$3 h=$4 got
  got=$( HOME="$h" GIT_CONFIG_GLOBAL="$tmp/empty-gitconfig" RS_GH_AUTH_STATUS="(認証情報なし)" \
    bash "$target" | jq -r --arg id "$id" 'select(.id == $id) | "\(.level)/\(.status)"' )
  [ -n "$got" ] || got="なし"

  if [ "$got" = "$want" ]; then
    echo "  [ok]   $name → $got"
  else
    echo "  [FAIL] $name → 期待 $want / 実際 $got"
    failures=$((failures + 1))
  fi
}

# 正常: setup リポ (main) の実体を指している
h=$(new_home CLAUDE.md)
ln -s "$h/.setup/claude/CLAUDE.md" "$h/.claude/CLAUDE.md"
assert_sym env-symlink-CLAUDE.md required/ok "setup リポ (main) を指す symlink" "$h"

# 欠落: 期待リストに載っているのに ~/.claude に無い (playbook 未実行の新マシン)
h=$(new_home CLAUDE.md)
assert_sym env-symlink-missing-CLAUDE.md required/ng "配布ファイルが無い" "$h"

# 実ファイル: symlink でなく実体が置かれている (正本と切り離されている)
h=$(new_home CLAUDE.md)
echo local > "$h/.claude/CLAUDE.md"
assert_sym env-not-symlink-CLAUDE.md recommended/warn "実ファイルが置かれている" "$h"

# 切れた symlink: リンク先が消えている (実体が無いので設定は効いていない)
h=$(new_home CLAUDE.md)
ln -s "$h/.setup/claude/gone.md" "$h/.claude/CLAUDE.md"
assert_sym env-symlink-broken-CLAUDE.md required/ng "symlink が切れている" "$h"

# worktree: setup リポの linked worktree を指している (main checkout と食い違う)
h=$(new_home CLAUDE.md)
gitq -C "$h/.setup" worktree add -q -b wt "$h/.setup/.claude/worktrees/wt" >/dev/null 2>&1
ln -s "$h/.setup/.claude/worktrees/wt/claude/CLAUDE.md" "$h/.claude/CLAUDE.md"
assert_sym env-symlink-worktree-CLAUDE.md required/ng "リンク先が setup リポの worktree" "$h"

# detached HEAD: リンク先 checkout が main から外れている
h=$(new_home CLAUDE.md)
gitq -C "$h/.setup" checkout -q --detach
ln -s "$h/.setup/claude/CLAUDE.md" "$h/.claude/CLAUDE.md"
assert_sym env-symlink-detached-CLAUDE.md required/ng "リンク先が detached HEAD" "$h"

# git 管理外: setup リポの外を指している (境界値: 正本を追えないだけなので ng でなく warn)
h=$(new_home CLAUDE.md)
mkdir -p "$h/elsewhere"
echo x > "$h/elsewhere/CLAUDE.md"
ln -s "$h/elsewhere/CLAUDE.md" "$h/.claude/CLAUDE.md"
assert_sym env-symlink-target-CLAUDE.md recommended/warn "リンク先が git 管理外" "$h"

# 期待リストの解決 (1): tasks/claude.yml の claude_config_files を読む経路。
# 1 件目が正常でも 2 件目の欠落を独立に見る
h=$(new_home CLAUDE.md settings.json)
ln -s "$h/.setup/claude/CLAUDE.md" "$h/.claude/CLAUDE.md"
assert_sym env-symlink-CLAUDE.md required/ok "claude.yml の 1 件目 (正常)" "$h"
assert_sym env-symlink-missing-settings.json required/ng "claude.yml の 2 件目 (欠落)" "$h"

# 期待リストの解決 (2): claude.yml が読めないときは現存 symlink へフォールバックする。
# 期待リストが無いので欠落は検出できない (この限界を仕様として固定する)
h=$(new_home CLAUDE.md settings.json)
rm -f "$h/.setup/tasks/claude.yml"
ln -s "$h/.setup/claude/CLAUDE.md" "$h/.claude/CLAUDE.md"
assert_sym env-symlink-CLAUDE.md required/ok "claude.yml が無くても現存 symlink は検査する" "$h"
assert_sym env-symlink-missing-settings.json なし "claude.yml が無ければ欠落は報告しない" "$h"

echo
echo "env-git-fetch-prune / env-git-gone-alias (squash 運用のローカルブランチ掃除):"

# assert_git <id> <期待 status> <ケース名> <グローバル gitconfig の中身>
# $GIT_CONFIG_GLOBAL でグローバル設定を差し替え、実マシンの ~/.gitconfig に依存させない。
# 出力契約 (warn を出すなら level は recommended) もあわせて検証する
assert_git() {
  local id=$1 want=$2 name=$3 conf=$4
  local gc="$tmp/gitconfig-$RANDOM"
  printf '%s\n' "$conf" > "$gc"
  local got
  got=$( GIT_CONFIG_GLOBAL="$gc" RS_GH_AUTH_STATUS="(認証情報なし)" bash "$target" \
    | jq -r --arg id "$id" 'select(.id == $id) | "\(.level)/\(.status)"' )

  if [ "$got" = "recommended/$want" ]; then
    echo "  [ok]   $name → $got"
  else
    echo "  [FAIL] $name → 期待 recommended/$want / 実際 ${got:-出力なし}"
    failures=$((failures + 1))
  fi
}

configured='[fetch]
	prune = true
[alias]
	gone = !git fetch -pq && git for-each-ref
	gone-clean = !git gone | while read -r b; do git branch -D "$b"; done'

assert_git env-git-fetch-prune ok "fetch.prune = true" "$configured"
assert_git env-git-gone-alias  ok "エイリアス両方あり" "$configured"

assert_git env-git-fetch-prune warn "設定が空 (未設定)" ""
assert_git env-git-gone-alias  warn "設定が空 (未設定)" ""

# 明示的な false は「未設定」と別経路だが同じく warn (境界値)
assert_git env-git-fetch-prune warn "fetch.prune = false" '[fetch]
	prune = false'

# 片方だけでは棚卸しが完結しないので warn (境界値)
assert_git env-git-gone-alias warn "gone だけあり gone-clean が無い" '[alias]
	gone = !git for-each-ref'

echo
echo "env-hook-* (settings.json が参照するフックの実在):"

# HOME を隔離し、フックの実体を 3 種類 (正常 / 実行ビットなし / 切れた symlink) 置いた
# ~/.claude を組み立てて、settings.json の内容だけを差し替えて検証する。
# assert_hook <id> <期待 level/status> <ケース名> <settings.json の中身>
# 期待を "なし" にすると「その id の行が出ないこと」を検証する (対象外の判定に使う)
assert_hook() {
  local id=$1 want=$2 name=$3 conf=$4
  local h="$tmp/hookhome-$RANDOM"
  mkdir -p "$h/.claude"
  printf '%s\n' "$conf" > "$h/.claude/settings.json"
  printf '#!/bin/sh\n' > "$h/.claude/good.sh"
  chmod +x "$h/.claude/good.sh"
  printf '#!/bin/sh\n' > "$h/.claude/noexec.sh"
  chmod -x "$h/.claude/noexec.sh"
  ln -s "$h/.claude/nowhere.sh" "$h/.claude/broken.sh"

  local got
  got=$( HOME="$h" GIT_CONFIG_GLOBAL="$tmp/empty-gitconfig" RS_GH_AUTH_STATUS="(認証情報なし)" \
    bash "$target" | jq -r --arg id "$id" 'select(.id == $id) | "\(.level)/\(.status)"' )
  [ -n "$got" ] || got="なし"

  if [ "$got" = "$want" ]; then
    echo "  [ok]   $name → $got"
  else
    echo "  [FAIL] $name → 期待 $want / 実際 $got"
    failures=$((failures + 1))
  fi
}

hook_conf() { printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"%s"}]}]}}' "$1"; }

assert_hook env-hooks-present required/ok "実在し実行できるフックのみ" "$(hook_conf '~/.claude/good.sh')"

# 欠落・切れた symlink・実行ビットなしはいずれも「登録されているのに効かない」= required/ng
assert_hook env-hook-missing-missing.sh required/ng "実体が無い" "$(hook_conf '~/.claude/missing.sh')"
assert_hook env-hook-missing-broken.sh required/ng "symlink が切れている" "$(hook_conf '~/.claude/broken.sh')"
assert_hook env-hook-not-executable-noexec.sh required/ng "実行ビットが無い" "$(hook_conf '~/.claude/noexec.sh')"

# 問題を検出したら「すべて実在」の ok は出さない (集約 ok が欠落を隠さないこと)
assert_hook env-hooks-present なし "欠落があるとき集約 ok を出さない" "$(hook_conf '~/.claude/missing.sh')"

# 引数付き・$HOME 形式でも追跡できる (境界値)
assert_hook env-hook-missing-missing.sh required/ng "引数付きでも追跡する" "$(hook_conf '~/.claude/missing.sh --flag x')"
assert_hook env-hook-missing-missing.sh required/ng '$HOME 形式でも追跡する' "$(hook_conf '$HOME/.claude/missing.sh')"

# ~/.claude 配下を指さないコマンドは対象外 (PATH 上のコマンド・他所の絶対パス)
assert_hook env-hooks-present required/ok "PATH 上のコマンドは対象外" "$(hook_conf 'jq -e .')"
assert_hook env-hooks-present required/ok "他所の絶対パスは対象外" "$(hook_conf '/usr/local/bin/other.sh')"

# hooks を持たない settings.json でも落ちない (境界値)
assert_hook env-hooks-present required/ok "hooks が無い settings.json" '{"model":"opus"}'

# settings.json が壊れていれば走査できないので skip (ng と区別する)
assert_hook env-hooks-present required/skip "settings.json が壊れている" '{"hooks":'

echo
echo "env-automode-* / env-ask-checkpoints (自動モードの守りが効いているか):"

# HOME を隔離し、settings.json の内容だけを差し替えて検証する。
# assert_am <id> <期待 level/status> <ケース名> <settings.json の中身>
assert_am() {
  local id=$1 want=$2 name=$3 conf=$4
  local h="$tmp/amhome-$RANDOM$RANDOM"
  mkdir -p "$h/.claude"
  printf '%s\n' "$conf" > "$h/.claude/settings.json"

  local got
  got=$( HOME="$h" GIT_CONFIG_GLOBAL="$tmp/empty-gitconfig" RS_GH_AUTH_STATUS="(認証情報なし)" \
    bash "$target" | jq -r --arg id "$id" 'select(.id == $id) | "\(.level)/\(.status)"' )
  [ -n "$got" ] || got="なし"

  if [ "$got" = "$want" ]; then
    echo "  [ok]   $name → $got"
  else
    echo "  [FAIL] $name → 期待 $want / 実際 $got"
    failures=$((failures + 1))
  fi
}

# "$defaults" の欠落はこの層で一番効く検査。素で書いた配列はその節の組み込みルール
# (force push・curl | bash・データ持ち出し・auto-mode bypass) を丸ごと捨てる
kept='{"autoMode":{"environment":["$defaults","Source control: github.com/acme"],"hard_deny":["$defaults","Never X"]}}'
dropped='{"autoMode":{"environment":["$defaults"],"soft_deny":["Never Y"]}}'

assert_am env-automode-defaults required/ok "各配列が \$defaults を含む" "$kept"
assert_am env-automode-defaults required/ng "soft_deny が \$defaults を落としている" "$dropped"

# 節ごとに独立して評価される。1 つでも落ちていれば ng (境界値)
assert_am env-automode-defaults required/ng "environment だけ保っていても他が落ちていれば ng" \
  '{"autoMode":{"environment":["$defaults"],"allow":["Anything goes"],"hard_deny":["$defaults"]}}'

# 配列でない値・未知のキーは検査対象外 (境界値)
assert_am env-automode-defaults required/ok "配列でない設定は対象外" \
  '{"autoMode":{"classifyAllShell":true,"environment":["$defaults"]}}'

# autoMode 自体が無ければ $defaults の欠落は起こりえない (ng と skip を区別する)
assert_am env-automode-defaults required/skip "autoMode ブロックが無い" '{"model":"opus"}'
assert_am env-automode-defaults required/skip "settings.json が壊れている" '{"autoMode":'

# environment が既定のままだと、分類器が信頼するのは cwd とそのリポの remote だけ
assert_am env-automode-environment recommended/ok "固有の記述がある" "$kept"
assert_am env-automode-environment recommended/warn "\$defaults だけ (実質未設定)" "$dropped"
assert_am env-automode-environment recommended/warn "autoMode ブロックが無い" '{"model":"opus"}'

assert_am env-automode-configured recommended/ok "defaultMode = auto" \
  '{"permissions":{"defaultMode":"auto"}}'
assert_am env-automode-configured recommended/warn "defaultMode が別のモード" \
  '{"permissions":{"defaultMode":"acceptEdits"}}'
assert_am env-automode-configured recommended/warn "defaultMode 未設定" '{"model":"opus"}'

# ask ルールは分類器より前に評価され、auto モードでも必ずプロンプトになる
assert_am env-ask-checkpoints recommended/ok "削除系のチェックポイントがある" \
  '{"permissions":{"ask":["Bash(gh repo delete:*)"]}}'
assert_am env-ask-checkpoints recommended/warn "ask が空" '{"permissions":{"ask":[]}}'
assert_am env-ask-checkpoints recommended/warn "permissions が無い" '{"model":"opus"}'

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK"
