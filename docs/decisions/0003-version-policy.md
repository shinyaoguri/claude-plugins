# 0003: version は plugin.json を唯一の正とし、bump は PR 内で行い CI が期待増分を強制する

- **状態**: 採用 (2026-08-02)
- **文脈**: 公式ドキュメントの調査で 2 つの事実が判明した。(1) クライアントの更新判定は version 比較で行われ、**bump しないマージは他マシンへ伝搬しない**。(2) plugin.json と marketplace.json の両方に version を書くのは公式非推奨 (plugin.json が無警告で優先される)。また、マージ後に bot が bump コミットを積む方式は、ブランチ保護 (PR 必須) と「GITHUB_TOKEN 起点の push では CI が発火しない」制約 (metaphor の syphon-bump PR で既知) に衝突し、PAT/App の管理が必要になる。
- **決定**:
  - version は plugin.json のみに置き、marketplace.json のエントリからは削除する (check-consistency.sh が再発を検査)
  - bump は**変更と同じ PR 内**で行う。期待増分は決定論的に導出する: `release:major|minor|patch|skip` ラベル > PR タイトル type (feat → minor / fix → patch)。CI (pr-policy) がタイトル lint と「期待増分どおりの bump」を強制する
  - `plugins/**` を触る PR の type は feat / fix に限定する (本文 = 製品であり、docs/chore はリポの仕組み側専用)
  - **major はラベルでのみ宣言できる** (`!` 付きタイトルでも type どおり)。事故 major を防ぐ metaphor / metaphor-cli の規約に揃える
  - 検討した代替: (A) version 廃止で commit SHA に委譲 — 保守ゼロだが変更の重みの伝達を放棄するため不採用 / (C) release-please — CHANGELOG は魅力だが伝搬が release PR マージまで遅れ、権限整備も増えるため不採用
- **影響**: プラグイン変更の公開 (伝搬) はマージと同時になる。PR 作者 (通常 Claude) は bump を忘れても CI が正確な期待 version を提示する (`scripts/bump-version.sh` で 1 コマンド修正)。required check は `validate` + `pr-policy` (ruleset も更新)。`release:skip` は「伝搬しない」ことを理解した上での例外運用とする。
