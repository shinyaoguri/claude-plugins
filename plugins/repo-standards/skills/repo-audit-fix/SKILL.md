---
name: repo-audit-fix
description: "repo-audit が保存した findings をもとに、個人標準に適合していない項目を修正する。適用可否の承認は一覧で 1 回だけ取り、リポ内ファイルの修正は 1 PR にまとめる。GitHub 設定は定義ファイル経由、破壊的操作と設計意図に反する項目は提示のみ。適用後に再監査して before / after を示す。Use when fixing repository standard violations, applying repo-audit findings, or resuming an unfinished standards fix."
allowed-tools: "Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh:*), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-repo.sh:*), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-github.sh:*)"
---

repo-audit が保存した findings を入力に、承認された項目だけを適用する。findings があれば監査をやり直さずに再開できる。

同梱スクリプトは**下記のとおり `${CLAUDE_PLUGIN_ROOT}/scripts/...` を毎回そのまま書く**。`P=` のような変数に束ねるとコマンド文字列が frontmatter の allowed-tools と一致せず、1 コマンドごとに許可を聞かれる。

## 前提の確認

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh summary
```

- `findings が空` → 先に repo-audit スキルで監査する
- `manual N 件が未判定` → repo-audit の手順 2 (LLM 判定と書き戻し) を先に済ませる。未判定のまま進めると意味判定の項目が丸ごと落ちる
- `暫定判定 N 件` → repo-audit-min 由来の判定 (`verdict_source: min`)。畳んだ材料と安いモデルによる判定で、反証も衝突判定も通っていない。**必須違反 (NG) を直すだけなら続行してよい** (安い監査で見つけた違反をその場で直せるのが階層を分けた狙い)。判断が微妙な項目・生成的な fix・GitHub 設定の変更に踏み込むなら repo-audit で判定し直してから進む
- `反証待ち N 件` → repo-audit の手順 3 (反証) を先に済ませることを勧める。反証で覆るのは required と指摘の付いた項目、つまり**これから直そうとしている項目**なので、通さずに進むと誤判定のまま修正することになる。ユーザーが承知のうえで進めるなら続行してよい
- `衝突判定待ち N 件` → repo-audit の手順 4 (衝突判定) を先に済ませることを勧める。通さずに進むと、このリポでは意図的にそうしている項目まで標準に合わせて直すことになる
- worktree が dirty → 退避を促して中断する (適用は新しいブランチに載せるため)

## 承認の粒度

**チャットで承認を取るのは一覧に対して 1 回だけ**にする。目的は内容の精査ではなく、**適用する / 直さない (rejected) / 今回は見送る (deferred) の仕分け**を確定させること。内容の精査は PR レビューに一元化する — 適用結果は 1 PR に載り、squash merge 前にレビューでき、マージ後も revert できる。項目ごとに文面を承認させると、同じ内容を PR で二度見ることになるだけで、可逆な変更に確認の往復を増やしても安全性は上がらない。

例外は**適用せず提示だけする項目** (下表の「提示のみ」) で、これは承認の対象ではなく、実行するかどうかをユーザー自身が決める。

## 手順

1. 未決項目を取る: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh list --decision pending`

2. fix の性質で群に分ける。**群は適用の仕方 (コミット粒度・そもそも当てるか) を決めるもので、承認回数を分けるものではない**:

   | 群 | 対象 | 適用の仕方 |
   |---|---|---|
   | 1. 決定論的 | 内容が一意に決まるもの (設定ファイル・ワークフロー・テンプレートの配置) | まとめて適用し、コミットは type ごとに分ける |
   | 2. 生成的 | リポ固有の中身を書き起こすもの (README・CLAUDE.md・ADR・CONTRIBUTING) | 1 件 1 コミットで適用する (内容は PR の diff でレビューする) |
   | 3. 提示のみ | 削除・履歴の書き換え・ブランチ整理・追跡済み秘密ファイルの除去 | コマンドを提示するだけ。実行はユーザーに委ねる |

   項目に `fix_kind` があればそれに従い、無ければ fix の文面から上表で分類する。

   **worktree の掃除 (`claude-worktrees-clean`)** — 監査の detail が挙げた候補 (upstream が `[gone]` で未コミットの変更が無いもの) だけを `git worktree remove` の対象として提示する。候補に挙がらなかったものは自分で判断せず、次を添えてユーザーへ渡す:

   - **`ahead N` を未マージ作業の根拠にしない**。squash merge では元コミットが main の祖先にならないため、マージ済みでも ahead に出続ける。逆に取り込むと古い内容で main を上書きしうる。判断材料は `gh pr list --head <branch> --state all` のマージ済み PR か、対象ファイルの実体比較 (`git diff origin/main:<file> <branch>:<file>`)
   - submodule を含む worktree は `git worktree remove` が拒否し、`rm -rf` するしかない。**不可逆なので群 3 (提示のみ) から動かさない**

   **`intent` による群の上書き** — この標準は全リポ共通のルールで、個別のリポで最適とは限らない。監査が意図との衝突を記録している項目は群を落とす:

   | `intent` | 扱い |
   |---|---|
   | `conflicts` | **群 3 (提示のみ)** に落とす。`intent_note` の理由をそのまま添えて「標準はこう言うが、このリポはこう決めている」と提示し、適用するかはユーザーに委ねる。勝手に当てない |
   | `unclear` | 元の群のまま。ただし**一覧に `intent_note` を必ず併記する** — 判断材料を伏せたまま承認させない |
   | `aligned` / 未判定 | 元の群のまま |

   **機械判定を LLM 判定が覆した項目** (`status` が ng / warn なのに `verdict` が ok / skip) は fix を当てる対象ではない。機械判定が偽陽性だったという判定なので、`evidence` の根拠をそのまま `--note` に引いて `rejected` に落とし、一覧には「機械判定の偽陽性」として並べる。**`status` は覆らない**ため、記録しないまま放置すると次のセッションで同じ確認をやり直すことになる。判定に納得できなければ `rejected` にせず repo-audit で判定し直す

   `conflicts` の項目をユーザーが「やはり直さない」と決めたら `rejected` に、標準の側を見直すべきだと判断したら**その理由を setup リポ (`claude/repo-standards.json`) の Issue へ持っていく** — 個別リポの逸脱が積み重なるなら、直すべきは標準の方かもしれない

   GitHub 設定 (`layer: github`) の扱い:
   - `.github/repo-settings.json` があるリポでは**群 1 に含める** — gh コマンドで直接変えず、定義ファイルの変更として PR に載せ、マージ後にそのリポの手順で適用する (変更の根拠が diff に残る)
   - 定義ファイルが無いリポでのみ、各項目の `fix` の gh コマンドを全文提示し、承認後に実行する

3. 群ごとに番号付きで並べた**一覧を 1 回提示し、まとめて承認を取る**。生成的な項目は「何を書き起こすか」を 1 行で添える (全文は出さない — 読むのは PR の diff で足りる)。承認されなかった項目も findings に記録してから次へ進む (記録しないと次のセッションで同じ確認を繰り返す):

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh set --decision rejected --note "<理由>" <id>...   # 直さないと決めた
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh set --decision deferred --note "<理由>" <id>...   # 今回は見送り
   ```

4. 承認された項目を適用する。`chore/repo-standards` ブランチを切り、群 1・2 をまとめて **1 PR** にする (標準適合が 1 関心事なので、項目ごとに PR は作らない)。

   コミットは Conventional Commits で、**type が変わるものは分ける** (構成ファイルの追加は chore、CI の追加は ci、ドキュメントの生成は docs)。決定論的 fix をすべて 1 コミットに押し込むと、何をなぜ変えたのかが追えず revert もできなくなる。本文には適用した項目 id と、その項目がある理由 (`why`) を列挙して監査由来の変更だと分かるようにする:

   ```
   chore(repo-standards): 標準の構成ファイルを追加する

   - gitignore-exists: リポ種別の生成物に合わせた .gitignore を追加
     (全リポジトリで唯一共通の必須ファイル)
   - pr-template-exists: .github/pull_request_template.md を追加
     (目的・変更点・確認方法の記入漏れを防ぐ)
   ```

   適用したら記録する:

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh set --decision applied <id>...
   ```

   生成的 fix が多く 1 PR の粒度を超えるときは、関心ごとに PR を分けて残りを `deferred` にする

5. 再監査して before / after を表で提示する:

   ```bash
   { bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-repo.sh; bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-github.sh; } | bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh save
   ```

   直った項目は status が変わり decision が自動で消える。`applied_unresolved` が残っていたら適用が効いていないので、その項目の fix を見直す。GitHub 設定を定義ファイル経由で直した項目は PR マージ + 適用の後でないと解消しないので、その旨を添えて残す

6. `deferred` が残っていれば、対象リポの Issue 1 件にまとめるかユーザーに確認する。findings はマシンローカル (`.git` 配下) で他マシンへ伝搬せず、リポを clone し直せば消えるため、持ち越しは GitHub 側へ移す

7. PR を作る。**findings は揮発するので、この PR 本文が適用の記録の正本**になる。次を載せる:

   - 適用した項目の表 (id | level | 何をしたか | why)
   - 見送った項目 (`deferred` / `rejected`) と理由。`deferred` は手順 6 の Issue へリンクする
   - **意図と衝突するため適用しなかった項目** (`intent: conflicts`) と `intent_note`。標準からの逸脱を意識して選んだ記録になるので、リポの外に残す価値がここで一番高い
   - 再監査の before / after (`summary` の `_next` 行の集計)
   - GitHub 設定を定義ファイル経由で直した項目があれば、マージ後に適用操作が要る旨

## 詳細の在処

- findings の保存先・行スキーマ・decision の意味: `${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh` 冒頭のコメント
- 各項目の根拠 (`why`) と fix の正本: `~/.claude/repo-standards.json` (実体は shinyaoguri/setup の claude/repo-standards.json)

このスキル自体の不具合・使いにくさに気付いたら、report-issue スキルで shinyaoguri/claude-plugins へ気軽に起票する。
