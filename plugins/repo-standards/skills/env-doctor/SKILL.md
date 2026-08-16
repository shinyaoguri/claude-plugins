---
name: env-doctor
description: "マシン側の Claude グローバル環境を診断する (~/.claude の symlink ドリフト・setup リポの鮮度・スキル二重供給・settings.json の破損・登録済みフックの実体欠落・自動モード (auto mode) の守りが効いているか・役目を終えたローカルブランチを掃除する git 設定 (gone / stale の両系統))。Use when diagnosing the global Claude environment, when ~/.claude symlinks or settings look wrong, when a PreToolUse hook seems not to fire, when auto mode blocks or over-permits actions, when merged local branches pile up, or after setting up a new machine."
allowed-tools: "Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-doctor-env.sh:*), Bash(git gone)"
---

マシン全体の診断なので cwd は問わない。修正の適用は必ず下の順序で行う (順序を飛ばすと直したそばから ansible に上書きされる)。

## 手順

1. 診断を実行する (JSON Lines、常に exit 0。正本 repo-standards.json が無くても動く)。**コマンドは下記のとおり `${CLAUDE_PLUGIN_ROOT}/scripts/...` をそのまま書く** (変数に束ねると frontmatter の allowed-tools と一致せず許可を聞かれる):

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-doctor-env.sh
   ```

2. 各項目を `[ok]` / `[warn]` / `[ng]` の一覧で提示し、問題には fix を添える
3. 修正はこの順序で提案する。**手作業での symlink 張り直しは案内しない** (正規経路は常に ansible):
   1. **setup リポの状態整理** — リンク先 checkout に未コミット差分 (`env-linked-checkout-dirty`) があれば `git diff` を提示し、コミット / PR するか破棄するかをユーザーに確認する。判断せず先へ進まない
   2. **playbook 再実行** — setup リポで `ansible-playbook playbook_sillicon_mac.yml --tags claude`。これが symlink を正本 (main checkout) へ張り直す唯一の正規手段。git 設定の項目 (`env-git-fetch-prune` / `env-git-gone-alias`) は同じ playbook の `--tags git` で入る
   - **自動モードの守り** (`env-automode-*` / `env-ask-checkpoints`) はフックの欠落と同列で最優先。承認プロンプトを消すほど、危険な操作を止める役目は分類器へ寄る。とくに `env-automode-defaults` の ng は **`"$defaults"` を書き忘れた配列が組み込みルール (force push・`curl | bash`・データ持ち出し・auto-mode bypass) を丸ごと捨てている**状態で、緩めた自覚が残らない。修正先は必ず setup リポの claude/settings.json (`~/.claude/settings.json` は symlink)。適用後に `claude auto-mode config` で展開後の実効ルールを確認し、自作ルールを足したなら `claude auto-mode critique` にレビューさせる。**プロジェクトの .claude/settings.json やプラグインからは供給できない** (リポが自分でルールを緩められないための公式仕様) ので、「対象リポに置けばよいのでは」と提案しない
   - **フックの欠落** (`env-hook-missing-*` / `env-hook-not-executable-*`) は最優先で扱う。settings.json に登録されているのに実体が無いフックは**無音で効かない**ため、ガードがある前提の作業が無防備なまま進む。playbook を再実行しても直らないときは setup リポの tasks/claude.yml (`claude_config_files`) に対象が入っているかを確認する (`chmod +x` や手作業の `ln -s` で塞がない — 次の playbook 実行で元に戻る)
   3. **実体コピーの削除** (`env-skill-duplicate-*` など) — rm コマンドは提示のみ。実行はユーザーに委ねる
   4. **ローカルブランチの掃除** — SessionStart hook (`stale-branch-sweep.sh`) が、**消しても情報が失われないと機械的に証明できるものだけ**を自動削除している (ADR 0018): ①既定ブランチの祖先 (`git stale` と同じ判定。push されなかった `worktree-agent-*` 等) と、②`[gone]` かつマージ済み PR の head と tip が一致するもの (squash マージ済み)。**残る `[gone]` は「証明できなかったもの」** — close された PR のブランチ、未 push のコミットが載っているもの、gh が引けなかったもの。これらは `git gone` で一覧を提示してから `git gone-clean` を案内し、**削除コマンドの実行はユーザーに委ねる** (消えるのはローカル参照だけだが、内容が残っている保証が無いので提示に留める)
   5. **gh トークンの権限** (`env-gh-token-admin`) — **権限の剥奪 (fine-grained PAT への切り替え) は提案しない**。実効性が「マシン上に admin トークンを残さない」に依存して崩れやすく、コストだけが残るため不採用 (setup#42)。warn は事実の可視化として扱い、bypass_actors を空にした ruleset と設定変更の検知で担保する方針であることを伝える
4. 修正後に同じスクリプトを再実行し、before / after を提示する

## 詳細の在処

- symlink の正しい張り方・配布対象の正本: setup リポの tasks/claude.yml (`claude_config_files`)
- スキル置き場のルール (汎用 / リポ固有 / 第三者配布の切り分け): setup リポの claude/CLAUDE.md (グローバル CLAUDE.md) のスキル節
- git のグローバル設定 (fetch.prune・gone / gone-clean / stale / stale-clean エイリアスの実体): setup リポの tasks/git.yml
- 自動モードの設定 (`permissions.defaultMode` / `permissions.ask` / `autoMode.{environment,allow,soft_deny,hard_deny}`) の正本: setup リポの claude/settings.json。組み込みルールの実物は `claude auto-mode defaults`
- 役目を終えたローカルブランチの自動掃除: `${CLAUDE_PLUGIN_ROOT}/hooks/scripts/stale-branch-sweep.sh` (SessionStart)。止めたいときは `RS_BRANCH_SWEEP=0`、`[gone]` 側 (gh への照会) だけ止めるなら `RS_BRANCH_SWEEP_GONE=0`、1 セッションの照会本数は `RS_BRANCH_SWEEP_GONE_MAX` (既定 10)
- 残骸 worktree の畳み込みと通知: `${CLAUDE_PLUGIN_ROOT}/hooks/scripts/worktree-sweep.sh` (SessionStart)。`git worktree prune` (実ディレクトリが消えた登録だけ) と、**既定ブランチを掴んだ linked worktree の通知**を行う。掴まれていると別の場所での `gh pr merge --delete-branch` がマージ後のローカル後処理で落ちる (#114)。worktree の削除はしない (ADR 0018 と同じ立場)。止めたいときは `RS_WORKTREE_SWEEP=0`
- 合意の無いまま実装が広がるのを止めるプランゲート: `${CLAUDE_PLUGIN_ROOT}/hooks/scripts/plan-gate.sh` (PreToolUse)。閾値は `RS_PLAN_GATE_THRESHOLD`、止めたいときは `RS_PLAN_GATE=0`
- 検査項目の実装: `${CLAUDE_PLUGIN_ROOT}/scripts/rs-doctor-env.sh` (すべてビルトイン。正本 JSON に依存しない)
- 削除系 (`git gone-clean`・実体コピーの `rm`) を allowed-tools に載せていないのは意図的。**証明できない削除**は提示のみに留める方針を許可の側でも担保する (証明できるものは hook 側で既に消えている)

このスキル自体の不具合・使いにくさに気付いたら、report-issue スキルで shinyaoguri/claude-plugins へ気軽に起票する。
