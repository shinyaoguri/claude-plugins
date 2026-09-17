# 0024: level は required / recommended の 2 値にし、前提側の項目を required へ上げて必須の穴を塞ぐ

- **状態**: 採用 (2026-09-17)

- **文脈**: `level` は `required` / `recommended` / `rejected` の 3 値だったが、**下流の挙動は 2 つしかなかった**。`fail_status()` (`rs-lib.sh`) は `required` を `ng`、それ以外を全て `warn` にする。`rejected` が `recommended` と違ったのは `repo-bootstrap` の生成対象から外れる点だけで、その `rejected` 項目は [0022 の後続](https://github.com/shinyaoguri/claude-plugins/pull/164) で 0 件になった。値としては在るが意味を持たない語が残っていた。

  もう 1 つ、`required` の集合に穴があった。`adr-covers-decisions` は `level: required` の LLM 判定だが、判定観点が「ADR が 0 件なら `adr-exists` 側の指摘に委ねてこの項目は skip とする」と書いている。ところが委ねた先の `adr-exists` は `recommended` だった。つまり **ADR が 1 件も無いリポジトリは、必須項目を 1 つも落とさない**。最も厳しい項目が、それを最も必要とするリポジトリに届かない。

  本来これは `blocked` (別の標準項目が未達で今は判定できない) で表現すべき状態で、[0019](0019-blocked-vs-skip.md) がその語をまさにこの用途のために足している。しかし `blocked` が入ったのは builtin の status 集合だけで、**LLM 判定の verdict 語彙 (`ok` / `warn` / `ng` / `skip`) には入っていない** ([#167](https://github.com/shinyaoguri/claude-plugins/issues/167))。この項目が `skip` を使っているのはそのためで、0019 が防ごうとした「required が黙って消える」形が LLM 判定側で再発していた。

- **決定**:
  1. `level` から `rejected` を廃止し、`required` / `recommended` の 2 値にする。「意図的に採らない」を表したいときは `check: file_absent` の `recommended` 項目で足りる (`rejected` はその上に貼るラベルでしかなかった)。`check-repo-standards.sh` の語彙から外し、`repo-bootstrap` の空振りフィルタも撤去する
  2. `adr-exists` を `recommended` → `required` へ上げる。`adr-covers-decisions` が既に `required` である以上、ADR を残すこと自体は必須という判断が先にある。その前提を検査する安価な機械判定が `recommended` に留まっているのが不整合だった
  3. LLM 判定の verdict に `blocked` を足すのは別の関心として切り出す ([#167](https://github.com/shinyaoguri/claude-plugins/issues/167))。語彙を増やすのは判定係・受け取り側・findings にまたがる変更で、穴を塞ぐこととは独立に進められる

- **影響**: `required` は 16 → 17 件、`recommended` は 33 件。**ADR が 0 件のリポジトリは `adr-exists` が `ng` として報告される**ようになる (これまでは `warn` のうえ、依存する required は skip で消えていた)。

  `fail_status()` の挙動は変わらない (`rejected` は既定の `*` 節に落ちていたため)。変えたのは語彙とコメントだけ。

  決定 2 は「すべてのリポジトリで ADR を必須とする」ことを意味する。軽いリポジトリには重い要求だが、`adr-covers-decisions` を `required` に置いた時点でその判断は済んでいる。重すぎると感じるなら、下げるべきは両方であって片方ではない。

  なお `repo-audit-fix` の `decision: rejected` (直さないと決めた) は別の名前空間で、この決定の対象外。
