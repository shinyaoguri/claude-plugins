# claude-plugins 開発規約

個人用 plugin marketplace。構成とプラグイン追加手順は [README.md](README.md) が正本。設計判断の経緯は [docs/decisions/](docs/decisions/) の ADR にある。

## 設計原則

- プラグインは上流正典ドキュメントへの**薄いルーター**。正典の内容を複製しない (ADR [0001](docs/decisions/0001-thin-router.md))
- プラグイン本文に上流リポのパス・ファイル参照を書き足したら [upstream-refs.json](upstream-refs.json) にも追記する (PR CI の coverage チェックが漏れを検出する)

## 検証

- `claude plugin validate` は**各プラグインディレクトリに対して**実行する。ルートへの validate は marketplace.json しか見ず、SKILL.md frontmatter の YAML 破損を検出できない
- SKILL.md の frontmatter description は必ずクォートする (裸の `: ` が混ざると YAML パースが落ち、メタデータ全体が無視される)
- CI と同じチェックはローカルで `scripts/check-consistency.sh` / `scripts/check-version-bump.sh` / `scripts/check-upstream-refs.sh --coverage` として実行できる

## バージョン規約

- `plugins/<name>/` 配下を変更したら、plugin.json と marketplace.json の version を**同時に** bump する (PR CI が強制)

## 記録規約 (メモリリセット耐性)

- 気付き・改善案・迷った判断は作業を止めずに Issue へ (テンプレートあり)。チャットや auto-memory にだけ残すのは禁止 (揮発する)
- 確定した設計判断は docs/decisions/ に ADR として追記する

## 陳腐化防止の仕組み

| 層 | 実行 | 正本 |
|---|---|---|
| PR CI | validate + 整合性 + version bump + マニフェスト網羅 | [.github/workflows/ci.yml](.github/workflows/ci.yml) |
| 週次 | 上流参照の実在 + リンク切れ → Issue 起票 | [.github/workflows/freshness.yml](.github/workflows/freshness.yml) |
| 月次 | 利用状況・意味的ドリフト・仕組み自体の俯瞰レビュー | [.claude/skills/portfolio-review/](.claude/skills/portfolio-review/SKILL.md) |

同種の問題・手戻りが 2 回起きたら、文書ルールの追記でなく仕組み (CI・hooks・スクリプト) への昇格を検討して Issue 起票する。
