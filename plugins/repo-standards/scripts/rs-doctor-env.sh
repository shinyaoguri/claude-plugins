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
settings_valid=0
if jq empty "$claude_dir/settings.json" 2>/dev/null; then
  settings_valid=1
  emit env-settings-valid env required ok "settings.json は正しい JSON"
else
  emit env-settings-valid env required ng "~/.claude/settings.json が JSON として壊れている (設定全体が無視される)" \
    "jq empty ~/.claude/settings.json でエラー箇所を特定して修正する"
fi

# ---- 6. settings.json が参照するフックスクリプトが実在し実行できるか ----
# 登録されているのに実体が無い状態は無音で通る (Claude Code は黙って先へ進む) ため、
# 「ガードがある前提で作業しているのにガードが無い」という一番まずい形になる。
# フックは今後も増えるので個別項目でなく走査で持つ (経緯: claude-plugins#82)。
# 対象は ~/.claude 配下を指すコマンドのみ。setup が配布する実体を参照するものだけが
# symlink 供給の欠落で無音化しうる (PATH 上のコマンドは対象外)
hook_fix="setup リポの tasks/claude.yml (claude_config_files) に対象が入っているか確認し、ansible-playbook playbook_sillicon_mac.yml --tags claude を実行する"
if [ "$settings_valid" -eq 1 ]; then
  hook_cmds=$(jq -r '(.hooks // {}) | to_entries[] | .value[]? | (.hooks // [])[]?
    | select(.type == "command") | .command // empty' "$claude_dir/settings.json" 2>/dev/null)
  hook_total=0
  hook_bad=0
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    # 引数付きでも判定できるよう先頭トークンだけ見る
    bin=${cmd%% *}
    case "$bin" in
      '~/.claude/'*) path="$claude_dir/${bin#\~/.claude/}" ;;
      '$HOME/.claude/'*) path="$claude_dir/${bin#\$HOME/.claude/}" ;;
      "$claude_dir/"*) path="$bin" ;;
      *) continue ;;
    esac
    hook_total=$((hook_total + 1))
    name=$(basename "$path")
    if [ ! -e "$path" ]; then
      hook_bad=$((hook_bad + 1))
      if [ -L "$path" ]; then
        emit "env-hook-missing-$name" env required ng \
          "settings.json が参照するフック $name の symlink が切れている ($(readlink "$path")) — このフックは無音で効かない" \
          "$hook_fix"
      else
        emit "env-hook-missing-$name" env required ng \
          "settings.json が参照するフック ~/.claude/$name が存在しない — このフックは無音で効かない" \
          "$hook_fix"
      fi
    elif [ ! -x "$path" ]; then
      hook_bad=$((hook_bad + 1))
      emit "env-hook-not-executable-$name" env required ng \
        "settings.json が参照するフック ~/.claude/$name に実行ビットが無い — このフックは無音で効かない" \
        "$hook_fix"
    fi
  done <<EOF
$hook_cmds
EOF
  if [ "$hook_bad" -eq 0 ]; then
    emit env-hooks-present env required ok \
      "settings.json が参照する ~/.claude 配下のフック $hook_total 件はすべて実在し実行できる"
  fi
else
  emit env-hooks-present env required skip "settings.json が壊れているためフックの参照を走査できない"
fi

# ---- 7. 自動モード (auto mode) の守りが効いているか ----
# 承認プロンプトを消す本体は auto mode で、危険な操作を止めるのは分類器の役目になる。
# 分類器が読む設定は ~/.claude/settings.json の autoMode ブロックだけで、プロジェクト
# 設定とプラグインからは供給できない (リポが自分でルールを緩められないための公式仕様)。
# つまりこの層の健全性はマシン側でしか見られない。
#
# 一番効くのは "$defaults" の欠落検査。配列を素で書くと**その節の組み込みルールを
# 丸ごと捨てる** (force push・curl | bash・本番デプロイ・データ持ち出し・auto-mode
# bypass)。緩めた自覚が残らないまま守りが消えるので required で落とす。
automode_fix="~/.claude/settings.json (正本は setup リポの claude/settings.json) の autoMode の各配列に \"\$defaults\" を含める。claude auto-mode defaults で組み込みルールを確認し、claude auto-mode config で展開後の実効ルールを確かめる"
if [ "$settings_valid" -eq 1 ]; then
  settings="$claude_dir/settings.json"

  if jq -e '.autoMode | type == "object"' "$settings" >/dev/null 2>&1; then
    bare=$(jq -r '.autoMode | to_entries[]
      | select(.key == "allow" or .key == "soft_deny" or .key == "hard_deny" or .key == "environment")
      | select((.value | type) == "array")
      | select((.value | index("$defaults")) == null) | .key' "$settings" 2>/dev/null | tr '\n' ' ')
    bare=${bare% }
    if [ -n "$bare" ]; then
      emit env-automode-defaults env required ng \
        "autoMode の $bare が \"\$defaults\" を含まない — この節の組み込みルール (force push・curl | bash・データ持ち出し・auto-mode bypass 等) を丸ごと捨てている" \
        "$automode_fix"
    else
      emit env-automode-defaults env required ok "autoMode の各配列は \"\$defaults\" を含む (組み込みルールを保ったまま拡張している)"
    fi

    extras=$(jq -r '[(.autoMode.environment // [])[] | select(. != "$defaults")] | length' "$settings" 2>/dev/null)
    if [ "${extras:-0}" -gt 0 ]; then
      emit env-automode-environment env recommended ok "autoMode.environment に固有の記述が ${extras} 件 (分類器が信頼する範囲を宣言済み)"
    else
      emit env-automode-environment env recommended warn \
        "autoMode.environment が既定のまま — 分類器が信頼するのは cwd とそのリポの remote だけで、自分の org や内部サービスへの操作は黙ってブロックされる" \
        "settings.json の autoMode.environment に \"\$defaults\" と併せて Organization / Source control / Key internal services を書き、claude auto-mode config で反映を確認する"
    fi
  else
    emit env-automode-defaults env required skip "autoMode ブロックが無いため \$defaults の欠落は起こりえない"
    emit env-automode-environment env recommended warn \
      "autoMode ブロックが無い — 分類器が信頼するのは cwd とそのリポの remote だけ" \
      "settings.json に autoMode.environment を足して信頼するインフラを宣言する"
  fi

  mode=$(jq -r '.permissions.defaultMode // ""' "$settings" 2>/dev/null)
  if [ "$mode" = "auto" ]; then
    emit env-automode-configured env recommended ok "permissions.defaultMode = auto (承認プロンプトを分類器へ寄せている)"
  else
    emit env-automode-configured env recommended warn \
      "permissions.defaultMode が auto でない (${mode:-未設定}) — 承認が実行のたびに出る一方、分類器による意味判定も効かない" \
      "settings.json の permissions.defaultMode を \"auto\" にする (ユーザー設定でのみ有効。プロジェクト設定からは指定できない)"
  fi

  asks=$(jq -r '(.permissions.ask // []) | length' "$settings" 2>/dev/null)
  if [ "${asks:-0}" -gt 0 ]; then
    emit env-ask-checkpoints env recommended ok "permissions.ask のチェックポイントが ${asks} 件 (auto モードでも必ず人間に返る境界)"
  else
    emit env-ask-checkpoints env recommended warn \
      "permissions.ask が空 — 取り返しのつかない操作 (リポ・リリースの削除など) でも人間に返らない" \
      "settings.json の permissions.ask に削除系のチェックポイントを置く。ask ルールは分類器より前に評価され、auto モードでも必ずプロンプトになる"
  fi
else
  emit env-automode-defaults env required skip "settings.json が壊れているため autoMode を読めない"
fi

# ---- 8. gh トークンが管理権限を持っていないか ----
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

# ---- 9. squash 運用で残るローカルブランチを掃除できる git 設定か ----
# 個人標準は squash merge を required にしているが、squash は feature ブランチの
# コミット群を main 上の別コミットへ畳むため、git branch -d / --merged では役目終了を
# 判定できない (元コミットが main の祖先にならない)。確実に効くシグナルは
# upstream:track == [gone] だけで、これは remote-tracking の prune が前提になる。
# どちらもリポでなくマシン共通の git 設定なので env 層で見る
# (正本: setup リポの tasks/git.yml。経緯: claude-plugins#67)
#
# [gone] のうちマージ済み PR の head と tip が一致するものは SessionStart hook
# (stale-branch-sweep.sh) が自動で消す。fetch.prune が効いていないとその判定材料が
# 揃わず、残りの棚卸しにはエイリアスが要る — どちらも「自動で消える範囲」を
# 説明できないと緑が誤読される (経緯: claude-plugins#99)
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
  emit env-git-gone-alias env recommended ok \
    "alias.gone / alias.gone-clean が設定済み (SessionStart hook が自動で消すのは「マージ済み PR の head と tip が一致する [gone]」だけ。close された PR や未 push のコミットが載っているものは残るので、棚卸しはこのエイリアスで手動)"
else
  emit env-git-gone-alias env recommended warn \
    "git のエイリアスが未設定 ($missing) — squash merge 後に残るローカルブランチのうち、SessionStart hook が自動で消せない分 (close された PR・未 push のコミットが載っているもの) を棚卸しする手立てが無い" \
    "$git_fix"
fi

# [gone] 判定は upstream を持つブランチしか拾えない。一度も push していない
# ローカル専用ブランチ (Claude Code の worktree 分離が作る worktree-agent-* 等) は
# 別のシグナル =「既定ブランチの祖先である」で拾う。SessionStart hook の
# stale-branch-sweep.sh が同じ判定で自動削除する (経緯: claude-plugins#95)
missing=""
for a in stale stale-clean; do
  git config --global --get "alias.$a" >/dev/null 2>&1 || missing="$missing $a"
done
if [ -z "$missing" ]; then
  emit env-git-stale-alias env recommended ok "alias.stale / alias.stale-clean が設定済み (既定ブランチに取り込み済みのローカルブランチの一覧と削除)"
else
  emit env-git-stale-alias env recommended warn \
    "git のエイリアスが未設定 ($missing) — push されなかったローカルブランチ (worktree-agent-* 等) を棚卸しする手立てが無い" \
    "$git_fix"
fi

# ---- 10. チェックリスト正本の解決 ----
if manifest=$(resolve_standards); then
  emit env-standards-manifest env recommended ok "正本: $manifest"
else
  emit_manifest_missing
fi

exit 0
