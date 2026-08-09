---
name: env-doctor
description: "マシン側の Claude グローバル環境を診断する (~/.claude の symlink ドリフト・setup リポの鮮度・スキル二重供給・settings.json の破損・役目を終えたローカルブランチを掃除する git 設定)。Use when diagnosing the global Claude environment, when ~/.claude symlinks or settings look wrong, when merged local branches pile up, or after setting up a new machine."
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
   3. **実体コピーの削除** (`env-skill-duplicate-*` など) — rm コマンドは提示のみ。実行はユーザーに委ねる
   4. **ローカルブランチの掃除** — git 設定を入れたうえで、実際の削除は `git gone` で一覧を提示してから `git gone-clean` を案内する。**削除コマンドの実行はユーザーに委ねる** (消えるのはローカル参照だけで内容は main と `refs/pull/<N>/head` に残るが、削除系は提示に留める)
   5. **gh トークンの権限** (`env-gh-token-admin`) — **権限の剥奪 (fine-grained PAT への切り替え) は提案しない**。実効性が「マシン上に admin トークンを残さない」に依存して崩れやすく、コストだけが残るため不採用 (setup#42)。warn は事実の可視化として扱い、bypass_actors を空にした ruleset と設定変更の検知で担保する方針であることを伝える
4. 修正後に同じスクリプトを再実行し、before / after を提示する

## 詳細の在処

- symlink の正しい張り方・配布対象の正本: setup リポの tasks/claude.yml (`claude_config_files`)
- スキル置き場のルール (汎用 / リポ固有 / 第三者配布の切り分け): setup リポの claude/CLAUDE.md (グローバル CLAUDE.md) のスキル節
- git のグローバル設定 (fetch.prune・gone / gone-clean エイリアスの実体): setup リポの tasks/git.yml
- 検査項目の実装: `${CLAUDE_PLUGIN_ROOT}/scripts/rs-doctor-env.sh` (すべてビルトイン。正本 JSON に依存しない)
- 削除系 (`git gone-clean`・実体コピーの `rm`) を allowed-tools に載せていないのは意図的。提示のみに留める方針を許可の側でも担保する

このスキル自体の不具合・使いにくさに気付いたら、report-issue スキルで shinyaoguri/claude-plugins へ気軽に起票する。
