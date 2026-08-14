# 0019: 前提未達の保留 (blocked) を恒久的な対象外 (skip) と分ける

- **状態**: 採用 (2026-08-15, Issue [#97](https://github.com/shinyaoguri/claude-plugins/issues/97) の判断)
- **文脈**: 監査スクリプトの出力契約 ([rs-lib.sh](../../plugins/repo-standards/scripts/rs-lib.sh)) は、判定できなかった項目をすべて `skip` (対象外・前提不足) に落としていた。そこには性質の違う 2 つが同居している。

  - **恒久的に対象外** — タグを打たないリポの `gh-tag-protection`、private 限定項目、リポ種別が違う項目。リポの性質が変わらない限り判定対象にならない
  - **前提が未達で今は判定できない** — CI workflow が無いので `gh-required-checks` を判定できない、`.gitignore` が無いので `gitignore-covers-env` を判定できない。**前提が埋まれば判定対象に戻る**

  後者を `skip` に潰すと、報告にも持ち越しにも載らないまま消える。`shinyaoguri/p5stage` で実害が出た: bootstrap 時に技術スタック未確定で `ci-workflow-exists` を見送った結果、`level: required` の `gh-required-checks` が**適用済みにも見送りにも現れず**、後で CI を足しても拾い直す契機が無かった。ruleset に `required_status_checks` が無いまま `gh pr merge --auto` が CI の結果と無関係に即マージする状態が Phase 0 以降ずっと続いた。**required の取りこぼしが、気付く手段の無い形で常態化する**のが問題の本体で、判定そのものは瞬間的には正しい (要求すべき check がまだ存在しない) ぶん、レビューでも見つからない。

- **決定**:

  1. **status に `blocked` を足す**。意味は「別の**標準項目**が未達で今は判定できない (前提が解消されれば判定対象に戻る)」。`skip` は「恒久的に対象外」に純化する。判断の境目は**前提が標準項目かどうか**に置く — 前提が標準項目なら、それを埋めるのは監査自身の仕事なので拾い直す責任がある。前提がリポの性質・環境 (タグの有無・可視性・種別・gh 未認証・トークン権限) なら `skip` のまま
  2. **`defer` とは呼ばない**。`decision: deferred` (今回は見送り。Issue へ引き継ぐ) が既にあり、同じ語で status と decision の両方を指すと集計が読めなくなる
  3. **`blocked` に `fix` を付けない**。当てる先はこの項目でなく前提側の項目にある。未決 (`decision: pending`) にも置かず、`repo-audit-fix` の承認一覧には並べない
  4. **代わりに、消えないところへ数える**。`rs-findings.sh summary` に `blocked` / `blocked_required` を足し、required の保留があれば hint に id ごと接尾する。`rs-audit-min.sh` は集計行に `blocked=` を出し、**`level: required` の保留だけ `BLOCK` 行として明示する** (recommended まで行にするとトークン最小化の趣旨に反する。件数は集計行で読める)
  5. **持ち越しの責任を repo-bootstrap に持たせる**。生成を見送った項目があるリポでは、それに依存する required が必ず保留になる。仕上げの簡易監査で `BLOCK` 行が出たら、見送り項目と一緒に持ち越し先 (方針 Issue の残タスク) へ**前提の id ごと**書く

  正本 (`repo-standards.json`) に `depends_on` を宣言する案は採らない。前提の検出ロジックは既に builtin 側にあり (workflow ファイルの有無など)、正本に依存関係を二重に持たせても判定するのは builtin のままで、setup リポとの往復が増えるだけプラグイン単体で閉じなくなる。

- **影響**: 出力契約の status 集合が 1 つ増えるため、`status` を列挙している消費側 (`rs-findings.sh` の集計、`rs-audit-min.sh` の集計行、各テストの契約検査) が追随する。既存の findings は作り直し不要 — 再監査で `skip` から `blocked` へ動いた行は、`save` の引き継ぎ規則 (status が変われば判断をやり直す) がそのまま面倒を見る。逆向き (前提が埋まって `blocked` → `ng`) でも同じ規則で未決に戻るので、**拾い直しは自動的に起きる**。環境前提が欠けているときの誤診断 ([#94](https://github.com/shinyaoguri/claude-plugins/issues/94)) はこの決定の対象外で、そちらは `skip` の detail の正しさの問題として別に扱う。
