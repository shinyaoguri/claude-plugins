# 0006: repo-standards の正本は setup リポに置き、~/.claude の symlink 経由で解決する

- **状態**: 採用 (2026-08-03)
- **文脈**: repo-standards プラグイン (リポ構成・GitHub 設定・Claude 設定の監査) には「自分好み」のチェックリストが必要だが、プラグイン本文に持つと setup リポのグローバル CLAUDE.md と二重記述になりドリフトする (ADR 0001 と同じ問題)。また判定を SKILL.md の指示だけに置くと実行ごとに指摘がブレる。
- **決定**:
  - チェックリストの正本は shinyaoguri/setup の `claude/repo-standards.json` 単一ファイルとする。人間向けの根拠は `why` フィールドに埋め込み、Markdown との 2 ファイル管理はしない。項目の増減・変更は setup リポへの PR で行う
  - プラグイン側は薄いルーターに徹する: 同梱スクリプト (rs- プレフィックス) が正本を `$REPO_STANDARDS_JSON` → `~/.claude/repo-standards.json` (ansible が張る symlink) → `~/.setup/claude/...` の順で解決し、決定論的チェックを JSON Lines で報告する。意味判定 (CLAUDE.md の質など) だけ `check.type: llm` として素通しし、SKILL.md 側で判定する
  - スクリプトはレポートツールでありゲートではないので、チェック結果によらず exit 0 とする (異常終了はスクリプト自体の破損のみ)
  - 同梱スクリプト名は `rs-` プレフィックスで統一し、check-upstream-refs.sh の ignore_re で除外する (token_re の `scripts/*.sh` パターンが SKILL.md 内の `${CLAUDE_PLUGIN_ROOT}/scripts/` 参照を上流参照と誤検出するため)
  - `check.type` / `builtin` 名は正本とスクリプトのクロスリポ契約。正本側のテスト (setup の repo_standards_test.py) がスキーマを守り、未実装 builtin はスクリプトが skip として報告する (黙って落とさない)
- **影響**: upstream-refs.json に shinyaoguri/setup を追加し、週次 freshness が正本の実在を検査する (このため setup 側 PR を先にマージする)。基準を変えたいときに触るのは setup リポのみで、プラグインの version bump は不要 (スクリプトの挙動が変わるときだけ bump)。正本が無いマシンでは監査は打ち切り報告になり、env-doctor のビルトイン検査だけが動く。
