# 0022: repo-standards の正本をプラグインに同梱し、契約を同一リポジトリで守る

- **状態**: 採用 (2026-09-17)

- **文脈**: [0006](0006-repo-standards-source-of-truth.md) は判定基準の正本を shinyaoguri/setup の `claude/repo-standards.json` に置き、プラグインは `~/.claude` の symlink 経由で解決する形を選んだ。「基準だけ変えるなら setup リポの PR のみで済み、プラグインの bump は不要」という身軽さが理由だった。

  [#159](https://github.com/shinyaoguri/claude-plugins/issues/159) の調査で、その身軽さの代償が実際に出ていることが分かった。

  - **契約を検証するテストが無い。** `check.type` / `builtin` 名は正本とスクリプトのクロスリポ契約だと 0006 決定 5 が宣言しているが、実際に検証されているのは片側だけである。`rs-audit-repo.sh` の `declare -F "builtin_$name"` は「正本にあって関数が無い」を skip として報告するが、**逆方向 (関数が残って正本に無い) は完全に無言**。`level` / `fix_kind` の語が一致しているかを見る仕組みも無い
  - **派生ドキュメントが追随しない。** 2026-08-23 に LLM 判定項目が 6 → 8 に増えた (`pr-visual-evidence` / `docs-images-external`) が、このリポジトリの `README.md` と [0011](0011-audit-cost-tiers.md) のコスト記述は 6 項目前提のまま残った。LLM 項目 1 件がサブエージェント 1〜2 本に効くので、実際の本数は 9〜13 → 11〜17 へ増えている。**リポジトリを跨いだから追随しなかった**
  - **正本を読む主体はこのプラグインだけ**である。setup 側に `repo-standards.json` が無いと困る機構は存在しない

  あわせて、setup 側に置く必然性がどこまであるかを仕様から確かめた。プラグインが供給できないのは `~/.claude/CLAUDE.md`・`permissions`・`additionalDirectories`・`statusLine`・`autoMode` で (プラグイン同梱の `settings.json` で有効なキーは `agent` と `subagentStatusLine` のみ)、さらに marketplace の宣言自体が `settings.json` にある以上ブートストラップの循環がある。`repo-standards.json` はそのどれにも当たらない。

- **決定**:
  1. チェックリストの正本を `plugins/repo-standards/repo-standards.json` としてプラグインに同梱する。項目の増減・変更はこのリポジトリへの PR で行う。0006 決定 1 を置き換える
  2. `resolve_standards()` の解決順を `$REPO_STANDARDS_JSON` → 同梱コピー → `~/.claude/repo-standards.json` → `~/.setup/claude/repo-standards.json` とする。同梱コピーは `$CLAUDE_PLUGIN_ROOT` ではなく**スクリプト自身の位置**から引く (テストが `rs-*.sh` を直接叩く経路でも効かせるため)。旧 2 経路は移設の移行期だけの保険で、setup 側から実体が消えれば dangling symlink が `[ -r ]` を通らず自然に外れる。0006 決定 2 の解決チェーンを置き換える
  3. スキーマ検査は `scripts/check-repo-standards.sh` が担い、CI の `validate` ジョブで流す。setup 側の `claude/tests/repo_standards_test.py` から移植する。検査対象は enum (`layer` / `level` / `check.type` / `fix_kind`)・id の重複・`check.type` ごとの必須フィールドとその非空・`applies_to` の解決・`when` は `visibility` のみ・required への `fix` 必須・`fix` と `fix_kind` の対・破壊的な `fix` への `destructive` 宣言・`why` の存在。0006 決定 5 の「正本側のテストが守る」をこのリポジトリ側へ移す
  4. 正本が解決できないときの案内を「setup リポのセットアップ」から「プラグインの入れ直し」へ変える。同梱後にこの状態へ至るのは配布が壊れているときだけである

- **影響**: 標準のデータを変えるたびにプラグインの version bump が要るようになる (0006 が挙げた身軽さは失われる)。これは受け入れる — 引き換えに、標準とそれを解釈するコードがバージョンを共にするので「新しい標準を古い解釈器が読む」ズレが構造的に消え、契約違反は CI で落ちる。

  `upstream-refs.json` から `shinyaoguri/setup` の `claude/repo-standards.json` を外す (週次 freshness の検査対象でなくなる)。setup 側は `claude/repo-standards.json` と `claude/tests/repo_standards_test.py` を削除し、`tasks/claude.yml` の `claude_config_files` からも外す。**同梱側を先にリリースし、setup 側の削除は後**にする (古いプラグインを持つマシンが正本を見失わないため)。既存マシンには dangling な `~/.claude/repo-standards.json` が残るので、env-doctor の「正本が解決できるか」の検査を「stale な symlink が残っていないか」へ寄せる。

  この決定は `repo-standards.json` だけを動かす。setup の `claude/` に残るフック群 (`git-safety-guard.sh` ほか) をプラグイン層へ移すかは別の判断で、[shinyaoguri/setup#127](https://github.com/shinyaoguri/setup/issues/127) が引き続き扱う — ガードを marketplace の更新経路に乗せてよいかという固有の論点があるため。
