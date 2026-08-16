# 0018: ブランチの自動削除は「情報が失われないと機械的に証明できる範囲」に限る

- **状態**: 採用 (2026-08-14)

- **文脈**: 役目を終えたローカルブランチの掃除には 2 系統のシグナルがあり、自動実行の口が片方にしか無かった。

  | 系統 | 判定 | 自動実行 (#99 以前) |
  |---|---|---|
  | `stale-branch-sweep.sh` (SessionStart) | 既定ブランチの祖先 = `git branch -d` が通る | あり ([ADR 0016](0016-agent-behavior-hooks-in-plugin.md) / #95) |
  | `git gone-clean` | `upstream:track == [gone]` | **なし** (env-doctor が提示するだけ) |

  ところが個人標準は `gh-squash-only` を required にしている。squash されたコミットは既定ブランチの祖先にならないので、**自動で走る側の判定は「マージ済みブランチ」を構造的に 1 本も拾えない**。実際に拾うべき本命が毎回手動に落ち、`shinyaoguri/metaphor` では 98 本中 52 本が `[gone]` のまま溜まっていた (#67 の実測)。

  さらにエージェント作業では、掃除のたびに削除の承認を求めることになる。可逆な操作に確認を挟まず**確認をプラン 1 点へ集約する** [ADR 0017](0017-approval-at-the-plan.md) と真正面から噛み合わない (本題と無関係なブランチ掃除で承認を 1 回使ってしまう事例が実際に起きた)。

  一方で「削除系は提示に留める」という env-doctor の方針にも理由がある。**削除してよいかは操作の種類でなく、消えるものが他に残っているかで決まる**。

- **決定**: 判断の軸を「削除系かどうか」から**「情報が 1 ビットも失われないと機械的に証明できるか」**へ置き換える。証明できるものは自動で消し、証明できないものは従来どおり提示に留める。

  現時点で証明として認めるのは 2 つだけ:

  | 証明 | 消えるものはどこに残るか |
  |---|---|
  | 既定ブランチの祖先である (`git merge-base --is-ancestor`) | コミットがそのまま既定ブランチに残る。削除も `git branch -d` なので git 自身が二重に拒否する |
  | `upstream:track == [gone]` かつ、**マージ済み PR の `headRefOid` とローカル tip の SHA が一致する** | squash 後の内容は既定ブランチに、元コミットは GitHub の `refs/pull/<N>/head` に永続的に残る |

  後者は `gh pr list --head <branch> --state merged --json headRefOid` で確かめる。SHA まで照合するのは、**tip が PR の head より進んでいる = 未 push のコミットが載っている**ケースを外すため (ブランチ名の一致だけでは証明にならない)。close された PR・gh が引けない・GitHub 以外の remote はすべて「証明できない」に倒れ、ブランチは残る。

  - **fetch はしない** — どちらの判定も単調なので、remote-tracking が古くても誤爆せず「拾い漏らす」側にしか倒れない
  - **候補が無ければ gh を呼ばない**。掃除済みのリポではネットワークに触れず、セッション開始も待たせない
  - 1 セッションの照会は既定 10 本で打ち切り、残数を報告して `git gone` へ誘導する (`RS_BRANCH_SWEEP_GONE_MAX`)
  - 逃げ道は `RS_BRANCH_SWEEP=0` (両パス) と `RS_BRANCH_SWEEP_GONE=0` (`[gone]` 側のみ)

- **影響**: squash 運用のリポでも、マージ済みブランチが自動で消える。承認は増えない。`git gone-clean` を allowed-tools に載せない方針は維持する — **allowed-tools に載らない削除 = 証明できない削除**という線引きになり、env-doctor の緑が「掃除が回っている」と誤読されないよう `env-git-gone-alias` の detail も「自動で消える範囲」を明示する形へ改めた。

  判定は [scripts/test-rs-branch-sweep.sh](../../scripts/test-rs-branch-sweep.sh) が PR CI で検証する (gh はスタブへ差し替え、`[gone]` は追跡先設定を残したまま remote-tracking を消して再現するのでネットワークに触れない)。

  同じ軸を worktree にも当てる (#114)。`worktree-sweep.sh` (SessionStart) が自動で行うのは `git worktree prune` — **実ディレクトリが既に消えている登録**を畳むだけで、失われる情報が無いことが定義から明らかなもの — に限る。残骸 worktree の削除は、未コミットの変更や再生成できない ignored ファイル (`.env` 等) が残りうるので**証明できない削除**に当たり、従来どおり提示に留める (repo-audit の `worktrees_clean` が候補を挙げる)。ただし**既定ブランチを掴んだ linked worktree だけは、削除の可否とは別に通知する** — 溜まって重いのではなく、別の場所での `gh pr merge --delete-branch` をマージ後のローカル後処理で落とすため。判定は [scripts/test-rs-worktree-sweep.sh](../../scripts/test-rs-worktree-sweep.sh) が PR CI で検証する。

  既知の限界:

  - **証明は remote-tracking の鮮度に依存する**。`fetch.prune` が効いていないリポでは `[gone]` にならず、拾い漏らす (`env-git-fetch-prune` が診断する)
  - **GitHub 以外のホスティングでは `[gone]` 側が丸ごと効かない**。証明の手段が gh しかないため
  - `refs/pull/<N>/head` が残ることは GitHub の挙動への依存であり、リポジトリごと削除されれば当然消える
