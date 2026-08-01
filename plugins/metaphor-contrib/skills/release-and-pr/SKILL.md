---
name: release-and-pr
description: shinyaoguri/metaphor または metaphor-cli で PR を作成する・PR タイトルを決める・リリースやバージョン bump を扱うとき、Syphon pin bump の bot PR で CI が走らないときに読む。Conventional Commits タイトルと release ラベルの規約。Use when creating a PR, deciding a PR title, planning a release or version bump in metaphor/metaphor-cli, or when a bot-created Syphon pin bump PR has no CI runs.
---

# metaphor / metaphor-cli のリリース・PR 規約

対象リポジトリ判定: cwd の `Package.swift` が `name: "metaphor"` または `name: "metaphor-cli"` のときだけ適用する。

## PR タイトルがリリースを決める

両リポとも squash merge のみで、**Conventional Commits 形式の PR タイトル = 最終コミット = リリース bump の判定材料**。マージするだけでリリースが自動で走る。

| 判定 (優先順) | 結果 |
|---|---|
| `release:skip` ラベル | リリースしない |
| `release:major` / `release:minor` / `release:patch` ラベル | 明示上書き |
| タイトル `feat:` | minor |
| タイトル `fix:` / `perf:` | patch |
| それ以外 (docs / chore / refactor / test / ci) | リリースなし (次の feat/fix に同乗) |

- **major は自動判定しない** (`!` 付きタイトルでも type どおりの bump)。major にしたいときは必ず `release:major` ラベルを付ける
- PR タイトルは日本語要約でよいが type/scope は規約どおりに (`feat(mcp): ...` 等)

## Syphon pin bump の bot PR

`syphon-bump.yml` が自動作成する PR は **CI が発火しない** (GITHUB_TOKEN 起点イベントは `pull_request` workflow をトリガーしない仕様)。required check を揃えるには PR を **close → reopen** する (自分のアカウント起点の reopened イベントで正規 CI が走る)。その後 green を確認して squash merge。`gh workflow run CI --ref <branch>` では required check として認識されない。

## 詳細の在処

- metaphor-cli: `AGENTS.md`「リリース手順」、`docs/homebrew.md` (Formula / tap)
- metaphor: `docs/releasing.md`
- bot PR 運用の経緯: metaphor-cli Issue #78
