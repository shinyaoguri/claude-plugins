# 0023: リポ種別による項目の出し分け (kinds / applies_to) を畳み、種別の知識は消費側に置く

- **状態**: 採用 (2026-09-17)

- **文脈**: 正本は `kinds` (swift / web / python / generic を marker ファイルで判定) を宣言し、各項目が `applies_to` で対象種別を指す形を持っていた。ところが**全 51 項目が `applies_to: ["all"]`** で、`rs-audit-repo.sh` のフィルタは一度も項目を除外していなかった。

  一方で種別ごとの差は実在し、**消費側にハードコードされて動いていた**。`builtin_test_dir_exists` は Swift / Python / TypeScript / Go / Ruby / bats のテストディレクトリ命名を、`builtin_tests_run_in_ci` は `package.json` を特別扱いする。つまり抽象化の口 (`applies_to`) は開いているのに使われず、同じ関心が実装側に埋まっていた。

  正本側のテストも「`applies_to` の値が kind id か `all` に解決するか」しか見ないので、全項目が `all` でも緑のまま通り、死蔵を検知できなかった。

  なお `kinds` は完全な死蔵ではない。検出された種別は出力の `_meta.kind` に載り、`repo-audit-fix` が「`dependabot-config` のエコシステムを聞くのは kind が generic のときだけ」という分岐に使っている。畳むのは**項目の出し分け**であって、種別の概念そのものではない。

- **決定**:
  1. 正本から `kinds` と全項目の `applies_to` を削除する。`rs-audit-repo.sh` の種別フィルタも外す (一度も除外していなかったので判定は変わらない)
  2. marker → 種別の対応表は `rs-audit-repo.sh` に literal で持つ。言語ごとの知識が既にこのスクリプトにあり、同じ関心を 2 箇所へ散らさないため。`_meta.kind` は従来どおり出力する
  3. 項目に条件付けが要るときは `when` を使う。`when.visibility` が既に 4 項目で動いている実績のある機構で、必要なら `when` を拡張する方が、使われない並行機構をもう一つ持つより良い
  4. 畳んだ抽象が戻らないことを `check-repo-standards.sh` が検査する (トップレベルの `kinds`、項目の `applies_to` を禁じる)

- **影響**: 標準の項目はすべてのリポ種別に当たる。種別は**生成物の中身**を決めるためだけに使われ、どの項目を生成するかは変えない (`repo-bootstrap` の手順 1・2 をその形へ直す)。

  正本が 56 行短くなる。種別ごとの項目を将来足したくなったら、`when` の拡張として設計し直す — その時点で本当に必要かを問い直せる形になる。

  `_meta.kind` を使う `repo-audit-fix` の分岐と、`--kind` 引数を取る `repo-bootstrap` は従来どおり動く。
