# 0004: 公式非推奨のプラグイン構成を排除し、CI で機械的に禁止する

- **状態**: 採用 (2026-08-02)
- **文脈**: 公式ドキュメント (code.claude.com/docs) との突き合わせ監査で、公式が非推奨・廃止と明言する構成パターンが複数あることを確認した。このリポジトリでは (a) version の二重指定 (対処済み: [0003](0003-version-policy.md))、(b) スラッシュコマンドの `commands/` 配置 — 公式リファレンスは commands/ を互換維持と位置づけ "Use `skills/` for new plugins" と明記 — が該当した。公式の非推奨は今後も増えるため、都度の人手レビューでは同種の逸脱が再発する。[0002](0002-freshness-architecture.md) の方針どおり決定論的な仕組みへ寄せる。
- **決定**:
  - スラッシュコマンドも `skills/<name>/SKILL.md` として作る。既存 4 コマンド (contract-check / quick-issue / metaphor-doctor / metaphor-new) は skills へ移行 (呼び出し名・挙動は不変。frontmatter に `name` を明示)
  - 公式が非推奨・廃止と明言するパターンを `scripts/check-deprecated-patterns.sh` に列挙し、PR CI (validate ジョブ) で強制する。検査項目と公式根拠はスクリプト冒頭のコメントが正本: commands/ 不使用 / `.claude-plugin/` 直下はマニフェストのみ / プラグイン root の CLAUDE.md 禁止 / shell フィールドの `${user_config.*}` 禁止 / `../` によるプラグイン外参照の禁止 / hook command への `${CLAUDE_PLUGIN_ROOT}` 前置 / top-level `monitors` 禁止 (version 二重指定は check-consistency.sh 側)
  - 公式の非推奨リストの鮮度は月次 portfolio-review の「仕組み自体の点検」で公式ドキュメント (plugins-reference / plugin-marketplaces / skills) と突き合わせて維持する
- **影響**: 非推奨パターンを含むプラグインは PR CI が赤くなり main に入らない。新規のスラッシュコマンドは skills として作る (README の追加手順を更新)。marketplace.json の `$schema` が指す URL は 2026-08 時点で JSON を返さないが、公式スキーマ表に「Claude Code はロード時に無視する」とあるフィールドのため許容している。
