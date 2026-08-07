---
name: repo-audit-min
description: "トークンをほとんど使わずに cwd のリポジトリを個人標準 (setup リポの repo-standards.json) と突き合わせる簡易監査。機械判定だけを走らせ、逸脱した項目を 1 行ずつ圧縮して報告する (LLM 判定・findings 保存・修正には入らない)。Use for a cheap quick check of repository standards, as a pre-flight before the full repo-audit, or when checking many repositories in a row."
---

cwd が git リポジトリでなければ「git リポジトリ内で実行してください」と伝えて終了する。

## 手順

1. 次を実行する (常に exit 0):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-min.sh"
   ```

   オフライン・gh 未認証などで GitHub 設定の層を省くなら `--no-github` を付ける

2. **出力をそのまま提示する。要約・再構成・表への整形をしない**。既に最小の報告書式になっており、書き直しても情報は増えずトークンだけ増える

3. 次の一手を 1 行だけ添える。NG / WARN があれば本監査 (repo-audit) を案内する。ユーザーがその場で求めたときだけ repo-audit へ進む

## このスキルがやらないこと (トークンを使わないための割り切り)

- **LLM 判定** (`status: "manual"` の項目) — 件数を数えるだけで中身は見ない。サブエージェントも立てない
- **findings への保存** — 判定していない manual 項目で前回の verdict / decision を上書きしないため、あえて保存しない。したがって repo-audit-fix へは引き渡せない
- **修正の提案・適用** — 逸脱の指摘までで止める

これらが要るなら repo-audit スキル (本監査) を使う。判定項目そのものの正本は `~/.claude/repo-standards.json` で、項目の追加・変更はプラグインでなく setup リポへの PR で行う。

このスキル自体の不具合・使いにくさに気付いたら、report-issue スキルで shinyaoguri/claude-plugins へ気軽に起票する。
