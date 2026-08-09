---
name: report-issue
description: "repo-standards プラグインの利用中に起きた問題 (スキル・同梱スクリプトのエラー、記述と実態のずれ、使いにくさ・改善アイデア) を shinyaoguri/claude-plugins へ気軽に Issue 起票する。Use when a repo-standards skill or bundled script fails or behaves unexpectedly, when plugin instructions don't match reality, or when reporting problems or improvement ideas about the repo-standards plugin."
argument-hint: "[問題・気付きの内容]"
allowed-tools: "Bash(gh issue list:*)"
---

「気付きは Issue へ」文化の実行支援。repo-standards プラグインで起きた問題を、その場で直そうとせずに起票して本題へ戻る。**完璧な報告より気軽な報告を優先する** — 原因が分からなくても、確信が持てなくても、状況をそのまま書けばよい。内容: `$ARGUMENTS`

## 手順

1. **起票先の判定**:

   | 事象 | 起票先 |
   |---|---|
   | スキルの手順・同梱スクリプト (rs-*.sh)・プラグイン記述の問題 | `shinyaoguri/claude-plugins` |
   | チェック項目・判定基準そのもの (repo-standards.json の中身) の問題 | `shinyaoguri/setup` |
   | Gyazo アプリ本体の不具合 | 起票せずユーザーに報告 (プレビュー版でサポート対象外) |

   迷ったら claude-plugins 側に立てる (プラグインの入口なのであちらで振り分けられる)。

2. **重複確認**: `gh issue list -R shinyaoguri/claude-plugins --search "<キーワード>"` で軽く見る。あれば起票せず、既存 Issue へ状況をコメントで追記するか URL を提示して終了。
3. **起票**: `gh issue create -R shinyaoguri/claude-plugins` で起票する。web のテンプレートを通らないので **`--label` を明示的に付け**、本文は該当テンプレートの見出し構成に沿って書く:

   | 事象 | ラベル | 本文の見出し (テンプレート) |
   |---|---|---|
   | 動作不良・エラー・記述と実態のずれ | `--label freshness` | 検知元 / ずれの内容 / 影響と対処案 (drift-report.yml) |
   | 使いにくさ・改善アイデア | `--label improvement` | 背景・きっかけ / 提案内容 / 期待効果・放置した場合のリスク (improvement.yml) |

   本文に含めるもの (分かる範囲でよい):
   - 実行したスキル・コマンドと、期待した動作・実際の動作 (エラー出力はそのまま貼る)
   - 環境の手がかり (OS・リポジトリの種別など、関係しそうなものだけ)
   - 確信が持てない場合は「提案」「未切り分け」と明記する (小さな気付きの起票も歓迎される文化)
   - 秘密情報・実データを貼らない。パス・ID などの参照に置き換える
4. GUI が絡む事象ならスクリーンショットを gyazo-capture スキルで Gyazo に上げて URL を貼る (リポジトリに画像をコミットしない)。
5. 起票した URL を報告し、**本題の作業に戻る** (その場で直さない)。
