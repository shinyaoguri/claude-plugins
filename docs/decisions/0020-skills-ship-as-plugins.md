# 0020: 汎用スキルは plugin として配り、グローバルスキルは使わない

- **状態**: 採用 (2026-08-16)

- **文脈**: 「スキルは自分しか使わないのだから、marketplace のプラグインではなく [setup](https://github.com/shinyaoguri/setup) リポのグローバルスキル (`~/.claude/skills/`) として管理したほうが楽ではないか」という問いが出た。marketplace 運用には version bump・[upstream-refs.json](../../upstream-refs.json) の網羅検査・ADR といった手続きが伴う一方、setup リポは `~/.claude` への symlink なので `git pull` だけで全マシンへ反映される。

  グローバル CLAUDE.md には既に「汎用スキルは marketplace のプラグインとして配布し、`~/.claude/skills/` には実体も symlink も置かない」と書いてあるが、**その根拠はどこにも記録されていない**。[0009](0009-plugin-granularity.md) が答えているのはプラグイン*間*の粒度であって、「そもそも plugin として配るか」は未記録だった。

  検討で分かったこと:

  - **skill 単体では hooks・agents・scripts を配れない**。実測すると `repo-standards` は skill 7 + hook 5 + agent 4 + scripts、`metaphor-sketch` は skill 4 + SessionStart hook 1 を同梱しており、skills だけで完結するのは `metaphor-contrib` のみ。グローバルスキル化すると 1 つの関心事が `~/.claude/skills/` (スキル) と `~/.claude/agents/` (エージェント) と `settings.json` (フック登録) の 3 か所へ散る。これは [0016](0016-agent-behavior-hooks-in-plugin.md) が「フックはリポにコミットせずプラグインが束ねる」と決めた問題の裏返しで、**プラグインの実体は skill + hook + agent + script を 1 単位に束ねる入れ物**のほうにある
  - **enable/disable の単位が消える**。グローバルスキルは常時全プロジェクトで有効になる。`metaphor-*` の 10 スキルは metaphor を触らないセッションでは description の重りにしかならず、[0009](0009-plugin-granularity.md) の「片方だけ無効にしたい環境がある」に真正面から当たる
  - **version をまたいだ伝搬制御を失う**。setup リポは symlink なので `git pull` した瞬間に全マシンが即時・無警告で入れ替わる。[0003](0003-version-policy.md) の「bump しないマージは伝搬しない」は不便ではなく、壊れた変更を止める安全弁として働いている
  - **体感の重さの出どころは marketplace ではない**。version bump は [scripts/bump-version.sh](../../scripts/bump-version.sh) 一発で、残りの手続き (薄いルーター検査・非推奨パターン・freshness) はこのリポが自分に課したもの。setup へ移しても同じ検査が要るなら重さは移動するだけで、要らないと判断するなら今の場所でも外せる

  この基準で移設候補を探すと 1 つも出てこない。最も「常時オン」の `repo-standards` は同梱物が多すぎてプラグインでないと配れず、最も「切りたい」`metaphor-*` はプラグインの利点そのもの。`metaphor-contrib` だけは skills のみだが、`metaphor-sketch` と対で有効・無効を切り替える関係にあり単独で例外にする意味は薄い。

- **決定**:

  1. **汎用スキルの供給先は claude-plugins の plugin 一択**とする。`~/.claude/skills/` には実体も symlink も置かない (グローバル CLAUDE.md の既存規約を、この ADR が根拠づける)
  2. **setup リポが持つのは、プラグインからは供給できない層に限る** — `settings.json` (`permissions` / `autoMode` / `enabledPlugins` / `extraKnownMarketplaces`)、プラグイン層の生死に依存させたくない PreToolUse ガード (`git-safety-guard.sh` ほか)、標準の正本である `repo-standards.json` ([0006](0006-repo-standards-source-of-truth.md))。プラグインを全部無効にしても効き続ける必要があるものがここに来る
  3. **plugin 側へ置く判断基準**は次の 3 つで、1 つでも当たれば plugin とする: **hooks・agents・scripts を伴う** / **enable・disable の単位を持つ** / **version をまたいで伝搬を制御したい**
  4. 3 基準のいずれにも当たらないスキルが生まれたときに、この判断を再議論する

- **影響**: [0009](0009-plugin-granularity.md) がプラグイン*間*の粒度を決めるのに対し、この ADR はその一段上 —「plugin として配るか否か」— を決める。月次の [portfolio-review](../../.claude/skills/portfolio-review/SKILL.md) で新設・統廃合を判断するときは、まずこの 3 基準で plugin 化の可否を見てから 0009 の粒度に進む。

  この決定は「自分しか使わない」前提の下でも成り立つ点が肝で、marketplace を選ぶ理由を配布 (他人に配る) に置いていない。したがって将来スキルを公開する・しないの判断が変わっても、この ADR を見直す必要はない。
