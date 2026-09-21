# 0027: 手段の存在理由は setup の意図の台帳に持ち、このリポとの突き合わせは週次で見る

- **状態**: 採用 (2026-09-21)

- **文脈**: Claude Code 本体は週に複数回リリースされるが、このリポのフックとスキルを本体の更新と突き合わせる仕組みが無かった。自前で組んだものが本体の標準機能に入っても、気付く経路は「たまたま changelog を読んだとき」しか無い。月次の portfolio-review が見る上流は自分のリポジトリで、Anthropic 側ではない。[0004](0004-deprecation-guard.md) の非推奨リストは「公式が明言した禁止構成」を機械的に止めるが、「もう要らなくなった自作」は止められない。

  shinyaoguri/setup が `claude/intents.json` (意図の台帳) を持った (shinyaoguri/setup#232)。正本は「何をしたいか」で、手段 (本体機能 / 第三者 / 自作) はその下に交換可能なものとしてぶら下がる。自作の手段には `sunset` (本体に何が入ったらやめるか) が必須で、本体が更新されるたびに存在理由を問われるのは自作の側になる。このリポのフックとスキルは、`plugin-self` の ref (`repo-standards@shinyaoguri#hooks/scripts/plan-gate.sh`) として台帳に載っている。

  台帳を setup に 1 本だけ置いたのは、1 つの意図の手段が 2 つのリポに跨るため (「人間の確認をプラン 1 点に集約する」= setup の CLAUDE.md の記述 + このリポの plan-gate / plan-pass)。全手段が合流する宣言点 (`enabledPlugins`・hooks・`autoMode`) は setup にしか無い ([0021](0021-three-layer-placement.md))。

  残る問題は、**setup の CI からはこのリポの中が見えない**こと。setup 側の被覆テストが見られるのは「`repo-standards@shinyaoguri` が `enabledPlugins` で有効か」までで、`#` より後ろのパスが実在するか、このリポに台帳へ載っていない手段が増えていないかは見えない。載っていない手段は、問われないまま残る。

- **決定**:
  1. `scripts/check-intent-coverage.sh` が両方向を見る。**手段 → 台帳**: `hooks.json` の全 command と `skills/*` が、どれかの意図の手段として載っている。**台帳 → 手段**: 台帳が指す `plugin-self` の ref の実体がこのリポに在る。被覆の単位はフック (登録された command) とスキルまでで、エージェント (`agents/*.md`) と `scripts/rs-*.sh` は repo-audit の内部実装なので単位にしない — 意図は「本体が置換したら一緒に消す単位」で切ってあり、内部実装はスキルと一緒に消える
  2. **PR CI には置かず、週次の freshness にだけ置く。** フックを足す PR は台帳が未更新なので赤くなり、台帳へ先に ref を足す PR は実体が無いので赤くなる — 2 つのリポの PR が互いを待って詰まる。跨ぎの契約を PR CI に置くと起きる事故は [0022](0022-repo-standards-bundled.md) で一度踏んでいる。週次なら順序を問わず、ずれは最長 1 週間で `label:freshness` の Issue に出る
  3. 台帳の在処は `$INTENTS_JSON` (テストと手元の確認用) → 無ければ `gh api` で setup の default branch から取る。`upstream-refs.json` にも `claude/intents.json` を載せ、リネーム・削除は既存の `--exists` が拾う
  4. 「本体の更新で要らなくなったか」の**判定はこのリポではやらない**。setup の `claude-upstream-review` スキルが changelog と台帳を突き合わせ、このリポの手段に変更が要るときはここへ Issue を起票する (初回の見直しが #176・#177 を起こした)。portfolio-review との分担は、向こうが内向き (利用履歴から新設・統廃合を見る・月次)、こちらが外向き (本体の changelog・Issue 起点)

- **影響**: フックかスキルを足す・消す・改名するときは、setup の `claude/intents.json` も直す (足すなら「何をしたくて在るのか」と `sunset` を書く)。忘れても PR は通るが、次の月曜に freshness の Issue に出る。

  portfolio-review に接点を 2 つ足す: 新設候補のうち手段がまだ無いものは、台帳へ `means` が空の意図 (unmet) として入れる — 本体の新機能で満たせるようになったかを、次の見直しが判定する。統廃合の理由が「本体機能による置換」なら、台帳の `sunset` を物差しにする。

  [0002](0002-freshness-architecture.md) の週次の層に検査が 1 つ増える。台帳の形 (`intents[].means[]` の `kind` / `ref`) はこのスクリプトとの契約になるので、setup 側で形を変えるときはここも直す — 形が読めなくなったら「台帳を読めない」で週次が赤くなる。
