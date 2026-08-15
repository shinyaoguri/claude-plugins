---
name: next-task
description: "並行して走っている他セッションと重ならない次のタスクを選んで着手する (in-flight の worktree・open PR・着手印の付いた Issue を集めて除外し、選んだ Issue に着手印を付けて worktree を切る)。Use when the user asks to start the next task, pick another issue, or switch to independent work — especially 次のタスクに着手して / 別の作業を始めて / 独立した作業を探して while other Claude sessions may be running on the same repository."
argument-hint: "[方向性やリポジトリの指定 (任意)]"
allowed-tools: "Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-inflight.sh:*), Bash(gh issue list:*), Bash(gh issue view:*), Bash(gh pr list:*), Bash(gh pr view:*), Bash(gh label list:*), Bash(git worktree list:*)"
---

同じリポジトリで複数のセッションが並行するので、**次のタスクは「空いている作業」から選ぶ**。着手印の規約 (`status: in progress` を付ける・外す) の正本は `~/.setup/claude/CLAUDE.md` の「ソフトウェア開発」節で、ここはその実行手順。ユーザーの指定: `$ARGUMENTS`

## 手順

1. in-flight を集める。**コマンドは下記のとおり `${CLAUDE_PLUGIN_ROOT}/scripts/...` をそのまま書く** (変数に束ねると frontmatter の allowed-tools と一致せず許可を聞かれる):

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-inflight.sh
   ```

   JSON Lines が返る (スキーマはスクリプト冒頭)。`self: true` は自分自身の worktree・セッションなので除外対象に数えない。

2. `_meta` を先に読み、**取れなかった源をユーザーに伝えてから進む**。黙って進めると「重ならないことを確認した」と誤解される:

   | 状態 | 意味 | 進め方 |
   |---|---|---|
   | `sources.gh: false` | gh 不在・未認証・GitHub 外リポ | Issue 候補も PR 除外も引けない。worktree とセッションだけで判断し、その旨を伝える |
   | `sources.sessions: false` | セッション置き場が無い (別マシン・将来の版) | worktree と PR だけで判断する。best-effort なのでここは止まらない |
   | `label_exists: false` | 着手印ラベルが未作成 | 手順 5 で作る。**「着手中の Issue が無い」ではない** |

3. 候補を集める。`gh issue list --state open --json number,title,labels,url --limit 50` を引き、次を落とす:

   - `kind: "issue"` で返ってきたもの (着手印が付いている = 他セッションが持っている)
   - in-flight PR (`kind: "pr"`) がタイトル・本文で参照している Issue 番号

4. 残りから**重ならないもの**を選ぶ。次に当たる候補は理由を添えて落とす:

   - **触るファイルが重なる** — `kind: "pr"` の `files` と、その Issue を直すなら触るであろうファイルが交差する。生成物 (llms.txt・索引・スナップショット類) は特に衝突しやすいので、片方でも触るなら避ける
   - **直列の依存がある** — 同じ Epic・親 Issue の鎖にあり、先行 PR がまだマージされていない
   - **同じ領域で他セッションが動いている** — `kind: "session"` に同じ `project` の行があり、その `branch` / `title` が同じ領域を指している
   - **in-flight PR がすでに 3 本ある** — 合流点が渋滞する。着手せず本数を伝えて、どれかのマージを待つかユーザーに判断を返す。**この分岐だけがこのスキルで唯一、着手前にターンを終えてよい離脱点**で、ここに当たらなければ手順 5・6 は続けて実行する

5. 選定結果を提示する。**選んだ 1 本の理由と、落とした候補それぞれの理由を 1 行ずつ**。そのうえで着手印を付ける (ラベルが無ければ先に作る):

   ```bash
   gh label create "status: in progress" --color 0052CC --description "着手中 (並行セッションの重複着手を防ぐ排他印)"
   gh issue edit <番号> --add-label "status: in progress"
   ```

   **この提示はユーザーに判断を返す点ではない**。選定の根拠を残すための途中経過なので、返答を待たずに手順 6 へ進む。

6. worktree を切って着手する (メインツリーで作業しない。並行セッションが同じファイルを取り合う)。**手順 5 と同じターンで続ける** — 着手印を付けたまま止まると、他セッションからは「着手済みだが誰も進めていない」状態に見えて候補が無駄に減る。

   着手の入り方は選んだ Issue の性質で決まる:

   - **非自明なら** (複数ファイルに及ぶ・設計の選択肢がある・要件が曖昧) worktree を切ったうえで `EnterPlanMode` に入り、プランを提示する。**ユーザーに返すのはこのプラン承認の 1 点**
   - **自明なら** そのまま実装に入る。プランの合意なしに編集が広がると `plan-gate` フックが差し戻すので、途中で非自明だと分かった時点でプランへ切り替える

7. **着手印を外すところまでがこのスキルの範囲**。PR がマージされたとき、あるいは着手をやめたときに外す:

   ```bash
   gh issue edit <番号> --remove-label "status: in progress"
   ```

## 落とし穴

- **外し忘れると候補が枯れる**。手順 3 で「着手印は付いているが、対応する open PR も worktree も稼働セッションも無い」Issue を見つけたら、外し忘れの可能性としてユーザーに報告する (勝手に外さない — 中断中の作業かもしれない)
- **ラベルはリポジトリごと**。初めてそのリポで使うときは手順 5 の `gh label create` が要る。3 リポ以上で同じことを繰り返すようなら、個人標準 (`repo-standards.json`) の項目へ昇格させる Issue を report-issue スキルで起票する
- `rs-inflight.sh` は収集専用で判定をしない。**除外の判断はこのスキル側の仕事**で、根拠 (どの PR のどのファイルと重なったか) を必ず言葉にする
