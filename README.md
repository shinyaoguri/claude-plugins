# claude-plugins

個人用の Claude Code plugin marketplace。複数の PC 環境で同じスキル・コマンド・エージェントを使えるようにするためのリポジトリ。

## プラグイン一覧

| プラグイン | 対象 | 内容 |
|---|---|---|
| [metaphor-sketch](plugins/metaphor-sketch) | [metaphor](https://github.com/shinyaoguri/metaphor) でスケッチを書く人 | 観測ループ (observe→edit→verify) と watch→AI クライアントの起動順序の作法、`/metaphor-new` `/metaphor-doctor` (skill 4)、watch セッション検査 (SessionStart hook 1) |
| [metaphor-contrib](plugins/metaphor-contrib) | [metaphor](https://github.com/shinyaoguri/metaphor) / [metaphor-cli](https://github.com/shinyaoguri/metaphor-cli) のコントリビュータ | クロスリポ契約・生成物の鮮度・リリース規約・CLI 拡張手順、`/contract-check` `/quick-issue` (skill 6) |
| [repo-standards](plugins/repo-standards) | 自分の全リポジトリと各マシン | 個人の開発運用標準 ([setup](https://github.com/shinyaoguri/setup) の repo-standards.json が正本) — リポジトリ構成・GitHub 設定・マシン環境の監査と雛形生成、作業の記録 (Issue・PR へのスクショ添付・気付きの起票) の作法、`/repo-audit` `/repo-audit-min` `/repo-audit-fix` `/env-doctor` `/repo-bootstrap` `/gyazo-capture` `/report-issue` (skill 7) |

いずれも対象リポジトリの正典ドキュメント (CLAUDE.md / AGENTS.md / DEVELOPMENT.md / CONTRACT.md) を複製せず、「いつ・何を読むか」を想起させる薄いルーターとして設計している (ドリフト防止)。

### リポジトリ監査スキルの使い分けとトークン目安

個人標準 (repo-standards.json、49 項目 = 機械判定 43 + LLM 判定 6) との突き合わせは 3 スキルに分かれている。**消費トークンが 2 桁違う**ので用途で選ぶ。

| スキル | 何をするか | コスト目安 |
|---|---|---|
| `/repo-audit-min` | 機械判定 43 項目を圧縮して報告し、LLM 判定 6 項目は材料をスクリプトで集めてから **Haiku 1 本**に一括で任せる。findings 保存・修正提案はしない | メイン **1K 弱** + 判定係 **1 本**。概算 **$0.05 前後** |
| `/repo-audit` | 同じ 49 項目を、LLM 判定は項目ごとの並列サブエージェントが**材料 + 実ファイル**を読んで判定し、必須項目と指摘は**独立した反証係**が覆せるか確かめてから確定する。結果を findings に保存して修正フローへ渡す | メイン **+10K 前後**、サブエージェント込みの累積 **400〜900K**。概算 **$1.5〜3** |
| `/repo-audit-fix` | findings の未決項目を承認を取りながら修正する (リポ内ファイルは 1 PR にまとめ、GitHub 設定は定義ファイル経由、破壊的操作は提示のみ) | 修正件数しだい。`/repo-audit` と同等かそれ以上 |

`/repo-audit-min` が 1 桁以上安いのは、**LLM を外したからではなく LLM の使い方を変えたから**。効いているのは 3 点:

1. **材料を先に畳む** — `rs-evidence.sh` が ADR の状態行・`git log`・open Issue・設定ファイルの構造を決定論的に集めて渡す。判定材料は 12K → 約 4.8K トークンに縮み、判定係は探索のためのツール呼び出しをほぼしない
2. **サブエージェントを 1 本に束ねる** — 1 本ごとに固定の初期コンテキスト (system prompt + ツール定義) を払うので、6 本に割るとその分が丸ごと 6 重になる
3. **[Haiku 4.5](https://platform.claude.com/docs/en/about-claude/models/overview) を使う** — $1/$5 per MTok で、Opus 5 ($5/$25) の 5 分の 1

代わりに落としているのは**判定の深さ**で、判定係が開けるファイルは 3 件までに制限してある。ADR の決定内容と実装の乖離のような、全文を突き合わせないと分からない項目は `/repo-audit` に劣る。

逆に `/repo-audit` は精度に振ってある ([ADR 0012](docs/decisions/0012-audit-precision.md))。同じ材料を**下限**として渡したうえで実ファイルを読ませ、必須項目と指摘には別コンテキストの反証係を通す。判定には根拠を必須にし (`rs-findings.sh` が 20 バイト未満を拒否する)、反証の状態を findings に持たせてあるのでセッションが尽きても続きから再開できる。累積が大きいのは ADR 全文・CLAUDE.md・`.claude/` 配下を項目ごとに読み、さらに反証で読み直すため。ただし findings は前回の判定を id 単位で引き継ぐので、**2 回目以降は status が変わった項目だけの再判定と反証で済む**。

日常の点検と多数のリポを続けて見るときは `/repo-audit-min`、新規リポの受け入れや腰を据えた棚卸しのときだけ `/repo-audit` — という使い分けを想定している。

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
