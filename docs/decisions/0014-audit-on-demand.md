# 0014: 監査は起動されたときに走れば足り、定期実行は導入しない

- **状態**: 採用 (2026-08-09, Issue [#22](https://github.com/shinyaoguri/claude-plugins/issues/22) の判断)
- **文脈**: [#22](https://github.com/shinyaoguri/claude-plugins/issues/22) は setup リポ #42 (Claude 用トークンから Administration を剥奪する) の撤回に伴う代替として、`rs-audit-github.sh` / `rs-audit-repo.sh` を GitHub Actions で定期実行し、必須項目の違反 (`ng`) が出たら Issue 起票する案だった。狙いは 2 つで、**実行環境を Claude の手の届かない場所に置く**ことと、ruleset や必須項目が後から崩れても次に誰かが監査を回すまで気付けない穴を塞ぐこと。検討の過程でこのリポ自身の `license-exists` 違反 (public なのに LICENSE 未設置) が未検知のまま残っていた実例もある。

  一方で、Issue が挙げた実装上の論点は未決のまま残っていた:

  - プラグイン同梱スクリプト (`${CLAUDE_PLUGIN_ROOT}/scripts/`) を CI から呼ぶ経路が要る。プラグインを「CI からも使えるツール」として扱うのは新しい用途で、薄いルーター原則 ([0001](0001-thin-router.md)) との整合も要る
  - 正本 `repo-standards.json` は setup リポにあり、CI からは `~/.claude/` 経由で解決できない。取得経路を別に用意することになる
  - **どのリポで動かすか**が決まらない。各リポに置けば N 個のワークフローを維持することになり、1 箇所から複数リポを監査するならトークン権限の設計が要る
  - LLM 判定 (`check.type: llm`) は CI では回せず、機械判定だけの部分監査になる。判定精度を優先した [0012](0012-audit-precision.md) の設計と噛み合わない

- **決定**: **定期実行の仕組みは導入しない**。監査は `/repo-audit` / `/repo-audit-min` が**起動されたときに走れば足りる**ものとする。上の論点を解いてまで自動化する価値は無いと判断した。

- **影響**: リポジトリ設定・構成のドリフトは、次に監査を起動するまで検知されない。この空白は意識して空けたままにする — 代わりに**起動の敷居を下げる側**に投資が寄っており、安い層 ([0011](0011-audit-cost-tiers.md) の repo-audit-min) と許可プロンプトの削減 (PR [#73](https://github.com/shinyaoguri/claude-plugins/pull/73)) が既に入っている。既存の週次 ([freshness.yml](../../.github/workflows/freshness.yml)) と月次 (portfolio-review) は上流参照とプラグイン構成が対象で、リポジトリ設定の監査は含まない。アカウント設定の変更検知 ([#21](https://github.com/shinyaoguri/claude-plugins/issues/21)) は対象が別 (GitHub の security log) なので、本 ADR の射程外として open のままにする。
