# 0026: マシン 1 台の事実は監査項目にしない — worktree は落とし、リモートブランチは GitHub に直接聞く

- **状態**: 採用 (2026-09-17)

- **文脈**: `repo-audit` の SKILL.md は「マシン 1 台の事実なので、リポ層に置くと全リポぶん同じ判定を繰り返すことになる」と書いて、worktree のガードを項目にしない判断を明記している。ところが**その線引きを破っている項目が 2 件、標準の側に残っていた**。

  **`claude-worktrees-clean`** は `git worktree list` を読む。worktree はそのマシンにしか存在しないので、同じリポジトリでもマシンごとに結論が変わる。さらに悪いことに、**いま動いているセッション自身の worktree が warn の材料になる** — `next-task` スキルが作った worktree を、同じプラグインの監査が削除候補として並べる。`worktree-sweep.sh` (SessionStart hook) は既に同じ状態を見ており、冒頭コメントで「repo-audit の worktrees_clean も同じ状態を指摘するが、監査を回すまで誰も見ないので、日常のセッションで気付ける口をここに置く」と重複を自認していた。

  **`no-stale-branches`** は事情が違う。見ているのは**リモートブランチ = GitHub 側の実状態**で、これはリポジトリの事実である。マシン依存なのは読み方だけ — ローカルの追跡 ref (`git branch -r`) 経由なので fetch の鮮度で結論が変わり、実装自身が detail に「fetch していなければ古い可能性」と但し書きを出していた。**項目が悪いのではなく、データの取り方が悪い。**

- **決定**:
  1. `claude-worktrees-clean` を正本から削除する。実装 (`builtin_worktrees_clean` と補助の `removable_worktrees` / `default_branch_worktrees`) も撤去する。受け皿は既存の `worktree-sweep.sh` で、**監査を待たず毎セッション気付ける**ぶんそちらが優れている
  2. `no-stale-branches` は残し、**GitHub に直接聞く形へ変える**。`layer` を `repo` から `github` へ移し、`rs-audit-github.sh` で GraphQL 1 回 (`refs(refPrefix:"refs/heads/")` + `committedDate`) から判定する。REST だとブランチごとに 1 回要るのでクエリは GraphQL を使う
  3. `repo-audit` の env-doctor 誘導は、消えた項目の detail でなく `git worktree list` の行数で判断する。誘導の意図 (worktree を跨ぐ作業をするならガードの実在を確かめる) は変わらない

- **影響**: 項目は 50 → 49 件。`no-stale-branches` は `gh` 認証が要る側へ移るので、未認証の環境では `skip_all` の対象になる (従来はローカル ref で判定できていた)。**代わりに、どのマシンで回しても同じ結論が出る**。

  fetch していないマシンで「30 日以上動いていないブランチ」が誤検出される問題が消える。逆に、fetch していないマシンでも検出されるようになる。

  worktree の掃除は `repo-audit-fix` の承認一覧から消え、SessionStart hook の通知だけになる。hook は削除を一切しない (ADR 0018 の立場) ので、消したいときはユーザーが自分で判断する形は変わらない。
