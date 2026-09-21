# claude-plugins 開発規約

個人用 plugin marketplace。構成とプラグイン追加手順は [README.md](README.md) が正本。設計判断の経緯は [docs/decisions/](docs/decisions/) の ADR にある ([索引](docs/decisions/README.md#索引) の「現行」2 群から読む)。

## 設計原則

- 上流に正典があるものは内容を複製せず、場所と読み方だけを書く (ADR [0001](docs/decisions/0001-thin-router.md))。判定ロジックを同梱するなら、正本との契約を同じリポジトリで e2e テストして守る (ADR [0022](docs/decisions/0022-repo-standards-bundled.md)) — repo-standards は後者で、薄いルーターではない
- プラグイン本文に上流リポのパス・ファイル参照を書き足したら [upstream-refs.json](upstream-refs.json) にも追記する (週次 freshness が上流での実在を検査する。追記漏れを PR CI では検出しない — ADR [0028](docs/decisions/0028-detection-needs-closure.md))
- 公式が非推奨とする構成は使わない (ADR [0004](docs/decisions/0004-deprecation-guard.md)、`scripts/check-deprecated-patterns.sh` が CI で強制)。スラッシュコマンドも `commands/` でなく `skills/<name>/SKILL.md` として作る
- 汎用スキルは `~/.claude/skills/` でなく **plugin として配る** (ADR [0020](docs/decisions/0020-skills-ship-as-plugins.md))。hooks・agents・scripts を同じ単位に束ねられ、enable/disable と version で伝搬を制御できるのはプラグインだけ
- プラグインの粒度は **enable/disable と version の単位**で決める (ADR [0009](docs/decisions/0009-plugin-granularity.md))。description の凝集度だけを理由に分割しない (スキルの起動判定は SKILL.md の description のみを見るため、分割しても起動精度は変わらない)

## 検証

- `claude plugin validate` は**各プラグインディレクトリに対して**実行する。ルートへの validate は marketplace.json しか見ず、SKILL.md frontmatter の YAML 破損を検出できない
- SKILL.md の frontmatter description は必ずクォートする (裸の `: ` が混ざると YAML パースが落ち、メタデータ全体が無視される)
- CI と同じチェックはローカルで `scripts/check-consistency.sh` / `scripts/check-deprecated-patterns.sh` / `scripts/check-version-bump.sh` として実行できる。これらと `scripts/test-*.sh`・`claude plugin validate`・gh の参照系は [.claude/settings.json](.claude/settings.json) で事前許可してあり確認プロンプトが出ない。**破壊的・外部影響のあるコマンド (`git push` / `gh pr merge` / `gh issue create` / `apply-repo-settings.sh --apply` 等) は allow に入れない**
- GitHub のリポジトリ設定は [.github/repo-settings.json](.github/repo-settings.json) が正本。**設定は GitHub の画面や gh コマンドで直接変えず、この JSON を変える PR として出す** (ADR [0008](docs/decisions/0008-repo-settings-as-code.md))。適用は `scripts/apply-repo-settings.sh --apply`、差分検査は引数なし。**admin 権限のあるトークンで実行する** (CI の GITHUB_TOKEN では管理系フィールドが読めないため CI では回さない)
- プラグイン同梱スクリプトの判定ロジックは `scripts/test-rs-*.sh` (対象スクリプトごとに 1 本) でテストする。一時 git リポと最小 manifest を組み立て、出力 (JSON Lines) の status を検証するエンドツーエンド方式 (正本との出力契約ごと守るため、関数を source しない)。同梱フック (`hooks/scripts/`) も同じ流儀で、検証対象は Claude Code との契約である**終了コードと、フックが返す判定** (Stop 系は stderr、PreToolUse は stdout の `permissionDecision`) になる (`gh` はスタブに差し替え、GitHub にも Claude セッションにも触らない)
- 正本 (`repo-standards.json`) に項目を足すとき、**設置するだけでは価値が出ず使われて初めて意味を持つもの**は `evidence.kind` を `observation` にし、`scripts/measure-standards-usage.sh` に測り方を足す (ADR [0029](docs/decisions/0029-measure-what-the-standard-installs.md))。`principle` は守りと、測りようのないものに限る
- エージェントの振る舞いを縛るフックは各リポにコミットせず、`repo-standards` プラグインが `hooks/hooks.json` で供給する (ADR [0016](docs/decisions/0016-agent-behavior-hooks-in-plugin.md))。個人標準 (`repo-standards.json`) には項目を足さない
- **人間の承認はプラン 1 点へ集約し、その 1 点も合意済みなら待たない** (ADR [0017](docs/decisions/0017-approval-at-the-plan.md) と 2026-09-07 の改訂)。可逆な操作に確認を挟まない代わりに、合意なしの実装拡大は `plan-gate` フックが deny で止める。**トリアージ印の付いた open な Issue に紐づくプランは `plan-pass` フックが `allow` を返して承認プロンプトを消す** — 消すのは待つことだけで、プランを書くことも記録することも変えない。`plan-pass` は `deny` を返さず、判定できないものはすべて素通しで人へ返る (逃げ道は `RS_PLAN_PASS=0`)。分類器の設定 (`autoMode.*`) は仕様上プラグインから供給できないので、プラグインは **`env-doctor` で診断するだけ**にとどめ、実体は setup リポの `claude/settings.json` に置く

## バージョン規約 (ADR [0003](docs/decisions/0003-version-policy.md))

- version の正は各 plugin.json のみ。**marketplace.json には version を書かない** (plugin.json が無警告で優先されるため公式非推奨。CI が検査)
- **version を bump しないマージは他マシンへ伝搬しない** (クライアントは version 比較で更新判定する)
- `plugins/<name>/` を触る PR は、同じ PR 内で `scripts/bump-version.sh <name> <major|minor|patch>` で bump する。CI (pr-policy) が見るのは「bump 済みか」だけで、増分は人が選ぶ: 機能追加 minor / 修正 patch / 破壊的変更 (スキルの削除・リネーム、hook の非互換変更、プラグイン統廃合) major (ADR [0028](docs/decisions/0028-detection-needs-closure.md))

## 記録規約 (メモリリセット耐性)

- 気付き・改善案・迷った判断は作業を止めずに Issue へ。チャットや auto-memory にだけ残すのは禁止 (揮発する)
- Issue は [.github/ISSUE_TEMPLATE/](.github/ISSUE_TEMPLATE/) の見出し構成に沿って書く (改善提案なら 背景・きっかけ / 提案内容 / 期待効果・放置した場合のリスク)。**`gh issue create` は web のテンプレートを通らないので `--label` を明示的に付ける** — improvement.yml → `improvement` / drift-report.yml → `freshness` / plugin-proposal.yml → `plugin-proposal`
- 確定した設計判断は docs/decisions/ に ADR として追記する

## 陳腐化防止の仕組み

| 層 | 実行 | 正本 |
|---|---|---|
| PR CI | validate + 整合性 + 非推奨パターン + version bump + スクリプトの判定テスト | [.github/workflows/ci.yml](.github/workflows/ci.yml) |
| 週次 | 上流参照の実在 + setup の意図の台帳との突き合わせ (フック・スキルが台帳に載っているか。ADR [0027](docs/decisions/0027-intents-ledger-cross-repo-coverage.md)) + リンク切れ → Issue 起票 | [.github/workflows/freshness.yml](.github/workflows/freshness.yml) |
| 週次 | GitHub Actions の更新 (patch/minor は CI green で自動マージ、major は `manual-review` ラベル) | [.github/workflows/dependabot-auto-merge.yml](.github/workflows/dependabot-auto-merge.yml) (ADR [0005](docs/decisions/0005-dependabot-auto-merge.md)) |
| 180 日ごと | 標準の項目が設置先で使われているかの再測定 (`scripts/measure-standards-usage.sh`。根拠の期限切れが PR CI を落とすので、再測定しないと次の PR が通らない) | 正本の `evidence` (ADR [0029](docs/decisions/0029-measure-what-the-standard-installs.md)) |

同種の問題・手戻りが 2 回起きたら、文書ルールの追記でなく仕組み (CI・hooks・スクリプト) への昇格を検討して Issue 起票する。
