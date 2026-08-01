---
name: extend-cli
description: shinyaoguri/metaphor-cli に新しいコマンド・新しい MCP ツール・新しいプロジェクトテンプレートを追加するとき、direnv でローカル開発版と brew 版を切り替えるときに読む。手順の索引。Use when adding a new command, MCP tool, or project template to metaphor-cli, or when switching between the local dev build and the brew-installed binary.
---

# metaphor-cli の拡張手順 (索引)

対象リポジトリ判定: cwd の `Package.swift` が `name: "metaphor-cli"` のときだけ適用する。

手順の本文はすべて cwd の **`DEVELOPMENT.md`** にある。該当セクションを読んでから着手する:

| やること | DEVELOPMENT.md のセクション |
|---|---|
| 新コマンド追加 (4 ステップ: Command struct → ルータ switch → helpText → テスト) | Adding a New Command |
| 新 MCP ツール追加 (4 ステップ: MCPToolDefinition → call 分岐 → 契約確認 → テスト) | Adding a New MCP Tool |
| テンプレート追加 (templates.json + `.template` ファイル + プレースホルダ) | Templates |
| ローカル開発版 ⇄ brew 版の切替 | Switching the metaphor used by `metaphor new` (direnv 推奨) |

## 索引に載らない注意 2 点

1. **MCP 経路の stdout 保護**: `MCPCommand.swift` は起動時に `dup2(2, 1)` で fd1 を stderr へ退避し、JSON-RPC 出力だけを本来の stdout に書く。MCP 経路に `print` を足すときは JSON-RPC を汚さないか必ず確認する
2. **新しい IPC は契約になる**: 子スケッチとの間に Probe ファイルや stdin JSON Lines を増やす変更は metaphor 本体との**クロスリポ契約**になる。cross-repo-contract スキルの 4 原則 (両リポ同時更新・同名ブランチ・check-contract green・対向 Issue) に従う
