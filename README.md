# claude-plugins

個人用の Claude Code plugin marketplace。複数の PC 環境で同じスキル・コマンド・エージェントを使えるようにするためのリポジトリ。

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
│       ├── skills/          # スキル (各ディレクトリに SKILL.md)
│       ├── commands/        # スラッシュコマンド (*.md)
│       ├── agents/          # サブエージェント定義 (*.md)
│       └── hooks/           # hooks 設定
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

2. `skills/` や `commands/` など必要なコンテンツを追加する
3. `.claude-plugin/marketplace.json` の `plugins` 配列にエントリを追加する

   ```json
   {
     "name": "<plugin-name>",
     "source": "./plugins/<plugin-name>",
     "description": "プラグインの説明"
   }
   ```

4. main へマージすると、各環境では `/plugin marketplace update shinyaoguri` (または自動更新) で反映される
