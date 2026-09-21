# 設計判断の記録 (軽量 ADR)

このリポジトリの確定した設計判断を 1 判断 1 ファイルで記録する。セッションのメモリがリセットされても、判断の背景と意図をここから復元できるようにするのが目的。

- ファイル名: `NNNN-短い説明.md` (連番)
- 構成: **状態** (採用/廃止 + 日付) / **文脈** (なぜ判断が必要だったか) / **決定** / **影響**
- 過去の判断を覆すときは古いファイルを消さず、状態を「廃止 (→ NNNN)」に変えて新しい ADR を足す

## 索引

**まず読むのは「現行」の 2 群だけでよい。** 状態欄が「一部廃止」のものは、現行として残る決定を状態欄に書いてある。ここに載っていない ADR があると `scripts/check-consistency.sh` が落ちる。

### リポジトリの運営 (現行)

| ADR | 決めたこと |
|---|---|
| [0003](0003-version-policy.md) | version の正は plugin.json だけ。変更と同じ PR で bump する (増分の強制は 0028 で廃止) |
| [0004](0004-deprecation-guard.md) | 公式が非推奨とするプラグイン構成を CI で禁止する |
| [0005](0005-dependabot-auto-merge.md) | Dependabot の patch / minor は CI green で自動マージ |
| [0008](0008-repo-settings-as-code.md) | GitHub のリポジトリ設定は `.github/repo-settings.json` が正本 |
| [0009](0009-plugin-granularity.md) | プラグインの粒度は enable / disable と version の単位で決める |
| [0020](0020-skills-ship-as-plugins.md) | 汎用スキルは plugin として配る |
| [0021](0021-three-layer-placement.md) | グローバル / plugin / リポジトリ — 置き場は「どこで発火する必要があるか」で決める |
| [0027](0027-intents-ledger-cross-repo-coverage.md) | 手段の存在理由は setup の意図の台帳に持ち、突き合わせは週次で見る |
| [0028](0028-detection-needs-closure.md) | 検知の層は「閉じる輪」を持つものだけを置く |

### repo-standards プラグインの設計記録 (現行)

| ADR | 決めたこと |
|---|---|
| [0022](0022-repo-standards-bundled.md) | 判定基準の正本 (repo-standards.json) はプラグインに同梱する |
| [0023](0023-drop-kinds-abstraction.md) | リポ種別による項目の出し分けを畳む |
| [0024](0024-level-semantics.md) | level は required / recommended の 2 値 |
| [0025](0025-cadence-bootstrap-vs-drift.md) | cadence で「設置して終わる項目」と「劣化する項目」を分ける |
| [0026](0026-machine-state-out-of-repo-audit.md) | マシン 1 台の事実は監査項目にしない |
| [0010](0010-audit-fix-handoff.md) | 監査と修正はスキルを分け、findings を受け渡しの正本にする |
| [0011](0011-audit-cost-tiers.md) | 監査はコストで階層を分ける (repo-audit-min / repo-audit) |
| [0012](0012-audit-precision.md) | 精度は「根拠の接地・材料の下限・独立した反証」で上げる |
| [0013](0013-standard-vs-repo-intent.md) | 標準は既定であり、リポ固有の設計意図との衝突を監査が判定する |
| [0014](0014-audit-on-demand.md) | 監査は起動されたときに走れば足り、定期実行はしない |
| [0015](0015-verdict-provenance.md) | 判定の出自を findings の行に持たせる |
| [0019](0019-blocked-vs-skip.md) | 前提未達の保留 (blocked) を恒久的な対象外 (skip) と分ける |
| [0016](0016-agent-behavior-hooks-in-plugin.md) | エージェントの振る舞いを縛るフックはプラグインが供給する |
| [0017](0017-approval-at-the-plan.md) | 人間の承認はプラン 1 点へ集約する (plan-gate / plan-pass) |
| [0018](0018-provable-branch-deletion.md) | ブランチの自動削除は「失われないと証明できる範囲」に限る |

### 一部廃止・置換済み (経緯を辿るとき用)

| ADR | 何が残り、何がどこへ移ったか |
|---|---|
| [0001](0001-thin-router.md) | 「プラグイン = 薄いルーター」は実態でなくなった (→ 0022)。「上流に正典があるものは複製しない」は現行 |
| [0002](0002-freshness-architecture.md) | 陳腐化防止の層。現行の層の表は [CLAUDE.md](../../CLAUDE.md) が正本。coverage は廃止 (→ 0028) |
| [0006](0006-repo-standards-source-of-truth.md) | 正本の置き場は 0022 へ。「レポートであってゲートではない」「`rs-` プレフィックス」は現行 |
| [0007](0007-guardrail-visibility.md) | 可視化レポートは廃止 (→ 0028)。権限側の決定 (`Administration` の剥奪だけ行う) は現行 |
