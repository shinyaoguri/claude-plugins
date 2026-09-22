---
name: repo-audit-min
description: "cwd のリポジトリを個人標準 (repo-standards.json) と突き合わせる低コストな監査。機械判定を圧縮して報告し、LLM 判定は材料をスクリプトで集めてから安いモデル 1 本に一括で任せる。報告専用で、findings には保存しない。Use for a cheap repository standards check, as a pre-flight before the full repo-audit, or when checking many repositories in a row."
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

   この出力を **standards-judge サブエージェント 1 本**にそのまま渡す (Agent ツール、`subagent_type: "repo-standards:standards-judge"`)。**項目ごとに分けず 1 本にまとめる** — サブエージェントは 1 本ごとに固定の初期コンテキストを払うので、項目ごと (8 本) に割るとその分だけ丸ごと重複する。プロンプトは材料の全文だけでよく、判定基準と使うモデルはエージェント側が持っている

3. 2 つの出力を続けて提示する。**機械判定の出力はそのまま貼る (要約・再構成・表への整形をしない)**。LLM 判定はエージェントが返した `<id>\t<verdict>\t<根拠>` を 1 行ずつ `<verdict> <id>  <根拠>` の形に直して並べ、末尾に判定込みの件数を 1 行足す

4. 次の一手を 1 行だけ添える。NG / WARN があれば本監査 (repo-audit) を案内する。ユーザーがその場で求めたときだけ repo-audit へ進む

   `BLOCK` 行 (前提未達で未判定の `level: required`) が出ていたら、**修正の順序として前提を先に案内する** — その項目は逸脱していないのではなく、まだ判定できていない。前提の id は行の detail に入っている

   例外は `repo-uninitialized` (コミットが 1 件も無いリポ)。この行が出たら機械判定はそれ 1 件で打ち切られている。監査ではなく雛形生成の段階なので、repo-audit ではなく **repo-bootstrap スキル**へ渡す

## その場で直したいと言われたら

このスキルの判定は findings に残らないので、ここから直接は修正フローへ渡せない。**repo-audit (本監査) を通してから repo-audit-fix へ**進む。安い層の判定をそのまま修正へ運ぶ近道は、findings の全行に出自を持たせる代償に見合わなかったので畳んだ ([ADR 0030](https://github.com/shinyaoguri/claude-plugins/blob/main/docs/decisions/0030-simplify-the-audit.md))。

## このスキルの割り切り

- **LLM 判定は安いモデルの一括判定**。材料は `rs-evidence.sh` が決定論的に集めた範囲に限られ、判定係が開けるファイルも 3 件までに制限してある。**深い乖離検知 (ADR の決定内容と実装のずれなど) は本監査に劣る** — 疑わしい項目が出たら repo-audit で見直す
- **findings を保存しない**。判定は報告して終わりで、次に repo-audit を回せば一から判定される
- **反証・衝突判定をしない**。この 2 つは本監査の作法
- **修正の提案・適用をしない**。逸脱の指摘までで止める (修正は repo-audit-fix の担当)

**定期的に見直すだけなら `--cadence drift`** を付けると、作業そのものが状態を崩していく 12 項目 (ブランチの取り残し・ADR の遅れ・allow の溜まり等) に絞れる。既定は全件で、リポジトリを初めて見るときの設置漏れを隠さない ([ADR 0025](https://github.com/shinyaoguri/claude-plugins/blob/main/docs/decisions/0025-cadence-bootstrap-vs-drift.md))。

これらが要るなら repo-audit スキル (本監査) を使う。判定項目そのものの正本は `${CLAUDE_PLUGIN_ROOT}/repo-standards.json` で、項目の追加・変更はこのリポジトリへの PR で行う (ADR 0022)。

このスキル自体の不具合・使いにくさに気付いたら、report-issue スキルで shinyaoguri/claude-plugins へ気軽に起票する。
