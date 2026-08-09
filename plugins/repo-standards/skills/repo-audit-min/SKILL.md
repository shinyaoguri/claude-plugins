---
name: repo-audit-min
description: "cwd のリポジトリを個人標準 (setup リポの repo-standards.json) と突き合わせる低コストな監査。機械判定を圧縮して報告し、LLM 判定は材料をスクリプトで集めてから安いモデル 1 本に一括で任せる (findings 保存と修正には入らない)。Use for a cheap repository standards check, as a pre-flight before the full repo-audit, or when checking many repositories in a row."
allowed-tools: "Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-min.sh:*), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-evidence.sh:*)"
---

cwd が git リポジトリでなければ「git リポジトリ内で実行してください」と伝えて終了する。

同梱スクリプトは**下記のとおり `${CLAUDE_PLUGIN_ROOT}/scripts/...` を毎回そのまま書く**。変数に束ねるとコマンド文字列が frontmatter の allowed-tools と一致せず、実行のたびに許可を聞かれる。

## 手順

1. 機械判定を実行する (常に exit 0):

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-min.sh
   ```

   オフライン・gh 未認証などで GitHub 設定の層を省くなら `--no-github` を付ける

2. 集計行の `manual=` が 1 以上なら LLM 判定へ進む。材料はスクリプトが集めるので**自分では読まない**:

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-evidence.sh
   ```

   この出力を **standards-judge サブエージェント 1 本**にそのまま渡す (Agent ツール、`subagent_type: "repo-standards:standards-judge"`)。**項目ごとに分けず 1 本にまとめる** — サブエージェントは 1 本ごとに固定の初期コンテキストを払うので、6 本に割るとその分だけ丸ごと重複する。プロンプトは材料の全文だけでよく、判定基準と使うモデルはエージェント側が持っている

3. 2 つの出力を続けて提示する。**機械判定の出力はそのまま貼る (要約・再構成・表への整形をしない)**。LLM 判定はエージェントが返した `<id>\t<verdict>\t<根拠>` を 1 行ずつ `<verdict> <id>  <根拠>` の形に直して並べ、末尾に判定込みの件数を 1 行足す

4. 次の一手を 1 行だけ添える。NG / WARN があれば本監査 (repo-audit) を案内する。ユーザーがその場で求めたときだけ repo-audit へ進む

## このスキルの割り切り

- **LLM 判定は安いモデルの一括判定**。材料は `rs-evidence.sh` が決定論的に集めた範囲に限られ、判定係が開けるファイルも 3 件までに制限してある。**深い乖離検知 (ADR の決定内容と実装のずれなど) は本監査に劣る** — 疑わしい項目が出たら repo-audit で見直す
- **findings を保存しない**。安いモデルの判定で、前回 repo-audit が付けた verdict と decision を上書きしないため。したがって repo-audit-fix へは引き渡せない
- **修正の提案・適用をしない**。逸脱の指摘までで止める

これらが要るなら repo-audit スキル (本監査) を使う。判定項目そのものの正本は `~/.claude/repo-standards.json` で、項目の追加・変更はプラグインでなく setup リポへの PR で行う。

このスキル自体の不具合・使いにくさに気付いたら、report-issue スキルで shinyaoguri/claude-plugins へ気軽に起票する。
