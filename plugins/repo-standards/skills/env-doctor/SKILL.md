---
name: env-doctor
description: "マシン側の Claude グローバル環境を診断する (~/.claude の symlink ドリフト・setup リポの鮮度・スキル二重供給・settings.json の破損)。Use when diagnosing the global Claude environment, when ~/.claude symlinks or settings look wrong, or after setting up a new machine."
---

マシン全体の診断なので cwd は問わない。修正の適用は必ず下の順序で行う (順序を飛ばすと直したそばから ansible に上書きされる)。

## 手順

1. 診断を実行する (JSON Lines、常に exit 0。正本 repo-standards.json が無くても動く):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/rs-doctor-env.sh"
   ```

2. 各項目を `[ok]` / `[warn]` / `[ng]` の一覧で提示し、問題には fix を添える
3. 修正はこの順序で提案する。**手作業での symlink 張り直しは案内しない** (正規経路は常に ansible):
   1. **setup リポの状態整理** — リンク先 checkout に未コミット差分 (`env-linked-checkout-dirty`) があれば `git diff` を提示し、コミット / PR するか破棄するかをユーザーに確認する。判断せず先へ進まない
   2. **playbook 再実行** — setup リポで `ansible-playbook playbook_sillicon_mac.yml --tags claude`。これが symlink を正本 (main checkout) へ張り直す唯一の正規手段
   3. **実体コピーの削除** (`env-skill-duplicate-*` など) — rm コマンドは提示のみ。実行はユーザーに委ねる
   4. **gh トークンの権限** (`env-gh-token-admin`) — 手順の提示のみ。PAT の発行は web UI での作業なので実行しない。このトークンは Claude 自身が使うものなので、切り替えると以後の gh 操作に影響する旨も伝える
4. 修正後に同じスクリプトを再実行し、before / after を提示する

## 詳細の在処

- symlink の正しい張り方・配布対象の正本: setup リポの tasks/claude.yml (`claude_config_files`)
- スキル置き場のルール (汎用 / リポ固有 / 第三者配布の切り分け): setup リポの claude/skills/README.md
- 検査項目の実装: `${CLAUDE_PLUGIN_ROOT}/scripts/rs-doctor-env.sh` (すべてビルトイン。正本 JSON に依存しない)
