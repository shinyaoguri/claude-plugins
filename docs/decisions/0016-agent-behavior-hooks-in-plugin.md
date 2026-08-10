# 0016: エージェントの振る舞いを縛るフックは、リポにコミットせずプラグインが供給する

- **状態**: 採用 (2026-08-10, Issue [#86](https://github.com/shinyaoguri/claude-plugins/issues/86) の判断)

- **文脈**: 「push した PR の CI が赤いままセッションを終えられない」フック (ci-watch) を [metaphor](https://github.com/shinyaoguri/metaphor) と [metaphor-cli](https://github.com/shinyaoguri/metaphor-cli) の各リポへコピーして実地投入し、機能することを確認した ([metaphor#450](https://github.com/shinyaoguri/metaphor/pull/450) / [metaphor-cli#104](https://github.com/shinyaoguri/metaphor-cli/pull/104))。これを個人標準へ採り込むにあたり、配り方が [#86](https://github.com/shinyaoguri/claude-plugins/issues/86) の論点として残った。当初の候補は (1) 各リポへコピー、(2) プロジェクトの `.claude/settings.json` から `${CLAUDE_PLUGIN_ROOT}` を参照、(3) プラグイン同梱 + `repo-bootstrap` が雛形をコピー。

  検討で分かったこと:

  - **(2) は成立しない**。公式リファレンスによれば `${CLAUDE_PLUGIN_ROOT}` が解決するのは plugin component のフィールド (プラグインの hook / monitor command、MCP、LSP、skill・agent 本文) であって、プロジェクトの `settings.json` は対象外。そもそもどのプラグインの root か決まらない
  - **(1)/(3) の「リポごとに育てられる」という利点は実測で 2 行しかない**。先行導入した 2 リポのコピーは既に分岐していたが、差分はローカル検証コマンド (`make ci-check` / `make test`) と flaky の Issue 番号だけで、ロジック 260 行とテストは完全に同一だった。しかもその 2 行は「CLAUDE.md に検証コマンドを書く」既存標準 (`claude-md-quality`) へ委譲すれば消える
  - 同種のマシン全体ガードは既に setup リポの `claude/` にあり (`git-safety-guard.sh` ほか PreToolUse 4 本)、プラグインが `hooks/hooks.json` でフックを供給する前例も metaphor-sketch にある (SessionStart。非対象プロジェクトでは自己ガードで無出力)

  つまり本当の分かれ目は置き場ではなく、**ci-watch が「リポの設定」なのか「エージェントの振る舞い」なのか**だった。守る対象は「Claude が赤を残して立ち去る」という挙動であって、リポの構成ではない。人間が clone しても Stop hook は存在しないので、リポにコミットしても他人には何も起きない。

- **決定**: エージェントの振る舞いを縛るフックは**リポにコミットせず、`repo-standards` プラグインが `hooks/hooks.json` で供給する**。ci-watch はその第 1 号として `plugins/repo-standards/hooks/scripts/` に置く。

  帰結:

  - **個人標準 (`repo-standards.json`) に項目を足さない**。リポ層に項目を置くと同じ事実を全リポぶん判定することになり、[#82](https://github.com/shinyaoguri/claude-plugins/issues/82) で (a) env-doctor 委譲を選んだ判断と逆行する。`repo-bootstrap` の雛形にも `repo-audit-fix` の修正手順にも含めない
  - **無音の欠落という失敗モードが存在しない**。プラグインが無効なら `/repo-audit` などのスキルごと消えるので、フックの生死とスキルの生死が一致する。setup リポ経由 (`settings.json` の登録と `~/.claude` の実体が別々に壊れうる) と違い、[#83](https://github.com/shinyaoguri/claude-plugins/pull/83) の走査に頼らずに済む
  - **伝搬が version bump だけで済む**。打ち切り回数・差し戻し文面・pending 判定のチューニングは今後も続く見込みで、ansible の再実行を待たずに全マシンへ届く
  - リポ固有の検証コマンドは持たず、差し戻し文面から CLAUDE.md へ委譲する (標準どうしが噛み合う形)

- **影響**: フックはプラグインを有効にした**全プロジェクトで動く**。対象外の状況 (push していないセッション、main ブランチ、PR 無し、bot の PR、git 管理外のディレクトリ) では何も出さずに即終了し、自動修正 3 回・待機 6 回で打ち切って人間の判断へ返す。それでも止めたい場面のために `RS_CI_WATCH=0` を逃げ道として置いた。判定は [scripts/test-rs-ci-watch.sh](../../scripts/test-rs-ci-watch.sh) が PR CI で検証する (26 assertions。使い捨て git リポ + `gh` スタブで、GitHub にも Claude セッションにも触らない)。

  既知の限界: Claude Code のセッションが動いている間だけ有効で、無人時間に bot PR が赤くなっても拾えない。印は `git push` を含む Bash 実行で置かれるため、GitHub UI から直接コミットした場合などは対象外。

  metaphor / metaphor-cli に入れた既存のコピーは二重に発火するので、各リポ側で削除する ([metaphor#452](https://github.com/shinyaoguri/metaphor/issues/452) / [metaphor-cli#106](https://github.com/shinyaoguri/metaphor-cli/issues/106))。
