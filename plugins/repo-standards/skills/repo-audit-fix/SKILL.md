---
name: repo-audit-fix
description: "repo-audit が保存した findings をもとに、個人標準に適合していない項目を承認を取りながら修正する。リポ内ファイルの修正は 1 PR にまとめ、GitHub 設定は定義ファイル経由、破壊的操作は提示のみ。適用後に再監査して before / after を示す。Use when fixing repository standard violations, applying repo-audit findings, or resuming an unfinished standards fix."
---

repo-audit が保存した findings を入力に、承認された項目だけを適用する。findings があれば監査をやり直さずに再開できる。

## 前提の確認

```bash
P="${CLAUDE_PLUGIN_ROOT}/scripts"
bash "$P/rs-findings.sh" summary
```

- `findings が空` → 先に repo-audit スキルで監査する
- `manual N 件が未判定` → repo-audit の手順 2 (LLM 判定と書き戻し) を先に済ませる。未判定のまま進めると意味判定の項目が丸ごと落ちる
- worktree が dirty → 退避を促して中断する (適用は新しいブランチに載せるため)

## 手順

1. 未決項目を取る: `bash "$P/rs-findings.sh" list --decision pending`

2. fix の性質で群に分ける。承認の粒度が群ごとに違う:

   | 群 | 対象 | 進め方 |
   |---|---|---|
   | 1. 決定論的 | 内容が一意に決まるもの (設定ファイル・ワークフロー・テンプレートの配置) | まとめて 1 回承認し、コミットは type ごとに分ける |
   | 2. 生成的 | リポ固有の中身を書き起こすもの (README・CLAUDE.md・ADR・CONTRIBUTING) | 1 件ずつ内容を提示して承認し、1 件 1 コミット |
   | 3. 破壊的 | 削除・履歴の書き換え・ブランチ整理・追跡済み秘密ファイルの除去 | コマンドを提示するだけ。実行はユーザーに委ねる |

   項目に `fix_kind` があればそれに従い、無ければ fix の文面から上表で分類する。

   GitHub 設定 (`layer: github`) の扱い:
   - `.github/repo-settings.json` があるリポでは**群 1 に含める** — gh コマンドで直接変えず、定義ファイルの変更として PR に載せ、マージ後にそのリポの手順で適用する (承認が PR に一元化され、変更の根拠が diff に残る)
   - 定義ファイルが無いリポでのみ、各項目の `fix` の gh コマンドを全文提示し、承認後に実行する

3. 群ごとに番号付きで提示し、適用可否の承認を取る。承認されなかった項目も findings に記録してから次へ進む (記録しないと次のセッションで同じ確認を繰り返す):

   ```bash
   bash "$P/rs-findings.sh" set --decision rejected --note "<理由>" <id>...   # 直さないと決めた
   bash "$P/rs-findings.sh" set --decision deferred --note "<理由>" <id>...   # 今回は見送り
   ```

4. 承認された項目を適用する。`chore/repo-standards` ブランチを切り、群 1・2 をまとめて **1 PR** にする (標準適合が 1 関心事なので、項目ごとに PR は作らない)。

   コミットは Conventional Commits で、**type が変わるものは分ける** (構成ファイルの追加は chore、CI の追加は ci、ドキュメントの生成は docs)。決定論的 fix をすべて 1 コミットに押し込むと、何をなぜ変えたのかが追えず revert もできなくなる。本文には適用した項目 id と、その項目がある理由 (`why`) を列挙して監査由来の変更だと分かるようにする:

   ```
   chore(repo-standards): 標準の構成ファイルを追加する

   - gitignore-exists: リポ種別の生成物に合わせた .gitignore を追加
     (全リポジトリで唯一共通の必須ファイル)
   - pr-template-exists: .github/pull_request_template.md を追加
     (目的・変更点・確認方法の記入漏れを防ぐ)
   ```

   適用したら記録する:

   ```bash
   bash "$P/rs-findings.sh" set --decision applied <id>...
   ```

   生成的 fix が多く 1 PR の粒度を超えるときは、関心ごとに PR を分けて残りを `deferred` にする

5. 再監査して before / after を表で提示する:

   ```bash
   { bash "$P/rs-audit-repo.sh"; bash "$P/rs-audit-github.sh"; } | bash "$P/rs-findings.sh" save
   ```

   直った項目は status が変わり decision が自動で消える。`applied_unresolved` が残っていたら適用が効いていないので、その項目の fix を見直す。GitHub 設定を定義ファイル経由で直した項目は PR マージ + 適用の後でないと解消しないので、その旨を添えて残す

6. `deferred` が残っていれば、対象リポの Issue 1 件にまとめるかユーザーに確認する。findings はマシンローカル (`.git` 配下) で他マシンへ伝搬せず、リポを clone し直せば消えるため、持ち越しは GitHub 側へ移す

7. PR を作る。**findings は揮発するので、この PR 本文が適用の記録の正本**になる。次を載せる:

   - 適用した項目の表 (id | level | 何をしたか | why)
   - 見送った項目 (`deferred` / `rejected`) と理由。`deferred` は手順 6 の Issue へリンクする
   - 再監査の before / after (`summary` の `_next` 行の集計)
   - GitHub 設定を定義ファイル経由で直した項目があれば、マージ後に適用操作が要る旨

## 詳細の在処

- findings の保存先・行スキーマ・decision の意味: `${CLAUDE_PLUGIN_ROOT}/scripts/rs-findings.sh` 冒頭のコメント
- 各項目の根拠 (`why`) と fix の正本: `~/.claude/repo-standards.json` (実体は shinyaoguri/setup の claude/repo-standards.json)

このスキル自体の不具合・使いにくさに気付いたら、report-issue スキルで shinyaoguri/claude-plugins へ気軽に起票する。
