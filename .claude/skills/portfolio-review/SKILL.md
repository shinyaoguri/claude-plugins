---
name: portfolio-review
description: "claude-plugins marketplace の月次俯瞰レビュー。Claude の利用状況からプラグインの新設・統廃合を提案し、SKILL.md と上流 docs の意味的ドリフト、および仕組み自体 (CLAUDE.md・CI・スクリプト・本スキル) の陳腐化を点検して Issue 起票する。Use for the monthly portfolio review of this plugin marketplace, when asked to review plugin usage, propose new plugins or consolidation, or audit the maintenance machinery itself."
---

# marketplace の月次俯瞰レビュー

週次の機械チェック (freshness.yml) が捉えない「意味のずれ」と「構成の最適性」を人間+AI で点検する。結論はチャットに書き捨てず、必ず Issue へ残す。

## 前提

- このリポジトリ (shinyaoguri/claude-plugins) の checkout で実行する
- 提案の判断材料になるので、開始時に `gh issue list --state open` と `gh issue list --label freshness --state all --limit 10` で未対応の検知・提案を把握する

## 手順

### 1. 利用状況の棚卸し (新設候補の発掘)

- ローカルのセッション履歴 (`~/.claude/projects/` 配下の各プロジェクト) をディレクトリの更新時刻で概観し、直近 1 ヶ月にどのプロジェクトでどんな作業をしたかを把握する。`/insights` が使える環境なら併用する
- 探すもの: **複数セッションで繰り返している手作業・定型プロンプト・毎回思い出させている知識**。それがスキル/プラグイン化の候補
- 候補の置き場は配置方針に従う: 複数プロジェクト横断 → marketplace の新プラグイン / 特定リポ固有 → そのリポの `.claude/skills/` (marketplace に入れない)

### 2. 既存プラグインの有効性 (統廃合候補の抽出)

- 各プラグイン (marketplace.json の一覧) について、直近 1 ヶ月で実際に発火・参照された形跡があるかをセッション履歴から確認する
- 使われていない・記述が実作業とずれている・2 つのスキルが常に同時に読まれている、などがあれば統合・廃止・降格の候補にする

### 3. 意味的ドリフトの点検

- 機械チェックは「参照先が存在するか」しか見ない。ここでは**内容**を見る: 各 SKILL.md が要約している上流の挙動・手順・表 (例: リリース bump の判定表、生成物の一覧) を、上流リポの現物と突き合わせる
- 上流の直近の変更は `gh api repos/shinyaoguri/<repo>/commits --jq '.[].commit.message'` や release notes で把握できる
- 疑いがあれば上流の該当ドキュメントを読み、ずれていれば「ドリフト報告」テンプレートで起票する

### 4. 仕組み自体のメタレビュー (自己改善)

- CLAUDE.md・README・`scripts/`・workflows・本スキルが実態と乖離していないかを確認する。CLAUDE.md の監査には md-maintainer スキルがあれば使う
- この 1 ヶ月で「守られなかったルール」「CI が見逃した問題」「同種の問題の 2 回目」がなかったかを振り返る。あれば文書ルールでなく仕組み (CI・hooks・スクリプト) への昇格を検討して起票する
- Dependabot PR・freshness Issue が放置されていないかを確認する

### 5. 起票と終了

- 提案は 1 件 1 Issue。起票前に `gh issue list --search "<キーワード>"` で重複を確認し、種別に応じたテンプレート (改善提案 / ドリフト報告 / プラグイン新設・統廃合の提案) の構成に沿って本文を書く
- 判断に迷う統廃合はユーザーに相談し、決めきれないものも「検討中」として Issue に残す (チャットにだけ残すことを禁ずる)
- 提案が 1 件もなければ起票せず、レビュー実施の旨だけ報告して終了する
