# 0029: 標準の有用性は「設置させたものが設置先で使われているか」で測り、期限で再測定を強制する

- **状態**: 採用 (2026-09-22, Issue [#179](https://github.com/shinyaoguri/claude-plugins/issues/179) の判断)

- **文脈**: 「使っていない設定が陳腐化して残らないようにしたい」という要求に対して、最初に検討したのはフックとスキルの呼び出し回数を記録する案だった。これは却下した — **repo-standards はリポジトリを設定する道具で、頻繁に呼ばれないのが正常**だから、呼ばれた回数は有用性の物差しにならない。測るべきは、プラグインが各リポに設置させている標準 (repo-standards.json の項目) が**設置先で使われているか**、つまり無駄な設定を配るプラグインになっていないかである。

  そのための器は正本に既に在り、死蔵されていた。各項目は `evidence.kind` として `principle` (目的から導ける) / `spec` (公式仕様への主張) / `observation` (測った事実。`measured_at` と再測定手順 `method` が必須) のどれかを宣言し、`scripts/check-repo-standards.sh` が observation と spec を 180 日で期限切れにして PR CI を落とす。再測定しないと次の PR が通らないので、[0028](0028-detection-needs-closure.md) の言う「閉じる輪」を最初から持っている。ところが 49 項目中 45 項目が `principle` を名乗って素通りし、`observation` は 0 件、測る手段も無かった。

  利用の棚卸しを担うはずだった月次 portfolio-review ([0002](0002-freshness-architecture.md)・[0027](0027-intents-ledger-cross-repo-coverage.md) 決定 4 の「内向き」) は、一度も回った形跡が無い。scheduled task の登録が人任せで、回らなくても誰も気付かない = 輪が無い。

- **決定**:
  1. **設置するだけでは価値が出ず、使われて初めて意味を持つ項目の根拠は `observation` にする**。`principle` に残すのは、守り (ブランチ保護・秘密の混入防止など、発動しないのが正常なもの) と、測りようのないものに限る。
  2. 測定は `scripts/measure-standards-usage.sh` が行う。直近 90 日に push のある自分のリポを対象に、項目ごとに「設置されているリポ数」と「うち使われているリポ数」を数える。**プラグインには同梱しない** — 配った先で動かすものではなく、正本を維持するための測定だから。非公開リポを見るので CI では回さず、手元で実行する。内訳にはリポ名が入るので、**外 (正本の `result`・PR・Issue) へ出すのは件数だけ**にする。
  3. 結果は正本の `evidence.result` に書く (必須)。前回と比べられないと、再測定しても良くなったのか悪くなったのかが分からない。
  4. **再測定は期限切れが強制する** (180 日。既存の仕組みのまま)。再測定の PR は、使用が設置の 1/3 未満だった項目について **削る / recommended へ下げる / `when` で対象を絞る / 残す理由を `result` に書く** のどれかを必ず選ぶ。測って終わりにしない。
  5. 最初に測るのは、安く・誤判定少なく測れる 7 項目に限る: `issue-template-exists` / `pr-template-exists` / `dependabot-config` / `changelog-exists` / `adr-exists` / `scheduled-freshness` / `pr-visual-evidence`。測り方に自信が持てる項目を、再測定のたびに足していく。
     - プランでは `gh-tag-protection` も挙げていたが外した。「タグの無いリポでは保護が空振りする」と見立てたが、監査側 (`builtin_tag_protection`) が既にタグの無いリポを skip にしており、無駄な設定を求めてはいなかった。
  6. **月次 portfolio-review は廃止する**。見直しの輪は 2 本になる:
     - **本体への追従** — setup の claude-upstream (意図の台帳 + 週次の changelog 突き合わせ + claude-upstream-review)。`reviewed_against` を進める PR でしか Issue が閉じない。0027 決定 4 のうち「外向き = claude-upstream」はそのまま
     - **標準の有用性** — この observation の期限
     [0004](0004-deprecation-guard.md) が月次に委ねた「非推奨リストの鮮度」は claude-upstream-review が changelog から拾う。[0009](0009-plugin-granularity.md) / [0020](0020-skills-ship-as-plugins.md) が月次に委ねた「統廃合の判断」は、定期の層を持たず、必要になったとき `plugin-proposal` の Issue で起こす。

- **影響**: 初回の実測 (2026-09-22、対象 44 リポ) — Issue テンプレートは設置 21 リポ中 8 リポでしか構成として使われておらず (`gh issue create` がテンプレートを通らないため)、PR テンプレートは 22 中 19、Dependabot は 25 中 20、ADR は 21 中 21、定期検査は 16 中 13 が緑、CHANGELOG は 4 中 2 がリリースに追随。**使用の低い項目をどうするかは標準そのものの変更なので、この ADR では決めない** (#179 のステップ C で項目ごとに扱う)。測定は 1 回 3 分ほどで、半年に 1 度の再測定の負担は小さい。呼び出し回数の記録・測定の定期実行・未使用の自動起票は置かない (輪の無い検知になる)。
