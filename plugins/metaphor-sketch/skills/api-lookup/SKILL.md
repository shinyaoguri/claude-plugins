---
name: api-lookup
description: metaphor (Swift + Metal クリエイティブコーディング) の API を調べる・未知のシンボルを使う・cannot find in scope 等のコンパイルエラーを直すとき、metaphor の API を書く前に必ず読む。llms.txt / llms-sketch.txt / examples-index の場所解決と検索レシピ。Use before writing or inventing any metaphor API call, when looking up function signatures, resolving "cannot find in scope" errors, or searching metaphor example sketches.
allowed-tools: "mcp__metaphor__api_reference"
---

# metaphor API の調べ方

metaphor の API を**発明しない**。Processing / p5.js の記憶からの類推で書かず、必ず以下の順で実物を確認する。

## 優先順位 1: MCP `api_reference` (使えるなら常にこれ)

依存解決済みの metaphor と**同一バージョン**の文書が返るため、パス解決自体が不要。

- `doc=sketch` — 作法ガイド (既定。まずこれ)
- `doc=full` — 全 API リファレンス。**必ず `grep` 引数と併用**する (全文は巨大)
- `doc=examples` — サンプル索引

## 優先順位 2: ファイル直接参照 (MCP が無い環境)

METAPHOR_ROOT を次の順で解決する:

1. cwd 自体が metaphor checkout (`Package.swift` に `name: "metaphor"`) → cwd
2. cwd の `Package.swift` が `.package(path: "...")` で metaphor を参照 → そのパス (`--metaphor-path` 生成や手書きローカル依存)
3. `.build/checkouts/metaphor/` が存在 → そこ (リリース参照の SwiftPM 依存はここに落ちる)
4. どれも無い → `swift package resolve` を実行してから 3 を再試行

環境ごとの既定: `metaphor new` 生成プロジェクト = MCP が既定・3 がフォールバック / SwiftPM 直依存のみ = 3→4 / metaphor checkout 内 = 1・2。

## 解決後に読むファイルと読み方

| ファイル | 読み方 |
|---|---|
| `$METAPHOR_ROOT/llms-sketch.txt` | **全文読んでよい** (約 4KB)。スケッチ作法・禁則の正典 |
| `$METAPHOR_ROOT/llms.txt` | **全文読み込み禁止** (約 190KB)。`grep -i` で部分参照のみ |
| `$METAPHOR_ROOT/docs/ai/examples-index.json` | jq で絞り込み (下記) |
| `$METAPHOR_ROOT/docs/ai/prompts/` | ジャンル別の定型プロンプト 6 本 (generative-2d / audio-reactive / shader-effect / vj-loop / debug-fix / polish-iteration) |

検索レシピ:

```bash
# シグネチャ検索 (関数名・型名で部分一致)
grep -i -n "func circle" "$METAPHOR_ROOT/llms.txt"

# supported な 3D サンプルのパス一覧
jq -r '.examples[] | select(.status == "supported")
       | select(.tags | index("3d")) | .path' "$METAPHOR_ROOT/docs/ai/examples-index.json"

# 元 Processing サンプルが PVector を扱う例
jq -r '.examples[] | select(.featured | index("PVector")) | .path' "$METAPHOR_ROOT/docs/ai/examples-index.json"
```

## サンプル参照の作法

- 新しい構造を発明する前に、リクエストのタグに近いサンプルを 1〜2 本選び、その `App.swift` を読む
- `status` が `stub` (未実装 API 待ち) と `obsolete` (Processing/OpenGL 固有) のサンプルは参照しない
- p5.js コードの逐語訳より、既存 metaphor イディオムへの適応を優先する
