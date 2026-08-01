---
description: metaphor スケッチプロジェクトを対話的に作成 (テンプレート推薦つき)
argument-hint: "[name] [--template <id>]"
---

metaphor のスケッチプロジェクトを作成する。引数: `$ARGUMENTS`

## 手順

1. `command -v metaphor` で CLI の存在を確認。無ければ `brew install shinyaoguri/tap/metaphor` を案内して終了。
2. 引数に名前とテンプレートが揃っていれば、そのまま `metaphor new` を実行する。
3. 名前だけ・引数なしの場合は、**作りたいものを 1 問だけ**聞き、以下の意図マップでテンプレートを推薦する。推薦前に `metaphor examples` を実行し、実在するテンプレート一覧と説明を確認する (将来のテンプレート追加に追従するため、このマップより実物を優先):

   | 意図 | テンプレート |
   |---|---|
   | 最初の 1 本・2D 主体の作品 | `2d` (既定) |
   | 3D 空間・カメラワーク | `3d` |
   | 独自の Metal シェーダ表現 | `shader` |
   | VJ・ライブ演出・OSC/MIDI 外部機器 (パラメータ GUI・Performance HUD 付き) | `live` |
   | 音 (マイク入力 FFT) に反応する作品 | `audio-reactive` |
   | レイトレーシング表現 | `raytracing` |
   | MadMapper / Resolume 等へ映像を送る | `syphon` |

4. `metaphor new <name> --template <id>` を実行する。既存ディレクトリを in-place で初期化したい場合は `metaphor init` (= `metaphor new .`)。ローカルの metaphor checkout を参照させたい場合のみ `--metaphor-path` を付ける。
5. 生成後、次を必ず案内する:
   - 実行は `cd <name> && metaphor run`
   - **AI と協調して作るなら、必ず `metaphor watch` を先に起動してから AI クライアントを開く** (逆順だと MCP が別インスタンスを観測する。詳細は sketch-loop スキル)
   - MCP 登録は生成済みの `.mcp.json` が担うため追加作業は不要
