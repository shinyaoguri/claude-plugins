---
name: repo-audit-min
description: "cwd のリポジトリを個人標準 (setup リポの repo-standards.json) と突き合わせる低コストな監査。機械判定を圧縮して報告し、LLM 判定は材料をスクリプトで集めてから安いモデル 1 本に一括で任せる。求められれば判定を暫定値として findings に残し修正フローへ渡す。Use for a cheap repository standards check, as a pre-flight before the full repo-audit, or when checking many repositories in a row."
allowed-tools: "Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-min.sh:*), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-evidence.sh:*), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh:*)"
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

   `BLOCK` 行 (前提未達で未判定の `level: required`) が出ていたら、**修正の順序として前提を先に案内する** — その項目は逸脱していないのではなく、まだ判定できていない。前提の id は行の detail に入っている

   例外は `repo-uninitialized` (コミットが 1 件も無いリポ)。この行が出たら機械判定はそれ 1 件で打ち切られている。監査ではなく雛形生成の段階なので、repo-audit ではなく **repo-bootstrap スキル**へ渡す

## その場で直したいと言われたら

本監査をやり直さず修正フローへ渡せる。**求められたときだけ**この経路に入る (既定は triage で止める):

1. 機械判定を findings へ保存する。**出力は手順 1 と同じなので提示しない** (同じ内容を二度読ませない):

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-min.sh --save
   ```

2. 手順 2 で得た判定を**暫定値として**書き戻す。`--source min` を必ず付ける — これが無いと安い層の判定が本監査の判定として記録される:

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh set --verdict <ok|warn|ng|skip> --evidence "<返ってきた根拠>" --source min <id>
   ```

   本監査の判定が既にある項目はスクリプトが書き込みを拒み、その旨を stderr に返す (暫定値で本監査の結論を置き換えない)。拒まれた項目はそのまま先へ進んでよい

3. repo-audit-fix スキルへ渡す。**判定が暫定値であることを伝える** — 反証も衝突判定も通っていないので、必須違反 (NG) の修正までに留め、判断が微妙な項目は repo-audit で見直すよう促す

## このスキルの割り切り

- **LLM 判定は安いモデルの一括判定**。材料は `rs-evidence.sh` が決定論的に集めた範囲に限られ、判定係が開けるファイルも 3 件までに制限してある。**深い乖離検知 (ADR の決定内容と実装のずれなど) は本監査に劣る** — 疑わしい項目が出たら repo-audit で見直す
- **既定では findings を保存しない**。保存するのは `--save` を明示したときだけで、書き戻す判定も `--source min` の暫定値として記録される。本監査の判定を上書きすることはなく、次に repo-audit を回せば必ず判定し直される
- **反証・衝突判定をしない**。この 2 つは本監査の作法で、暫定判定は反証待ちにも数えない
- **修正の提案・適用をしない**。逸脱の指摘までで止める (修正は repo-audit-fix の担当)

これらが要るなら repo-audit スキル (本監査) を使う。判定項目そのものの正本は `~/.claude/repo-standards.json` で、項目の追加・変更はプラグインでなく setup リポへの PR で行う。判定の出自と上書き規則は [ADR 0015](https://github.com/shinyaoguri/claude-plugins/blob/main/docs/decisions/0015-verdict-provenance.md)。

このスキル自体の不具合・使いにくさに気付いたら、report-issue スキルで shinyaoguri/claude-plugins へ気軽に起票する。
