---
description: metaphor ⇄ metaphor-cli のクロスリポ契約チェックを実行し、結果と次アクションを提示
---

metaphor ⇄ metaphor-cli のクロスリポ契約を検証する。

## 手順

1. **リポジトリ判定**: cwd の `Package.swift` に `name: "metaphor"` または `name: "metaphor-cli"` があるか確認。どちらでもなければ「metaphor / metaphor-cli のリポジトリで実行してください」と伝えて終了。
2. **ローカルチェック 3 本**を順に実行し、それぞれの結果を報告する:
   ```bash
   ./scripts/check-contract.sh          # 契約トークンの存在チェック
   ./scripts/check-contract-schema.sh   # contract/examples を JSON Schema で検証
   ./scripts/check-contract-identity.sh # 対向リポとのバイト一致検証 (要 gh 認証)
   ```
3. **対向リポの同名ブランチ確認**: 現在のブランチ名を取り、対向リポ (metaphor なら `shinyaoguri/metaphor-cli`、逆も同様) に同名ブランチがあるか `gh api repos/shinyaoguri/<sibling>/branches/<branch>` で確認する。
4. **結果の解釈と次アクション**:
   - identity チェックが赤 + 対向に同名ブランチ無し → 契約ファイルを両リポで揃える必要がある。対向リポに同名ブランチを切って同じ変更を適用するよう案内
   - 対向に同名ブランチがある → 両 PR を背中合わせでマージする段取りと、先にマージした側の push-to-main CI が一度赤くなる (re-run で解消) 点を伝える
   - 片側のみで作業を終える場合 → 対向リポへの Issue 起票を提案し、契約変更の要点を含む Issue 本文の下書きを提示する (起票は /quick-issue でも可)
