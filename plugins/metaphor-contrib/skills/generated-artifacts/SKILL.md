---
name: generated-artifacts
description: shinyaoguri/metaphor リポジトリで Sources/**/*.swift・Examples/**・Sources/MetaphorCore/Shaders/Metal/** を編集するとき、llms.txt や docs/ai/examples-index.{md,json} や ShaderSources/*.txt に差分が現れたとき、新しい example を追加するときに読む。生成物の再生成ルール。Use when editing metaphor library sources, examples, or Metal shaders, when llms.txt or examples-index show diffs, or when adding a new example package.
---

# metaphor の生成物 (checked-in generated files)

対象リポジトリ判定: cwd の `Package.swift` が `name: "metaphor"` のときだけ適用する。

以下の 3 種はリポジトリにチェックインされているが**生成物**であり、**手で編集してはならない**。入力を変えたら対応する make ターゲットで再生成してからコミットする。

| 生成物 | 入力 | 再生成 |
|---|---|---|
| `llms.txt` | `Sources/**/*.swift` | `make llms-txt` |
| `docs/ai/examples-index.{md,json}` | `Examples/**` | `make examples-index` |
| `Sources/MetaphorCore/Shaders/ShaderSources/*.txt` | `Sources/MetaphorCore/Shaders/Metal/*.metal` | (metaphor リポの Makefile 参照) |

- 鮮度は pre-push フック (`make setup` が導入) と CI の二重で検証され、陳腐化していると push / PR が止まる
- 生成器は**決定的**であること (全コレクションをソート)。非決定的出力は auto-fix bot が毎回 push する原因になる
- 新しい example は `Examples/{Category}/{Subcategory}/{Name}/` の自己完結 SwiftPM パッケージとして追加し、追加後に `make examples-index` を実行する
- CLAUDE.md 内のコマンド名・パス等の整合は `make ai-docs-check` (`scripts/validate-ai-docs.sh`) が検査する

正式な表と仕組みの詳細は cwd の `CLAUDE.md`「自動生成される AI 向けファイル」と `DEVELOPMENT.md` を読む。
