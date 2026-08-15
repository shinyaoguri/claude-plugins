---
name: report-issue
description: "作業中に気付いた本題以外のバグ・ドキュメント不備・改善アイデアを、その場で直さず適切なリポジトリへ Issue 起票する (作業中のリポ / repo-standards プラグイン / 個人標準そのもの)。Use when noticing an unrelated bug, doc gap, or improvement idea while working, when filing an issue with gh, or when a repo-standards skill or bundled script fails or its instructions don't match reality."
argument-hint: "[気付き・問題の内容]"
allowed-tools: "Bash(gh issue list:*), Bash(gh repo view:*), Bash(gh label list:*)"
---

「気付きは Issue へ」文化の実行支援。本題以外のバグ・ドキュメント不備・改善アイデアを、その場で直さずに起票して本題へ戻る。**完璧な報告より気軽な報告を優先する** — 原因が分からなくても、確信が持てなくても、状況をそのまま書けばよい。内容: `$ARGUMENTS`

## 手順

1. **起票先の判定**:

   | 事象 | 起票先 |
   |---|---|
   | 作業中のリポで気付いた、本題と別の問題・改善案 | そのリポ (`gh repo view --json nameWithOwner -q .nameWithOwner`) |
   | repo-standards のスキル手順・同梱スクリプト (rs-*.sh)・プラグイン記述の問題 | `shinyaoguri/claude-plugins` |
   | チェック項目・判定基準そのもの (個人標準 repo-standards.json の中身) の問題 | `shinyaoguri/setup` |
   | Gyazo アプリ本体の不具合 | 起票せずユーザーに報告 (プレビュー版でサポート対象外) |

   作業中のリポと、その上流・下流のリポ (ライブラリと CLI など) の両方に跨るなら**両方へ起票して相互リンクする**。プラグイン絡みで迷ったら claude-plugins 側に立てる (入口なのであちらで振り分けられる)。

2. **重複確認**: `gh issue list -R <repo> --search "<キーワード>"` で軽く見る。あれば起票せず、既存 Issue へ状況をコメントで追記するか URL を提示して終了。

3. **タイトルは Conventional Commits で書く** (`<type>(<scope>): <要約>`)。PR タイトルと同じ形なので後から拾いやすく、タイトルの型からラベルを決める仕組みを持つリポではこれがラベル付けの入口になる。

4. **ラベルと本文の見出しは起票先から読む**。**`gh issue create` は web の Issue テンプレートを通らない** — テンプレートの `labels:` も本文の見出しも一切適用されないので、自分で揃える:

   ```bash
   ls .github/ISSUE_TEMPLATE/     # あれば、事象に合うテンプレートの labels: と見出し構成を読む
   gh label list -R <repo>        # テンプレートが無ければ既存ラベルから選ぶ
   ```

   - **テンプレートの内容をこのスキルへ写さない** (テンプレートが正本。増減しても追随が要らない)
   - 選んだラベルは **`--label` で明示的に付ける**。ここでの付け忘れは後から自動では拾えず、無ラベルの Issue が溜まって triage が効かなくなる
   - **ラベルを決められないことを、起票しない理由にしない**。ラベル無しで立てても情報は失われない (後から付けられる)

5. **起票**: `gh issue create -R <repo> --title <title> --label <label> --body <body>`。本文に含めるもの (分かる範囲でよい):

   - 事象 / 期待した動作と実際の動作 (エラー出力はそのまま貼る)
   - 実行したコマンド・スキルと、再現手順
   - 環境の手がかり (OS・リポジトリの種別など、関係しそうなものだけ)
   - 確信が持てない場合は「提案」「未切り分け」と明記する (小さな気付きの起票も歓迎される文化)
   - 秘密情報・実データを貼らない。パス・ID などの参照に置き換える

6. GUI が絡む事象ならスクリーンショットを gyazo-capture スキルで Gyazo に上げて URL を貼る (リポジトリに画像をコミットしない)。
7. 起票した URL を報告し、**本題の作業に戻る** (その場で直さない)。
