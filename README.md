# claude-plugins

個人用の Claude Code plugin marketplace。複数の PC 環境で同じスキル・コマンド・エージェントを使えるようにするためのリポジトリ。

## プラグイン一覧

| プラグイン | 対象 | 内容 |
|---|---|---|
| [metaphor-sketch](plugins/metaphor-sketch) | [metaphor](https://github.com/shinyaoguri/metaphor) でスケッチを書く人 | 観測ループ (observe→edit→verify) と watch→AI クライアントの起動順序の作法、`/metaphor-new` `/metaphor-doctor` (skill 4)、watch セッション検査 (SessionStart hook 1) |
| [metaphor-contrib](plugins/metaphor-contrib) | [metaphor](https://github.com/shinyaoguri/metaphor) / [metaphor-cli](https://github.com/shinyaoguri/metaphor-cli) のコントリビュータ | クロスリポ契約・生成物の鮮度・リリース規約・CLI 拡張手順、`/contract-check` `/quick-issue` (skill 6) |
| [repo-standards](plugins/repo-standards) | 自分の全リポジトリと各マシン | 個人標準 ([setup](https://github.com/shinyaoguri/setup) の repo-standards.json が正本) との突き合わせ監査・修正・雛形生成と、Issue・PR に貼るスクリーンショットの Gyazo ホスト手順、プラグイン利用中の問題の起票手順、`/repo-audit` `/env-doctor` `/repo-bootstrap` `/gyazo-capture` `/report-issue` (skill 5) |

いずれも対象リポジトリの正典ドキュメント (CLAUDE.md / AGENTS.md / DEVELOPMENT.md / CONTRACT.md) を複製せず、「いつ・何を読むか」を想起させる薄いルーターとして設計している (ドリフト防止)。

## 使い方

### marketplace の登録

Claude Code のインタラクティブセッションで:

```
/plugin marketplace add shinyaoguri/claude-plugins
```

または `~/.claude/settings.json` で宣言する (セットアップの自動化向け):

```json
{
  "extraKnownMarketplaces": {
    "shinyaoguri": {
      "source": {
        "source": "github",
        "repo": "shinyaoguri/claude-plugins"
      }
    }
  }
}
```

### プラグインのインストール

```
/plugin install <plugin-name>@shinyaoguri
```

settings.json で宣言する場合:

```json
{
  "enabledPlugins": {
    "<plugin-name>@shinyaoguri": true
  }
}
```

## リポジトリ構成

```
claude-plugins/
├── .claude-plugin/
│   └── marketplace.json     # marketplace 定義 (プラグイン一覧)
├── plugins/                 # プラグイン本体 (1 プラグイン = 1 ディレクトリ)
│   └── <plugin-name>/
│       ├── .claude-plugin/
│       │   └── plugin.json  # プラグインのメタデータ
│       ├── skills/          # スキル (各ディレクトリに SKILL.md。スラッシュコマンドもここ)
│       ├── agents/          # サブエージェント定義 (*.md)
│       └── hooks/           # hooks 設定
├── .claude/skills/          # このリポの開発専用スキル (配布しない)
├── .github/                 # CI (ci.yml / freshness.yml)・テンプレート・Dependabot
├── scripts/                 # 整合性・上流参照チェック (CI とローカル共用)
├── docs/decisions/          # 設計判断の記録 (軽量 ADR)
├── upstream-refs.json       # プラグインが参照する上流パスのマニフェスト
├── CLAUDE.md                # 開発規約 (Claude Code 向け)
└── README.md
```

## プラグインの追加手順

1. `plugins/<plugin-name>/` を作成し、`.claude-plugin/plugin.json` を置く

   ```json
   {
     "name": "<plugin-name>",
     "description": "プラグインの説明",
     "version": "0.1.0"
   }
   ```

2. `skills/<skill-name>/SKILL.md` など必要なコンテンツを追加する。スラッシュコマンドも skills として作る (`commands/` は公式非推奨。他の非推奨構成は [ADR 0004](docs/decisions/0004-deprecation-guard.md) 参照、CI が検査)
3. `.claude-plugin/marketplace.json` の `plugins` 配列にエントリを追加する

   ```json
   {
     "name": "<plugin-name>",
     "source": "./plugins/<plugin-name>",
     "description": "プラグインの説明"
   }
   ```

4. main へマージすると、各環境では `/plugin marketplace update shinyaoguri` (または自動更新) で反映される。**反映されるのは plugin.json の version が bump されたときだけ** (バージョン規約は [CLAUDE.md](CLAUDE.md) 参照)

## 運用 (陳腐化防止)

プラグインは上流ドキュメントへの薄いルーターのため、上流の変化への追従が保守の中心。仕組みの設計は [docs/decisions/0002](docs/decisions/0002-freshness-architecture.md)、開発時の規約は [CLAUDE.md](CLAUDE.md) を参照。

| 層 | 実行 | 内容 |
|---|---|---|
| PR CI | 自動 ([ci.yml](.github/workflows/ci.yml)) | validate・整合性・公式非推奨パターン・version bump・マニフェスト網羅 |
| 週次 | 自動 ([freshness.yml](.github/workflows/freshness.yml)) | 上流参照の実在・リンク切れ → label:freshness の Issue へ起票 |
| 月次 | ローカル scheduled task | [portfolio-review](.claude/skills/portfolio-review/SKILL.md) スキルで利用状況・意味的ドリフト・仕組み自体を俯瞰レビュー |

月次レビューの scheduled task は各マシンで一度だけ登録する。Claude Code に次を依頼すればよい:

> claude-plugins リポジトリで /portfolio-review を実行する月次のスケジュールタスクを登録して

検知・提案はすべて GitHub Issue に集約される (テンプレート: 改善提案 / ドリフト報告 / プラグイン新設・統廃合の提案)。
