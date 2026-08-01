---
name: cross-repo-contract
description: "shinyaoguri/metaphor または metaphor-cli リポジトリで CONTRACT.md・contract/・scripts/check-contract*.sh・契約実装ファイル (SketchRunner, InputInjectionPlugin, Probe 系, ViewerWatch, ViewerWindow, SyphonFrameSource, Package.swift の Syphon pin) に触れるとき、METAPHOR_* 環境変数・Probe wire format (.metaphor/probe)・stdin JSON Lines 入力イベント・MCP ツール定義の変更を扱うときに必ず読む。Use when changing anything covered by the metaphor ⇄ metaphor-cli cross-repo contract: CONTRACT.md, contract/ schemas, METAPHOR_* env vars, Probe files, stdin input events, or the Syphon binaryTarget pin."
---

# metaphor ⇄ metaphor-cli クロスリポ契約

対象リポジトリ判定: cwd の `Package.swift` が `name: "metaphor"` または `name: "metaphor-cli"` のときだけ本スキルを適用する。それ以外のリポジトリでは何もしない。

両リポは Swift 依存を持たず、**ランタイム/バイナリの暗黙契約**だけで結合している。契約に触れる変更は片方のリポで完結しない。

## 変更の 4 原則

1. **両リポ同時更新**: 契約の producer (metaphor) と consumer (metaphor-cli) を同時に直す
2. **両リポで同名ブランチ**: identity チェック (`check-contract-identity.sh`) は対向リポの**同名ブランチを優先して比較**し、無ければ default branch と比較する。同名ブランチにしないと片側の CI が赤くなる。なお先にマージした側の push-to-main CI は対向の古い main と比較して一度赤くなる — 対の PR を背中合わせでマージし、その 1 ジョブを re-run する
3. **`./scripts/check-contract.sh` が green** であることをコミット前に確認 (`make contract` でも可)
4. **片側のみで作業する場合**は、対向リポに対応する Issue / PR を必ず立てる

## バイト一致が要求されるファイル (identity セット)

以下は両リポに**同一内容**で複製され、CI が一致を検証する。片側だけ編集してはならない:

- `CONTRACT.md`
- `contract/**` (README.md / `*.schema.json` / `examples/*.json`)
- `scripts/check-contract.sh` / `check-contract-schema.sh` / `check-contract-identity.sh`

## 契約に触れる実装ファイル (編集したら本スキルの対象)

- metaphor 側: `SketchRunner.swift` (環境変数) / `InputInjectionPlugin.swift` (stdin JSON Lines) / `Sources/MetaphorCore/Probe/` (Probe ファイル) / Release ワークフロー (Syphon pin 発行)
- metaphor-cli 側: `ViewerWatch.swift` / `ViewerWindow.swift` / `SyphonFrameSource.swift` / `MCP/` 配下 / `Package.swift` の Syphon binaryTarget pin
- 共通の概念: `METAPHOR_PROBE` `METAPHOR_VIEWER` `METAPHOR_SYPHON_NAME` `METAPHOR_FPS` `METAPHOR_SOURCE_STAMP`、`.metaphor/probe/` のファイル群、`.metaphor/session.json`

## 詳細の在処

契約 6 点の定義・wire スキーマ・変更ルールの全文は、**cwd の `CONTRACT.md`** (両リポに必ず存在) を読む。wire 形式の正典は `contract/*.schema.json`。新しい IPC (Probe ファイルや stdin イベント) を増やす変更は、それ自体が新しい契約点になるため CONTRACT.md への追記とチェックスクリプトのトークン更新まで含めて 1 セット。
