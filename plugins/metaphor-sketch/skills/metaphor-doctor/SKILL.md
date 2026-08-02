---
name: metaphor-doctor
description: "metaphor 環境の診断 (doctor + PATH 混在・MCP 登録・共有セッションの追加検査)"
---

metaphor の実行環境を診断する。`metaphor doctor` に加えて、プラグイン独自の検査を行い、問題ごとに修正方法を提示する。

## 検査項目

1. **CLI 本体**: `command -v metaphor` と `metaphor --version`
   - 見つからない → `brew install shinyaoguri/tap/metaphor` を案内
   - 実体パスで種別を判定: `/opt/homebrew/...` = brew 版 / `.build/debug/metaphor` = ローカル開発版 (direnv) / `~/.local/bin/metaphor` = direct installer 版
2. **旧インストールの残骸**: brew 版があるのに `~/.local/bin/metaphor` や `~/.local/share/metaphor` も存在する場合、PATH の先勝ちで旧版が brew 版を隠している可能性を警告。削除コマンド (`rm -f ~/.local/bin/metaphor` / `rm -rf ~/.local/libexec/metaphor ~/.local/share/metaphor`) は**提示のみで自動実行しない**
3. **公式診断**: `metaphor doctor` を実行し、`[warn]` 項目を解釈して伝える (Swift / Xcode / Package.swift / テンプレート / Syphon.framework)
4. **MCP 登録** (スケッチプロジェクト内の場合): `.mcp.json` に `metaphor` サーバ定義があるか。無ければ `claude mcp add metaphor -- metaphor mcp .` か `.mcp.json` の配置を案内
5. **共有セッション** (スケッチプロジェクト内の場合): `.metaphor/session.json` の有無と `pid` の生存 (`kill -0`)。stale なら「`metaphor watch` を先に起動 → AI クライアント側で `/mcp` 再接続」を案内
6. **ライブラリ解決** (スケッチプロジェクト内の場合): `.build/checkouts/metaphor/` の有無。無ければ `swift package resolve` を案内

## 出力

各項目を `[ok]` / `[warn]` で一覧にし、`[warn]` には修正コマンドを添える。破壊的な操作 (ファイル削除など) は提案の提示に留め、実行はユーザーに委ねる。
