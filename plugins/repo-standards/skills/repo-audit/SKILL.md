---
name: repo-audit
description: "cwd のリポジトリを個人標準 (setup リポの repo-standards.json) と突き合わせて精度優先で監査する。GitHub 設定・リポ構成ファイル・.claude 設定の 3 層を機械判定 + LLM 判定でレポートし、必須項目と指摘は独立した判定者の反証を通し、さらに標準に合わせることがリポ自身の設計意図と衝突しないかを判定してから findings に保存して修正シーケンス (repo-audit-fix) へ引き渡す。Use when auditing a repository against personal standards, checking GitHub repo settings, or reviewing repository structure and Claude configuration."
allowed-tools: "Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-repo.sh:*), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-github.sh:*), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh:*), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-evidence.sh:*)"
---

cwd が git リポジトリでなければ「git リポジトリ内で実行してください」と伝えて終了する。

精度優先の本監査で、LLM 判定に加えて反証パスを通すぶんトークンを相応に使う。ユーザーが「ざっと」「軽く」だけを求めているなら repo-audit-min スキル (安い一括判定) の方が適切。

同梱スクリプトは**下記のとおり `${CLAUDE_PLUGIN_ROOT}/scripts/...` を毎回そのまま書く**。`P=` のような変数に束ねるとコマンド文字列が frontmatter の allowed-tools と一致せず、1 コマンドごとに許可を聞かれる。

## 手順

1. 機械判定を実行し、結果を findings へ保存する (どのスクリプトも常に exit 0):

   ```bash
   { bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-repo.sh; bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-github.sh; } | bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh save
   ```

   監査結果の JSON Lines がそのまま流れ、末尾に集計と次アクションの `_next` 行が付く。前回の判定・承認は id 単位で引き継がれる (status が変わった項目だけ未決に戻る)。

   **`layer: meta` の項目が出たらここで打ち切る** — 判定を続ける前提が欠けている:

   | id | 次にやること |
   |---|---|
   | `standards-manifest-missing` | fix の内容 (setup リポのセットアップ) を案内する |
   | `repo-uninitialized` | **repo-bootstrap スキルへ渡す**。コミットが 1 件も無いリポは監査でなく雛形生成の段階で、スクリプトも他の項目を並べずこの 1 件だけを返す。手順 2 以降を回しても、判定対象のファイルが存在しないので LLM 判定・反証・衝突判定が全件空振りする |

2. **判定** — 対象は `bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh list --needs-verdict` (未判定のもの、判定後に HEAD が進んで陳腐化したもの、および repo-audit-min が付けた暫定判定 (`verdict_source: min`))。**暫定判定は根拠が残っていても必ず判定し直す** — 安い層は畳んだ材料とファイル 3 件までで判定しており、本監査の結論として残してよい深さではない。項目ごとに**並列で standards-auditor サブエージェントへ委譲**する (`subagent_type: "repo-standards:standards-auditor"`)。渡すのは判定観点 (detail) と `bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-evidence.sh <id>` の出力。**材料は下限で、実ファイルを読ませる**のが本監査の要点 (材料だけで済ませるのは repo-audit-min の作法)

   返ってきた `VERDICT` / `EVIDENCE` を書き戻す。根拠は 20 バイト以上が必須で、満たさなければスクリプトが拒否する:

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh set --verdict <ok|warn|ng|skip> --evidence "<返ってきた EVIDENCE>" <id>
   ```

3. **反証** — 対象は `bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh list --needs-verify` (required 項目と、ng / warn と判定した項目)。項目ごとに**並列で standards-verifier サブエージェントへ委譲**する (`subagent_type: "repo-standards:standards-verifier"`)。渡すのは判定観点・材料・**元の verdict と根拠**。判定係とは別のコンテキストで走らせること — 同じエージェントに確認させても自分の結論を追認するだけになる

   | 返り値 | 書き戻し |
   |---|---|
   | `RESULT: upheld` | `set --verified --evidence "<反証の EVIDENCE>" <id>` |
   | `RESULT: overturned` | `set --verdict <新しい VERDICT> --evidence "<反証の EVIDENCE>" <id>` |

   overturned で書き戻すと `verified` が落ちるので、その項目は再び反証待ちに戻る。**同じ項目が 2 回覆ったら 3 回目を回さず**、両方の判定と根拠を併記してユーザーに判断を仰ぐ (判定が振動しているのは観点かリポの状態が曖昧なサインで、回し続けても収束しない)

4. **衝突判定** — 対象は `bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh list --needs-intent-check` (標準から外れている項目のうち、まだ意図と突き合わせていないもの)。**機械判定の ng / warn もここに含まれる** — この標準は全リポ共通のルールであって個別のリポで最適とは限らず、機械判定に文脈が入る接点はここしかない

   材料は `bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-evidence.sh --intent` を**1 回だけ**実行する。これを**standards-intent-judge サブエージェント 1 本**に、対象項目 (id / level / detail / fix) の一覧とあわせてまとめて渡す (`subagent_type: "repo-standards:standards-intent-judge"`)。**項目ごとに分けない** — 材料が全項目共通で、判定も「明示的な記述と食い違うか」の照合なので、分けても精度は上がらず固定コンテキストだけが件数分重複する (判定 (手順 2) と反証 (手順 3) を項目ごとに分けるのは、あちらが項目ごとに違う深さまで実ファイルを読む必要があるため)

   返ってきた `<id>\t<intent>\t<REASON>` を 1 行ずつ書き戻す:

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh set --intent <aligned|unclear|conflicts> --intent-note "<返ってきた REASON>" <id>
   ```

   **intent は verdict を上書きしない。** 標準から外れているという事実と、それがこのリポでは正しい逸脱かもしれないという文脈は別物で、後者で前者を消すと「外れていること」自体が見えなくなる

5. レポートを提示する: `_meta` 行 (kind / repo / visibility) をヘッダに、層ごとの表 (項目 | 判定 | 意図 | 詳細)。LLM 判定の行には根拠を添え、**反証で覆った項目は覆る前後を併記する** (どこで判断が変わったかが監査の価値になる)。

   **`status: blocked` (前提未達で保留) の項目は別枠で必ず載せる** — 前提の id ごと (`detail` に入っている) 並べ、**`level: required` は 1 件も省かない**。恒久的に対象外の `skip` と違い、前提が埋まれば判定対象に戻る項目で、ここで落とすと required の取りこぼしが誰にも見えないまま残る (issue #97 の実害)。直す対象はこの項目ではなく前提側の項目なので、承認・適用の一覧には入れない

   **機械判定を LLM 判定が覆した項目** (`summary` の `overridden`。機械が ng / warn、LLM が ok / skip) も同じ扱いで、機械の status と LLM の verdict を並べ、偽陽性と判断した根拠を載せる。機械判定の status は覆らない (事実として集計に残る) ので、レポートで根拠が読めないと「直っていないのに放置されている項目」に見える。この種の項目は `decision` を `rejected` にし、`--note` に理由を残して未決から外す`intent` が `conflicts` / `unclear` の項目は**理由をそのまま載せる** — 「標準には合っていないが、このリポではこう決めている」が読み取れる形にする。末尾に `bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh summary` の集計 (必須 NG / 推奨 WARN / 意図と衝突 / 未決 / 反証待ち / skip)

6. 未決 (pending) が残っていれば repo-audit-fix スキルへ進み、修正シーケンスに入る。ユーザーが監査だけを求めているときを除き、報告で終わらせない

## 途中で止まっても再開できる

手順 2〜4 の状態はすべて findings に載る。セッションが尽きたら、次回は `summary` の `manual_unjudged` / `unverified` / `intent_unchecked` を見て続きから入る — `--needs-verdict` は未判定と陳腐化した判定を、`--needs-verify` は判定済みで反証を通っていないものを、`--needs-intent-check` は標準から外れていて意図と突き合わせていないものを返す。判定を書き換えると `verified` が落ちるので、覆した項目を反証済みと取り違えることはない。

衝突判定は HEAD では陳腐化させない (設計意図はコミットごとに変わるものではなく、毎回無効化するとコストが跳ねるだけ)。項目が標準に適合すれば `intent` は自動で落ちる。設計意図そのものが変わったときだけ、ユーザーの指示で付け直す。

## 詳細の在処

- チェックリストの正本: `~/.claude/repo-standards.json` (実体は shinyaoguri/setup の claude/repo-standards.json。項目の追加・変更はプラグインでなく setup リポへの PR で行う)
- 必須項目と根拠だけ見る: `jq -r '.items[] | select(.level=="required") | [.id, .why] | @tsv' ~/.claude/repo-standards.json`
- 監査出力のスキーマと status の意味: `${CLAUDE_PLUGIN_ROOT}/scripts/rs-lib.sh` 冒頭のコメント
- findings の行スキーマ・判定を記録するときの制約・decision の意味: `${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh` 冒頭のコメント

このスキル自体の不具合・使いにくさに気付いたら、report-issue スキルで shinyaoguri/claude-plugins へ気軽に起票する。
