---
name: repo-bootstrap
description: "新規リポジトリを個人標準 (setup リポの repo-standards.json) どおりに対話的に雛形生成する。構成ファイルの生成 → 初回コミット → GitHub 作成と設定適用まで。Use when creating a new repository or initializing an existing directory to personal standards."
argument-hint: "[path] [--kind <swift|web|python|generic>]"
allowed-tools: "Bash(jq:*), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-github.sh:*), Bash(bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-min.sh:*)"
---

新しいリポジトリの雛形を個人標準どおりに作る。既存リポの監査は /repo-audit を使う (このスキルは生成が目的)。

**コミットが 1 件も無いリポは監査側から渡されて来る** — repo-audit / repo-audit-min は `repo-uninitialized` で判定を打ち切り、このスキルを次の一手として指す。その経路では `git init` が済んでいるので手順 3 の初期化を飛ばす。

## 手順

1. 正本を読み、リポ種別を決める。`--kind` 指定が無ければ選択肢を提示して 1 問だけ聞く:

   ```bash
   jq -r '.kinds[].id' ~/.claude/repo-standards.json    # 種別の選択肢 (正本から動的に取得)
   ```

   正本が無ければ setup リポのセットアップ (`ansible-playbook --tags claude`) を案内して終了する
2. `level: required` の全項目と、該当種別に適用される `recommended` 項目を列挙し、生成するファイル一覧 (`.gitignore`・README.md・CLAUDE.md・CI・テンプレート等) を提示して確認を取る:

   ```bash
   jq -r --arg k <kind> '.items[] | select(.applies_to | index("all") or index($k))
     | select(.level != "rejected") | [.level, .id, .fix // ""] | @tsv' ~/.claude/repo-standards.json
   ```

   **生成に要る材料もこのとき 1 回でまとめて聞く** — リポの目的 (README の 1 行)、検証コマンド (CLAUDE.md と CI に載る)、LICENSE (既定は MIT)。marker ファイルすら無い段階なのでリポから読めるものはほぼ無く、聞かずに書くと見出しだけの雛形になる。答えが得られなかった項目は生成せず、後から /repo-audit-fix で埋める

3. `git init` (default branch は main。**既に init 済みなら飛ばす**) → 各項目の `fix` の方針に沿ってファイルを生成 → 初回コミット。新規リポなのでこの初回コミットだけ main 直コミットでよい

   - **既にある未追跡ファイルは上書きしない** — 生成対象と同名のファイルがあれば、その中身を材料として足りない節を書き足す
   - **ディレクトリだけ作らない** — git は空ディレクトリを追跡しないので、`docs/decisions/` やテストディレクトリは中身と一緒に作る (でないと初回コミットに乗らず、直後の確認で未整備のまま出る)
4. ユーザーが望めば `gh repo create` + push し、`bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-github.sh` の NG 項目の fix コマンドを提示 → 承認後に適用する
5. 仕上げに簡易監査で green を確認する (判定ロジックをここに複製しない):

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/rs-audit-min.sh
   ```

   逸脱が残っていれば項目を示し、対処は /repo-audit へ渡す。**生成直後に本監査 (repo-audit) は回さない** — 標準どおりに作った直後で逸脱はほぼ無く、反証まで通す本監査を通すコストに見合わない

   **`BLOCK` 行 (前提未達で未判定) が出たら、見送った項目と一緒に持ち越し先へ書く**。手順 2 で生成を見送った項目 (技術スタック未確定で CI を作らない等) があると、それに依存する `level: required` の項目が判定されないまま残る。前提を埋めたときに拾い直す契機はこの持ち越しにしか無い (CI を後から足しても、誰も `gh-required-checks` を見に行かない — issue #97 の実害)。持ち越しには**前提の id と、前提を埋めた後に /repo-audit を回すこと**まで書く

## 詳細の在処

- チェックリストの正本と各項目の生成方針 (`fix`): `~/.claude/repo-standards.json` (実体は shinyaoguri/setup の claude/repo-standards.json)
- CLAUDE.md に書くべき内容の判断基準: 正本の `claude-md-quality` 項目の prompt

このスキル自体の不具合・使いにくさに気付いたら、report-issue スキルで shinyaoguri/claude-plugins へ気軽に起票する。
