---
name: repo-audit
description: "cwd のリポジトリを個人標準 (setup リポの repo-standards.json) と突き合わせて監査する。GitHub 設定・リポ構成ファイル・.claude 設定の 3 層を機械判定 + LLM 判定でレポートし、結果を findings に保存して修正シーケンス (repo-audit-fix) へ引き渡す。Use when auditing a repository against personal standards, checking GitHub repo settings, or reviewing repository structure and Claude configuration."
---

cwd が git リポジトリでなければ「git リポジトリ内で実行してください」と伝えて終了する。

## 手順

1. 機械判定を実行し、結果を findings へ保存する (どのスクリプトも常に exit 0):

   ```bash
   P="${CLAUDE_PLUGIN_ROOT}/scripts"
   { bash "$P/rs-audit-repo.sh"; bash "$P/rs-audit-github.sh"; } | bash "$P/rs-findings.sh" save
   ```

   監査結果の JSON Lines がそのまま流れ、末尾に集計と次アクションの `_next` 行が付く。前回の判定・承認は id 単位で引き継がれる (status が変わった項目だけ未決に戻る)。`standards-manifest-missing` が出たら監査を打ち切り、その fix の内容 (setup リポのセットアップ) を案内する

2. `status: "manual"` の項目を判定する。対象は `bash "$P/rs-findings.sh" list --needs-verdict` (未判定のもの、および判定後に HEAD が進んで陳腐化したもの)。detail の判定観点に従って ok / warn / ng を決める。項目が複数あるときは項目ごとに並列でサブエージェントへ委譲し (対象ファイルのパスと判定観点を渡し、判定と根拠だけ返させる)、メインコンテキストには結果のみ集約する。1〜2 件なら自分で読んで判定してよい

   判定は必ず findings へ書き戻す。チャットに書くだけでは次のセッションに残らない:

   ```bash
   bash "$P/rs-findings.sh" set --verdict warn --evidence "<根拠を一文で>" <id>
   ```

3. レポートを提示する: `_meta` 行 (kind / repo / visibility) をヘッダに、層ごとの表 (項目 | 判定 | 詳細)。末尾に `bash "$P/rs-findings.sh" summary` の集計 (必須 NG / 推奨 WARN / 未決 / skip)

4. 未決 (pending) が残っていれば repo-audit-fix スキルへ進み、修正シーケンスに入る。ユーザーが監査だけを求めているときを除き、報告で終わらせない

## 詳細の在処

- チェックリストの正本: `~/.claude/repo-standards.json` (実体は shinyaoguri/setup の claude/repo-standards.json。項目の追加・変更はプラグインでなく setup リポへの PR で行う)
- 必須項目と根拠だけ見る: `jq -r '.items[] | select(.level=="required") | [.id, .why] | @tsv' ~/.claude/repo-standards.json`
- 監査出力のスキーマと status の意味: `${CLAUDE_PLUGIN_ROOT}/scripts/rs-lib.sh` 冒頭のコメント
- findings の保存先・行スキーマ・decision の意味: `${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh` 冒頭のコメント

このスキル自体の不具合・使いにくさに気付いたら、report-issue スキルで shinyaoguri/claude-plugins へ気軽に起票する。
