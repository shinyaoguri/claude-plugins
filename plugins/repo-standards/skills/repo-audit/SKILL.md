---
name: repo-audit
description: "cwd のリポジトリを個人標準 (setup リポの repo-standards.json) と突き合わせて監査する。GitHub 設定・リポ構成ファイル・.claude 設定の 3 層を機械判定 + LLM 判定でレポートし、承認された項目だけ修正を適用する。Use when auditing a repository against personal standards, checking GitHub repo settings, or reviewing repository structure and Claude configuration."
---

cwd が git リポジトリでなければ「git リポジトリ内で実行してください」と伝えて終了する。

## 手順

1. 機械判定を実行する (どちらも JSON Lines を出力し、常に exit 0):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-repo.sh"      # リポ構成 + .claude 設定
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-github.sh"    # GitHub 設定 (gh 不在時は全 skip)
   ```

2. `status: "manual"` の項目は detail の判定観点に従い、対象ファイルを自分で読んで ok / warn を判定する
3. レポートを提示する: `_meta` 行 (kind / repo / visibility) をヘッダに、層ごとの表 (項目 | 判定 | 詳細)。末尾に集計 (必須 NG / 推奨 WARN / skip)。`standards-manifest-missing` が出たら監査を打ち切り、fix の内容 (setup リポのセットアップ) を案内する
4. 修正候補を 3 群に分けて番号付きで提示し、群ごとに適用可否の承認を取る。承認された項目だけ適用する:
   - **A 群 (GitHub 設定)**: `.github/repo-settings.json` があるリポでは**この群を作らず B 群に含める** — 設定は gh コマンドでなく定義ファイルの変更として PR に載せ、マージ後に `apply-repo-settings.sh --apply` で反映する (承認が PR に一元化され、変更の根拠が diff に残る)。定義ファイルが無いリポでのみ、各項目の `fix` の gh コマンドを全文提示し承認後に実行する
   - **B 群 (リポ内ファイルの追加・修正)**: worktree が dirty なら中断して退避を促す。`chore/repo-standards` ブランチを切り、承認項目をまとめて 1 PR にする (標準適合が 1 関心事)
   - **C 群 (削除系・破壊的操作)**: コマンドの提示のみ。実行はユーザーに委ねる
5. 適用後に同じスクリプトを再実行し、before / after を表で提示する

## 詳細の在処

- チェックリストの正本: `~/.claude/repo-standards.json` (実体は shinyaoguri/setup の claude/repo-standards.json。項目の追加・変更はプラグインでなく setup リポへの PR で行う)
- 必須項目と根拠だけ見る: `jq -r '.items[] | select(.level=="required") | [.id, .why] | @tsv' ~/.claude/repo-standards.json`
- 出力スキーマと status の意味: `${CLAUDE_PLUGIN_ROOT}/scripts/rs-lib.sh` 冒頭のコメント
