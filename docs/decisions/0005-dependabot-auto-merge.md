# 0005: Dependabot PR の自動マージは CI green に委ね、patch/minor に限定する

- **状態**: 採用 (2026-08-03)
- **文脈**: [0002](0002-freshness-architecture.md) の陳腐化防止として Dependabot で GitHub Actions を週次監視しているが、PR は人が手でマージしていた。更新対象が `github-actions` エコソースのみである点が効いていて、**更新された action 自身が PR CI を走らせる**構造になっている ([ci.yml](../../.github/workflows/ci.yml) の checkout/setup-node)。つまり `validate` / `pr-policy` の green は「新バージョンで実際に動いた」実証を兼ねており、人が追加で確認できることは多くない。一方で ruleset `main-protection` は bypass_actors が空で required status checks を Dependabot にも強制しているため、自動マージしても検査が素通りすることはない。残るリスクは (a) action の major bump に伴う非互換、(b) PR CI に載らない workflow の存在、(c) PR タイトル規約との衝突による恒久停止、の 3 点だった。
- **決定**:
  - 判定そのものは新設せず、**ruleset の required status checks (`validate` / `pr-policy`) を合格条件として流用する**。GitHub の auto-merge が checks 通過後に squash merge する (リポジトリ設定 `allow_auto_merge` を有効化)
  - 自動マージの対象は **semver patch / minor に限定**する。major は `dependabot/fetch-metadata` で判別し、`manual-review` ラベルを付けて人のレビューへ回す
  - [freshness.yml](../../.github/workflows/freshness.yml) は `schedule` / `workflow_dispatch` でしか起動せず PR CI に載らないため、**そのファイルに差分がある PR だけ PR ブランチで `workflow_dispatch` 試走**し、green を確認してから auto-merge を有効化する
  - Dependabot の PR タイトル prefix を [dependabot.yml](../../.github/dependabot.yml) の `commit-message.prefix: build` で固定する。未指定時の「コミット履歴からの推測」に依存すると、推測が外れた瞬間に [check-pr-title.sh](../../scripts/check-pr-title.sh) が落ちて自動マージが恒久的に止まる
  - action の指定は可読性を優先してタグのまま (SHA ピンにしない)。利用中の action が `actions/*` と少数の著名 action に収まっている前提の判断で、第三者 action が増えたら再検討する
  - 上記の非対称性への手当てとして、[dependabot.yml](../../.github/dependabot.yml) に `cooldown.default-days: 7` を明示する (2026 年以降 Dependabot は既定でも 3 日待つが、自動マージを入れた以上は猶予を伸ばす。週次スケジュールのため実質の遅延はほぼない)
- **補足 (根拠の非対称性)**: 「更新された action 自身が PR CI を走らせるので CI green が実証を兼ねる」という論理は、裏返すと**汚染された action もマージ前に CI 内で実行される**ことを意味する。GitHub が Dependabot にネイティブの自動マージを実装していないのはまさにこの理由で、trivy-action の侵害では自動マージを入れたリポジトリが悪意ある workflow バージョンへ自動更新し、それを CI で実行した。この ADR は「対象が `actions/*` 中心」「required status checks が Dependabot にも強制される」「cooldown で猶予がある」の 3 条件のもとで自動マージを許容するもので、前提が崩れたら (第三者 action の増加、cooldown の短縮、bypass_actors の追加) 再評価する。
- **影響**: patch/minor の action 更新は人手なしで main に入る。major と、試走に失敗した PR は `manual-review` ラベルが付いて残る。試走は実データのドリフトでも赤くなり freshness Issue を起票しうるが、週次でどのみち起票されるものなので許容する。`plugins/**` に差分が出ないため version bump 検査 ([0003](0003-version-policy.md)) は「差分なし」で通り、marketplace のクライアントへは伝搬しない。
