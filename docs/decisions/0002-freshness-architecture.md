# 0002: 陳腐化防止は 4 層構成とし、文書ルールより決定論的な仕組みを優先する

- **状態**: 採用 (2026-08-02)
- **文脈**: 薄いルーター設計 ([0001](0001-thin-router.md)) の帰結として、上流参照のドリフトが最大の陳腐化リスク。加えて (a) SKILL.md frontmatter の YAML 破損は `claude plugin validate <plugin-dir>` でしか検出できない、(b) marketplace.json ↔ plugin.json の version 不整合、(c) 仕組み (CI・CLAUDE.md・スキル) 自体の陳腐化、という壊れ方がある。文書ルールだけでは守られる保証がないため、強制できるものは仕組みへ寄せる。
- **決定**: 次の 4 層で防止する。
  | 層 | 実行 | 担当 |
  |---|---|---|
  | 常時強制 | ブランチ保護・Issue/PR テンプレート・Dependabot | GitHub 設定 / `.github/` |
  | PR CI | validate + 整合性 + version bump + マニフェスト網羅 | `.github/workflows/ci.yml` + `scripts/` |
  | 週次 | 上流参照の実在 + リンク切れ → Issue 自動起票 | `.github/workflows/freshness.yml` |
  | 月次 | 利用状況からの新設・統廃合提案 + 意味的ドリフト + 仕組み自体のメタレビュー | `.claude/skills/portfolio-review/` (ローカル scheduled task) |
  - 上流参照は `upstream-refs.json` にマニフェスト化する。マニフェスト自体の記載漏れは PR CI の coverage チェック (プラグイン本文からのトークン抽出) で防ぐ
  - 俯瞰レビューをローカル実行にするのは、利用状況データ (セッション履歴) がマシン上にしかなく、Actions への API キー登録も不要になるため
  - 週次/月次の使い分け: 機械検知は安価なので週次、俯瞰レビューの成果物は「対応に工数を要する提案」なのでノイズ化を防ぐため月次
- **影響**: プラグイン本文に新しい上流参照を書くときは `upstream-refs.json` への追記が必要 (忘れると PR CI が赤くなる)。CI の実行環境は `npm install -g @anthropic-ai/claude-code` に依存する。検知の正本は Issue (label: freshness) に集約される。
