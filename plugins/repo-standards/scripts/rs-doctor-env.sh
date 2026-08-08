#!/usr/bin/env bash
# グローバル環境 (~/.claude と setup リポ) の健全性診断。layer は "env" 固定。
# チェックはすべてビルトインで、正本 repo-standards.json が無くても動く
# (正本の解決可否そのものも 1 項目として報告する)。
# 出力契約は rs-lib.sh 冒頭を参照。修正の適用はしない (レポートのみ)。
set -uo pipefail
. "$(dirname "$0")/rs-lib.sh"

claude_dir="$HOME/.claude"
setup_main="$HOME/.setup"

# symlink が指す先の checkout (worktree ドリフト検出用)。CLAUDE.md のリンク先から導出
link_root=""
if [ -L "$claude_dir/CLAUDE.md" ]; then
  target=$(readlink "$claude_dir/CLAUDE.md")
  link_root=$(cd "$(dirname "$target")" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || link_root=""
fi

jq -cn --arg cd "$claude_dir" --arg lr "$link_root" --arg sm "$setup_main" \
  '{id:"_meta",layer:"env",claude_dir:$cd,link_root:$lr,setup_main:$sm}'

# ---- 1. ~/.claude の配布ファイルが正しい symlink か ----
# 期待リストは setup リポの tasks/claude.yml (claude_config_files) が正本。
# setup が見つからないときは現存の symlink だけを検査する (欠落は検出できない)
expected=""
if [ -f "$setup_main/tasks/claude.yml" ]; then
  expected=$(awk '/claude_config_files:/{f=1;next} f&&/^ *- /{sub(/^ *- */,"");print;next} f{exit}' \
    "$setup_main/tasks/claude.yml")
else
  expected=$(find "$claude_dir" -maxdepth 1 -type l 2>/dev/null | while IFS= read -r p; do basename "$p"; done)
fi

for name in $expected; do
  path="$claude_dir/$name"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    emit "env-symlink-missing-$name" env required ng \
      "~/.claude/$name が無い (setup が配布するはずのファイル)" \
      "ansible-playbook playbook_sillicon_mac.yml --tags claude を setup リポで実行する"
    continue
  fi
  if [ ! -L "$path" ]; then
    emit "env-not-symlink-$name" env recommended warn \
      "~/.claude/$name が実ファイル (setup 管理の symlink であるべき)" \
      "playbook 再実行で .bak 退避のうえ symlink 化される"
    continue
  fi
  if [ ! -e "$path" ]; then
    emit "env-symlink-broken-$name" env required ng \
      "~/.claude/$name の symlink が切れている ($(readlink "$path"))" \
      "setup リポの状態を確認して playbook を再実行する"
    continue
  fi
  troot=$(cd "$(dirname "$(readlink "$path")")" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || troot=""
  tbranch=$(git -C "$troot" rev-parse --abbrev-ref HEAD 2>/dev/null) || tbranch=""
  case "$troot" in
    */.claude/worktrees/*)
      emit "env-symlink-worktree-$name" env required ng \
        "~/.claude/$name が setup リポの worktree ($troot, branch: ${tbranch:-?}) を指している。main checkout と食い違う" \
        "worktree 側の未コミット差分を確認・整理してから playbook を再実行する"
      ;;
    "")
      emit "env-symlink-target-$name" env recommended warn \
        "~/.claude/$name のリンク先が git 管理外 ($(readlink "$path"))"
      ;;
    *)
      if [ "$tbranch" = "HEAD" ]; then
        emit "env-symlink-detached-$name" env required ng \
          "~/.claude/$name のリンク先 checkout ($troot) が detached HEAD" \
          "setup リポを main に戻してから playbook を再実行する"
      else
        emit "env-symlink-$name" env required ok "→ $troot ($tbranch)"
      fi
      ;;
  esac
done

# ---- 2. リンク先 checkout の未コミット差分 ----
# 作業途中の正当な差分もあり得て人間の判断が要るため recommended/warn とする
# (required にすると契約上 ng になり「違反確定」の扱いになってしまう)
if [ -n "$link_root" ]; then
  dirty=$(git -C "$link_root" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$dirty" -gt 0 ]; then
    emit env-linked-checkout-dirty env recommended warn \
      "symlink が指す checkout ($link_root) に未コミット差分が $dirty 件。実効設定と正本 (main) が食い違っている可能性" \
      "git -C $link_root diff で差分を確認し、コミット/PR するか破棄するかを判断する"
  else
    emit env-linked-checkout-dirty env recommended ok "リンク先 checkout はクリーン"
  fi
fi

# ---- 3. setup リポ main checkout の鮮度 ----
if [ -d "$setup_main/.git" ]; then
  branch=$(git -C "$setup_main" rev-parse --abbrev-ref HEAD 2>/dev/null)
  dirty=$(git -C "$setup_main" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  behind=$(git -C "$setup_main" rev-list --count HEAD..origin/main 2>/dev/null || echo "?")
  detail="branch: $branch / 未コミット: $dirty 件 / origin/main より behind: $behind (fetch していない場合は古い値)"
  if [ "$branch" != "main" ] || [ "$dirty" -gt 0 ] || { [ "$behind" != "?" ] && [ "$behind" -gt 0 ]; }; then
    emit env-setup-checkout env recommended warn "$detail" \
      "git -C ~/.setup で main を最新化してから必要なら playbook を再実行する"
  else
    emit env-setup-checkout env recommended ok "$detail"
  fi
else
  emit env-setup-checkout env required ng "~/.setup が無い" \
    "github.com/shinyaoguri/setup を ~/.setup へ clone してセットアップする"
fi

# ---- 4. ~/.claude/skills の残骸 (スキル二重供給・旧 symlink 供給の名残) ----
# 規約: スキルは marketplace プラグインか各リポの .claude/skills で供給し、~/.claude/skills
# には置かない (正本: setup リポ claude/CLAUDE.md のスキル節)。かつて setup が汎用スキルを
# ここへ symlink していた (2026-08 に廃止) ため、その残骸 symlink も検出する
plugin_skills=$(find "$claude_dir/plugins" -maxdepth 8 -type d -path '*/skills/*' 2>/dev/null \
  | awk -F/ '$(NF-1) == "skills" {print $NF}' | sort -u)
found_any=0
if [ -d "$claude_dir/skills" ]; then
  for d in "$claude_dir/skills"/*; do
    { [ -e "$d" ] || [ -L "$d" ]; } || continue
    name=$(basename "$d")
    found_any=1
    if [ -L "$d" ] && [[ "$(readlink "$d")" == "$HOME/.setup/claude/skills/"* ]]; then
      emit "env-skill-legacy-$name" env required ng \
        "~/.claude/skills/$name が setup の旧 skills symlink 供給の残骸" \
        "rm ~/.claude/skills/$name (削除系: 実行はユーザー判断)。スキル本体は marketplace プラグインで供給される"
    elif printf '%s\n' "$plugin_skills" | grep -qx "$name"; then
      emit "env-skill-duplicate-$name" env required ng \
        "~/.claude/skills/$name が実体コピーで、プラグイン供給と二重になっている" \
        "rm -rf ~/.claude/skills/$name (削除系: 実行はユーザー判断)"
    else
      emit "env-skill-untracked-$name" env recommended warn \
        "~/.claude/skills/$name が管理外に置かれている" \
        "汎用スキルなら claude-plugins の marketplace プラグインへ、リポ固有なら該当リポの .claude/skills/ へ移す"
    fi
  done
fi
[ "$found_any" -eq 0 ] && emit env-skills-clean env required ok "~/.claude/skills に残骸なし"

# ---- 5. settings.json が壊れていないか ----
if jq empty "$claude_dir/settings.json" 2>/dev/null; then
  emit env-settings-valid env required ok "settings.json は正しい JSON"
else
  emit env-settings-valid env required ng "~/.claude/settings.json が JSON として壊れている (設定全体が無視される)" \
    "jq empty ~/.claude/settings.json でエラー箇所を特定して修正する"
fi

# ---- 6. gh トークンが管理権限を持っていないか ----
# Claude と同じトークンに管理権限があると、監査対象の GitHub 設定そのものを
# 書き換えられてしまう (repo-standards は防御機構ではない。ADR 0007 / setup#42)。
# 判定は gh auth status のスコープ表示から行う。$RS_GH_AUTH_STATUS はテスト用の注入口
gh_status="${RS_GH_AUTH_STATUS-}"
if [ -z "$gh_status" ] && command -v gh >/dev/null 2>&1; then
  gh_status=$(gh auth status 2>&1) || gh_status=""
fi
if [ -z "$gh_status" ]; then
  emit env-gh-token-admin env recommended skip "gh が無いか未認証のためトークン権限を判定できない"
else
  # 例: "  - Token scopes: 'gist', 'read:org', 'repo'"
  scopes=$(printf '%s\n' "$gh_status" | sed -n "s/.*Token scopes: *//p")
  admin=""
  for s in repo admin:org delete_repo site_admin; do
    case "$scopes" in *"'$s'"*) admin="$admin $s" ;; esac
  done
  if [ -n "$admin" ]; then
    emit env-gh-token-admin env recommended warn \
      "gh のトークンが管理権限スコープを持つ ($admin) — ブランチ保護など監査対象の設定を書き換えられる" \
      "権限の剥奪は採らない (実効性が崩れやすくコストが継続するため: shinyaoguri/setup#42)。bypass_actors を空にした ruleset を張り、設定変更を検知する仕組みで担保する"
  elif [ -z "$scopes" ]; then
    # fine-grained PAT はスコープを表示しない。個別権限は gh からは判定できない
    emit env-gh-token-admin env recommended ok \
      "スコープ表示なし (fine-grained PAT の可能性。個別権限は gh からは判定できないため要目視)"
  else
    emit env-gh-token-admin env recommended ok "管理権限スコープなし ($scopes)"
  fi
fi

# ---- 7. squash 運用で残るローカルブランチを掃除できる git 設定か ----
# 個人標準は squash merge を required にしているが、squash は feature ブランチの
# コミット群を main 上の別コミットへ畳むため、git branch -d / --merged では役目終了を
# 判定できない (元コミットが main の祖先にならない)。確実に効くシグナルは
# upstream:track == [gone] だけで、これは remote-tracking の prune が前提になる。
# どちらもリポでなくマシン共通の git 設定なので env 層で見る
# (正本: setup リポの tasks/git.yml。経緯: claude-plugins#67)
git_fix="setup リポで ansible-playbook playbook_sillicon_mac.yml --tags git を実行する"
prune=$(git config --global --get fetch.prune 2>/dev/null) || prune=""
if [ "$prune" = "true" ]; then
  emit env-git-fetch-prune env recommended ok "fetch.prune = true (fetch のたび remote-tracking を prune する)"
else
  emit env-git-fetch-prune env recommended warn \
    "git config --global fetch.prune が ${prune:-未設定} — 消えたリモートブランチの remote-tracking が残り、ローカルブランチの gone 判定が効かない" \
    "$git_fix"
fi

missing=""
for a in gone gone-clean; do
  git config --global --get "alias.$a" >/dev/null 2>&1 || missing="$missing $a"
done
if [ -z "$missing" ]; then
  emit env-git-gone-alias env recommended ok "alias.gone / alias.gone-clean が設定済み (役目を終えたローカルブランチの一覧と削除)"
else
  emit env-git-gone-alias env recommended warn \
    "git のエイリアスが未設定 ($missing) — squash merge 後に残るローカルブランチを棚卸しする手立てが無い" \
    "$git_fix"
fi

# ---- 8. チェックリスト正本の解決 ----
if manifest=$(resolve_standards); then
  emit env-standards-manifest env recommended ok "正本: $manifest"
else
  emit_manifest_missing
fi

exit 0
