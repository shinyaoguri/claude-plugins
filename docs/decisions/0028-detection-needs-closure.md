# 0028: 検知の層は「閉じる輪」を持つものだけを置く

- **状態**: 採用 (2026-09-22, Issue [#179](https://github.com/shinyaoguri/claude-plugins/issues/179) の判断)

- **文脈**: リポ開始から 7 週で、プラグイン 1 個に対して scripts 28 本・CI ジョブ 3・週次検査 3 種・PR のラベル規約 5 種が積まれた。全体レビュー (#179) で確かめると、複雑さの主因は個々の部品ではなく、**検知する層を足し続け、検知結果を閉じる輪が無い**ことだった:

  - 週次 freshness は 5 週連続 failure のまま、自動起票の #136 にコメントだけが積まれていた (原因はリンク先の非公開化で、直せば 1 日で済むものだった)
  - 月次 portfolio-review は一度も回った形跡が無く、[0004](0004-deprecation-guard.md) / [0009](0009-plugin-granularity.md) / [0020](0020-skills-ship-as-plugins.md) が判断を委ねた先が空いていた
  - 守りの弱体化レポート ([0007](0007-guardrail-visibility.md)) は `guardrail-change` を 11 件に付けたが、本命だった「承認を消すフックの追加」は素通りした (#154)。削る変更しか見ないので、**足して弱める変更は原理的に拾えない**。1 人運用ではラベルを見るレビュアーもいない

  輪の無い検知は無害ではない。赤やラベルが常態になると、輪のある検知 (PR CI の判定テスト) の信用まで一緒に落ちる。

- **決定**:
  1. **検知の層を足すときは、検知したものを誰が・どの操作で閉じるのかを先に決める**。閉じる操作が PR のマージに繋がらない検知 (ラベルを付けるだけ・コメントを積むだけ) は置かない。PR CI のゲートは「直さないとマージできない」、setup の claude-upstream は「見直しを終える PR でしか Issue が閉じない」で、どちらも輪が閉じている
  2. 次の層を外す (それぞれ別 PR。個別に revert できる):
     - **守りの弱体化レポート** — `check-guardrail-weakening.sh` と `upsert-pr-comment.sh`、そのテスト、ci.yml の guardrail ジョブ、`guardrail-change` ラベル。0007 のうち権限側の決定 (`Administration` の剥奪だけ行う) は現行のまま
     - **上流参照のマニフェスト網羅** (`check-upstream-refs.sh --coverage`) — 前提だった「上流パス参照が中心のプラグイン」は #143 で無くなった。照合が部分文字列一致で `CLAUDE.md` が `claude/CLAUDE.md` に当たり、検査として機能していなかった。週次の `--exists` (上流のリネーム・削除の検知) は残す
     - **version bump の期待増分の強制** ([0003](0003-version-policy.md) の決定のうち、PR タイトルの type と `release:*` ラベルから増分を導出して完全一致を強制する部分) — 守りたい事故は「bump 忘れで他マシンへ伝搬しない」の 1 つで、それは「`plugins/` に差分があれば version が変わっている」だけで防げる。type の限定は refactor の PR で 3 回ラベル迂回されていた
  3. 残す守り: `claude plugin validate` / `check-consistency.sh` / `check-deprecated-patterns.sh` / `check-repo-standards.sh` / `scripts/test-*.sh` の全部 / PR タイトルの lint / bump 済みの検査 / 週次の `--exists`・意図の台帳との突き合わせ・lychee
  4. 同種の問題が 2 回起きたら仕組みへ昇格する、という CLAUDE.md の方針は変えない。変えるのは昇格先の条件で、**ゲート (直さないと進めない) にできないものは、仕組みにせず Issue に留める**

- **影響**: scripts 28 → 23 本、CI ジョブ 3 → 2、PR のラベル規約が無くなる。テストや CI を削る変更は、PR の diff と PR 本文 (目的・変更点) でしか見えなくなる — 1 人運用ではもともとそこでしか見ていなかった。検知の一本化 (freshness / claude-upstream / portfolio-review) と利用実績の記録は setup リポにまたがるので、#179 のステップ A で別に決める
