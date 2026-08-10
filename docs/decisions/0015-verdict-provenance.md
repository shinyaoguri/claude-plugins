# 0015: 判定の出自を findings の行に持たせ、上書き規則で階層と食い違いを守る

- **状態**: 採用 (2026-08-10, Issue [#62](https://github.com/shinyaoguri/claude-plugins/issues/62) と [#74](https://github.com/shinyaoguri/claude-plugins/issues/74) の 2 の判断)
- **文脈**: [0011](0011-audit-cost-tiers.md) で監査をコストで階層に分け、[0013](0013-standard-vs-repo-intent.md) で標準の指摘とリポの設計意図を突き合わせる層を入れた。運用してみると、`findings.jsonl` の行が**判定を 1 つの `verdict` フィールドでしか表せない**ことが 2 つの形で表面化した。

  - **安い層の判定を保存できない** ([#62](https://github.com/shinyaoguri/claude-plugins/issues/62))。`repo-audit-min` の判定 (畳んだ材料 + Haiku + ファイル 3 件まで) と本監査の判定 (項目ごとの並列サブエージェント + 実ファイル読み + 反証) が同じフィールドに同居すると、前者が後者を無警告で置き換えうる。結果として簡易監査は triage 専用に留まり、**NG を見つけても修正へ直行できない** — 「安いから起動する」効果が修正側で目減りしていた
  - **機械判定を覆した記録が揮発する** ([#74](https://github.com/shinyaoguri/claude-plugins/issues/74) の 2)。機械判定の warn を LLM が偽陽性と判定して `ok` に覆すと、`verdict` が ok = 適合とみなされて `decision` と `intent` がその場で落ちる。しかし `status` は warn のままなので項目は集計にも `--needs-intent-check` にも残り続け、**「なぜ直さないのか」だけが消える**。機械判定と LLM 判定が食い違うのは監査が一番価値を出す場面で、そこだけ記録が残らない

  どちらも `verdict` 周りの引き継ぎ規則を触るため、別々に設計すると同じ規則を二度決めることになる。

- **決定**:

  1. **行に `verdict_source` を持たせる** (`full` / `min`)。`rs-findings.sh set --verdict` に `--source` を足し、**既定は `full`** とする。既定を min にすると、書き戻しを 1 か所書き忘れただけで本監査の判定が暫定値として扱われる — 安全側に倒す
  2. **min の verdict は full の verdict を上書きしない**。陳腐化していない (HEAD が一致する) full の判定がある行への min の書き込みはスキップし、その id を stderr で伝える。**未知 id と違って全体を拒否せず、残りは書き込む** — 一括判定が 1 件の衝突で丸ごと落ちると triage にならない。陳腐化した full は上書きしてよい (古い判定より新しい暫定判定の方が実態に近い)
  3. **min の判定は常に再判定の対象に残す**。`list --needs-verdict` が `verdict_source: min` を含め、本監査を回せば必ず full の判定に置き換わる。反証待ち (`--needs-verify`) には数えない — 反証は本監査の作法で、暫定判定はその前に置き換わる。集計では未判定 (`manual_unjudged`) と分けて `provisional` として数え、修正フローへは進めるようにする
  4. **`repo-audit-min` に `--save` を足す**。既定は保存しないまま (triage 専用) で、明示したときだけ機械判定を findings に保存する。機械判定の結果は層によらず同じなので保存してよく、階層の違いは 1〜3 の書き戻し規則が受け持つ。**保存しても出力は圧縮テキストのまま** — 保存の出力 (JSON Lines 全行 + 集計) を流すとこのスクリプトの存在理由が消えるため捨て、保存できたかどうかだけを次アクションの 1 行に畳む
  5. **機械判定 (status が ng / warn) の行では、verdict が ok / skip でも `decision` / `note` / `intent` を落とさない**。そこでの verdict ok は「機械判定が偽陽性だった」という**異議**であって、status が示す事実は消えない。落とす規則は manual 項目に限る
  6. **機械判定の status は LLM 判定で覆さない**。集計の ng / warn は機械判定のまま残し、覆された件数を `overridden` として別に数える。[0013](0013-standard-vs-repo-intent.md) の決定 (intent は verdict を上書きしない) と同じ考え方 — 「外れている」という事実と「このリポではそれでよい / それは誤検知だ」という文脈は別物で、後者で前者を消すと逸脱が理由なく常態化する。読む側で両方が見えるよう、レポートには機械の status と LLM の verdict を併記し、根拠を載せる

- **影響**: [0011](0011-audit-cost-tiers.md) の決定 5 (簡易版は findings を保存しない) を改訂する — 保存しないのが既定である点は変わらないが、`--save` という出口ができ、`repo-audit-min` → `repo-audit-fix` の導線が開く。安い層で見つけた必須違反をその場で直せるようになる一方、**暫定判定のまま修正まで進める経路ができた**ので、`repo-audit-fix` は前提確認で暫定件数を見て「NG の修正までに留めるか、本監査で判定し直すか」を促す。行スキーマが増えるが、`verdict_source` を持たない既存行は `full` とみなすため findings の作り直しは要らない。判定の質の違いが行に載ったことで、今後 judge を足す (別モデル・別材料) 場合も同じ枠で扱える。
