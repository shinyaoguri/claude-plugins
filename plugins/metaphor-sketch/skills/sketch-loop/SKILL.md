---
name: sketch-loop
description: metaphor (Swift + Metal クリエイティブコーディング) のスケッチを作成・編集・実行・デバッグするとき、表示が真っ黒・想定と違う・snapshot が古い/別物に見えるとき、metaphor watch や MCP ツール (snapshot / capture_sequence / input / build_status / api_reference) を使うときに読む。Use when writing, fixing, or running a metaphor sketch (Sketch protocol, App.swift, import metaphor, metaphor watch/run), or when MCP snapshots look black, wrong, or stale.
---

# metaphor スケッチの観測ループ (observe → edit → verify)

metaphor は「AI がいま見えている絵を観測しながら直す」ためのライブラリ。
コードを想像で直さず、必ず MCP ツールで観測しながら反復する。

## 最重要: 起動順序 (共有セッション)

人間がライブビューアを見ながら AI と協調する場合、**必ず `metaphor watch` が先、AI クライアントが後**。

- `metaphor mcp` (AI クライアントが裏で自動起動) が「動作中の watch にアタッチするか / 自前の別インスタンスを起動するか」を決めるのは**起動した瞬間に 1 回だけ**。`.metaphor/session.json` の pid 生存で判定し、後から再チェックしない。
- 逆順だと MCP は**別のヘッドレスインスタンス**を観測し、ユーザーのライブビューア窓とは別物になる。snapshot が「ユーザーの見ている絵と違う」ときはまずこれを疑う。
- **復旧**: `metaphor watch` を起動した状態で、クライアント側の `/mcp` で metaphor サーバを再接続する (mcp が再起動してアタッチし直す)。
- `metaphor watch --no-probe` は共有を無効化する。snapshot が失敗し続けるときは watch の起動フラグも確認。
- AI 単独で作業する場合 (人間がビューアを見ない) は watch 不要。MCP が自前のヘッドレスインスタンスを起動して観測できる。

## 反復ループの定型

1. **観測**: `snapshot` で現在フレームの PNG + 内部状態 (frame.json) を取得。まず現状を見る
2. **編集**: ソースをファイルとして直接編集する (watch が再ビルドして反映)
3. **検証**: `build_status` でコンパイル成否を確認 → 成功したら `snapshot` で再観測
4. 期待と違えば 2 に戻る。「直った」と主張する前に必ず snapshot で裏取りする

## MCP 5 ツールの使い分け

| ツール | 使う場面 |
|---|---|
| `snapshot` | 静止した 1 フレームの確認。性能診断 (fps/メモリ/CPU/thermal) も frame.json の `performance` で画像に頼らず判定できる |
| `capture_sequence` | 動き・リズム・遷移の確認 (frames 指定必須)。コンタクトシート + sequence.json が返る。1 枚でよければ snapshot |
| `input` | 実行中スケッチへマウス・キー入力を送る (**単独モードのみ**。共有セッションでは入力注入なし) |
| `build_status` | 編集後のコンパイル成否・エラー出力の確認。snapshot の前に挟む |
| `api_reference` | API を使う前の参照 (api-lookup スキル参照)。`grep` 引数で部分参照できる |

- 初回の snapshot は cold-start を待つため `timeout` を長め (既定 15 秒) に。
- スケッチ側から状態を報告させたいときは `draw()` 内で `probe("particles.count", n)` を書くと frame.json に載る (Probe 未登録時は no-op)。

## 詳細の在処

- MCP・共有セッションの正典: [metaphor-cli README「AI と協調する」](https://github.com/shinyaoguri/metaphor-cli#ai-と協調する)
- frame.json のフィールド定義: 依存 checkout の `contract/frame.schema.json` (または [CONTRACT.md](https://github.com/shinyaoguri/metaphor/blob/main/CONTRACT.md))
- プロジェクト固有の意図・制約: そのプロジェクトの `AGENTS.md` と `PROJECT_BRIEF.md` (metaphor new が生成)
