# 0009: プラグインの粒度は enable/disable と version の単位で決める

- **状態**: 採用 (2026-08-05, Issue #37 の判断)
- **文脈**: gyazo-capture スキル (スクリーンショットの Gyazo ホスト手順) が repo-standards プラグインに同居していることを「関心の分離」の観点で問題視した ([#37](https://github.com/shinyaoguri/claude-plugins/issues/37))。#32 で汎用スキルの供給を marketplace へ一本化した際の意図的なトレードオフだったが、plugin description が「監査・雛形生成」と「スクショのホスト手順」の 2 本立てになっていた。分離の根拠として挙がったのは (a) description・keywords の凝集度と検索性、(b) スキル自動起動の判定精度への寄与、の 2 点。

  検証の結果:

  - **(b) は成立しない**。スキルの起動判定に使われるのは `SKILL.md` frontmatter の description のみで、`plugin.json` の description はマーケットプレイス表示用。プラグイン名はスキル名の名前空間接頭辞にしかならない (`repo-standards:gyazo-capture`)。分離しても起動精度は変わらない
  - **(a) の価値はほぼ無い**。全プラグインを自作し、全マシンで常時有効にしている個人用 marketplace では、一覧からの発見・検索という行為自体が発生しない
  - 一方 **分離のコストは実在する**。スキルの削除・リネームは破壊的変更 (`release:major`、[0003](0003-version-policy.md)) にあたり、加えて全マシンの settings.json (`enabledPlugins`) の更新と、version 系統・marketplace 登録・README 表の二重管理を招く
  - **gyazo-capture だけを切り出すのは対症療法**。実態として repo-standards の「リポジトリ」以外の関心は gyazo-capture だけではない (env-doctor はマシン環境の診断、report-issue は気付きの起票)。凝集していないのは中身ではなく、`repo-standards` という名前と、関心を羅列した description のほうだった

- **決定**:

  1. **プラグインの粒度は enable/disable と version の単位で決める**。分離が正当化されるのは「片方だけ無効にしたい環境がある」「片方だけ別ペースで version を刻みたい」「依存が重く入れたくない利用者がいる」のいずれかに当たるときに限る。description の凝集度・想像上の検索性・スキル起動精度は分離の理由にしない
  2. repo-standards は「**個人の開発運用標準**」— リポジトリ構成・GitHub 設定・マシンの Claude 環境・作業の記録の作法 — を一つの概念として定義する。plugin.json / marketplace.json / README の説明は関心の羅列でなく、この概念で書く
  3. **gyazo-capture の用途は Issue・PR への添付に限る**。汎用スクリーンショットユーティリティへは育てない (グローバル CLAUDE.md の「GUI を伴う作業は Issue・PR にスクショを添え、リポジトリに画像をコミットしない」の実行手段という位置づけ)
  4. 次のいずれかに当たったら分離を再議論する: **片方だけ無効化したいマシン・用途が出た** / **gyazo-capture が Issue・PR 添付以外の文脈で育ち始めた** / **repo-standards のスキルが 8 個を超えた** (現在 5 個)

- **影響**: #37 をクローズする。月次の [portfolio-review](../../.claude/skills/portfolio-review/SKILL.md) の統廃合判断はこの ADR を基準にし、同じ議論を毎月蒸し返さない。今後 marketplace に別スキルを同居させるかの判断も同じ基準で決める。
