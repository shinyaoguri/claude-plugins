---
name: quick-issue
description: "作業中の気付きを metaphor / metaphor-cli の適切なリポジトリへ Issue 起票"
argument-hint: "<気付きの内容>"
---

「気付きは Issue へ」文化の実行支援。本題以外のバグ・ドキュメント不備・改善アイデアを、その場で直さずに適切なリポジトリへ起票する。気付きの内容: `$ARGUMENTS`

## 手順

1. **起票先の判定**:

   | 事象 | 起票先 |
   |---|---|
   | 描画・ライブラリ API・example・llms.txt | `shinyaoguri/metaphor` |
   | CLI コマンド・テンプレート・ビューア・MCP サーバ・インストール | `shinyaoguri/metaphor-cli` |
   | 両リポに跨る (CONTRACT.md・Probe wire format・環境変数・stdin イベント) | **両方に起票して相互リンク** |

   迷ったら metaphor-cli 側に立てる (README の方針: あちらで振り分ける)。

2. **重複確認**: `gh issue list -R shinyaoguri/<repo> --search "<キーワード>"` で既存 Issue を軽く確認。あれば起票せずリンクを提示して終了。
3. **起票**: `gh issue create -R shinyaoguri/<repo>` で起票する。本文には次を含める:
   - 事象 / 期待した動作と実際の動作
   - 再現手順 (分かる範囲で。`metaphor doctor` の出力が関係するなら添える)
   - **描画結果・見た目・動きが絡むなら視覚証跡** (撮り方は手順 4。起票の前に撮る)
   - 確信が持てない場合は「提案」であることを明記 (小さな気付きの起票も歓迎される文化)
4. **見た目・動きの事象は「壊れている絵」を貼る**。修正 PR には CI が証跡を要求するので直った絵は必ず残るが、**壊れていた絵は起票時にしか撮れない**。静止画だけでよいかアニメーション WebP も併載かの判断と、Gyazo への上げ方は gyazo-capture スキルが正本。metaphor は GUI を掴まなくても撮れる:

   | 撮りたいもの | 経路 |
   |---|---|
   | 実行中のスケッチ | sketch-loop スキル (MCP の snapshot / capture_sequence) |
   | ヘッドレスで 1 枚 | Probe (`METAPHOR_PROBE=1`。詳細は `CONTRACT.md`) |
   | 既にリポジトリにある生成物 (ゴールデン PNG・example の実行結果) | 撮らずに raw URL で貼る (`DEVELOPMENT.md`) |

   撮れないときは撮れない理由を本文に 1 行書いて起票する (**証跡が無いことを起票しない理由にしない**)。
5. 両リポ跨ぎの場合は 2 件起票し、双方の本文にもう一方の URL を追記して相互リンクにする。
6. 起票した URL を報告し、**本題の作業に戻る** (その場で直さない)。
