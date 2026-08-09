---
name: repo-bootstrap
description: "新規リポジトリを個人標準 (setup リポの repo-standards.json) どおりに対話的に雛形生成する。構成ファイルの生成 → 初回コミット → GitHub 作成と設定適用まで。Use when creating a new repository or initializing an existing directory to personal standards."
argument-hint: "[path] [--kind <swift|web|python|generic>]"
allowed-tools: "Bash(jq:*), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-github.sh:*), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-min.sh:*)"
---

新しいリポジトリの雛形を個人標準どおりに作る。既存リポの監査は /repo-audit を使う (このスキルは生成が目的)。

## 手順

1. 正本を読み、リポ種別を決める。`--kind` 指定が無ければ選択肢を提示して 1 問だけ聞く:

   ```bash
   jq -r '.kinds[].id' ~/.claude/repo-standards.json    # 種別の選択肢 (正本から動的に取得)
   ```

   正本が無ければ setup リポのセットアップ (`ansible-playbook --tags claude`) を案内して終了する
2. `level: required` の全項目と、該当種別に適用される `recommended` 項目を列挙し、生成するファイル一覧 (`.gitignore`・README.md・CLAUDE.md・CI・テンプレート等) を提示して確認を取る:

   ```bash
   jq -r --arg k <kind> '.items[] | select(.applies_to | index("all") or index($k))
     | select(.level != "rejected") | [.level, .id, .fix // ""] | @tsv' ~/.claude/repo-standards.json
   ```

3. `git init` (default branch は main) → 各項目の `fix` の方針に沿ってファイルを生成 → 初回コミット。新規リポなのでこの初回コミットだけ main 直コミットでよい
4. ユーザーが望めば `gh repo create` + push し、`bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-github.sh` の NG 項目の fix コマンドを提示 → 承認後に適用する
5. 仕上げに簡易監査で green を確認する (判定ロジックをここに複製しない):

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-min.sh
   ```

   逸脱が残っていれば項目を示し、対処は /repo-audit へ渡す。**生成直後に本監査 (repo-audit) は回さない** — 標準どおりに作った直後で逸脱はほぼ無く、反証まで通す本監査を通すコストに見合わない

## 詳細の在処

- チェックリストの正本と各項目の生成方針 (`fix`): `~/.claude/repo-standards.json` (実体は shinyaoguri/setup の claude/repo-standards.json)
- CLAUDE.md に書くべき内容の判断基準: 正本の `claude-md-quality` 項目の prompt

このスキル自体の不具合・使いにくさに気付いたら、report-issue スキルで shinyaoguri/claude-plugins へ気軽に起票する。
