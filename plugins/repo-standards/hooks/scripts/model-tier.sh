#!/usr/bin/env bash
# SessionStart / PostModelSwitch hook — セッションを動かすモデルの格を判定し、身の丈を伝える。
#
# 規約もフックもモデルを区別しないので、軽いモデルに投げても設計判断を自分で下したまま
# 実装が進みうる (shinyaoguri/claude-plugins#207)。しかも軽いモデルほど「自分に何が
# 分からないか」に気付きにくく、**自己申告に頼る仕組みはいちばん止まってほしい場面で
# 止まらない**。だから格はここで機械的に決め、2 つの使い道へ渡す:
#
#   1. 中・低の格には、引き受けてよいもの / 自分で決めないもの / 当たったときの出口を
#      additionalContext で伝える (SessionStart のときだけ)
#   2. セッション単位の印を置き、plan-pass.sh (プランの自動承認) と next-task スキル
#      (候補の選定) が読む。PermissionRequest の入力には model が載らないため
#
# ## 格
#
#   model に haiku を含む → low / sonnet → mid / opus・fable → high
#   それ以外・model が無い → 判定しない (印を消し、何も出さない)
#
# 判定できないものを low に倒さないのは、本体が model を省く場面 (/clear 後など) で
# 上位モデルの自動承認まで止めてしまうため。止めそこねても失うのは人がプランを見る
# 機会だけで、取り返しはつく (plan-gate.sh と同じく静かな側へ倒す)。
#
# 契約: stdin に SessionStart (.model) か PostModelSwitch (.to_model) の JSON。
# 出力は SessionStart で中・低のときだけ hookSpecificOutput.additionalContext、常に exit 0。
# PostModelSwitch は出力の契約を確かめていないので、印を書き換えるだけで何も出さない
# (途中で格が下がっても指示は届かないが、印を読む plan-pass は効く — ADR 0031)。
# 呼び出し口は hooks/hooks.json、テストは scripts/test-rs-model-tier.sh。
set -uo pipefail

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

session=$(printf '%s' "$input" | jq -r '.session_id // ""')
[ -n "$session" ] || exit 0
event=$(printf '%s' "$input" | jq -r '.hook_event_name // ""')
model=$(printf '%s' "$input" | jq -r '.to_model // .model // ""')

# 逃げ道と上書き。0 で判定ごと止め、high|mid|low でモデルに依らず格を固定する
override=${RS_MODEL_TIER:-}
[ "$override" = "0" ] && exit 0

case "$override" in
  high | mid | low) tier="$override" ;;
  *)
    lower=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
      *haiku*) tier=low ;;
      *sonnet*) tier=mid ;;
      *opus* | *fable*) tier=high ;;
      *) tier="" ;;
    esac
    ;;
esac

# 印の置き場は cwd を見ない (格はセッションの事実。plan-gate-mark.sh と同じ理由)
dir="${RS_MODEL_TIER_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/model-tier}"
mkdir -p "$dir" 2>/dev/null || exit 0
mark="$dir/$session.tier"
if [ -z "$tier" ]; then
  rm -f "$mark" 2>/dev/null
  exit 0
fi
printf '%s\n' "$tier" > "$mark" 2>/dev/null
find "$dir" -type f -name '*.tier' -mtime +30 -delete 2>/dev/null

[ "$event" = "SessionStart" ] || exit 0
[ "$tier" = "high" ] && exit 0

if [ "$tier" = "mid" ]; then
  label="中"
  take="完了条件が人の手で固まった (トリアージ済みの) Issue のうち、直し方が 1 通りに決まる Bug・Task・Docs。結論だけ要る定型の調査・読み取り。"
  plan_note="この格では、Issue Type が Design のプランは自動承認されず人がプランを見る。"
else
  label="低"
  take="機械的な作業だけ (定型の置換・読み取り・集計・決まった手順の実行)。判断を伴う実装は上位のモデルへ渡す。"
  plan_note="この格では、トリアージ済みの Issue でもプランは自動承認されず人がプランを見る。"
fi

context="[repo-standards] このセッションのモデルは ${model:-不明} で、格は「${label}」。身の丈に合うタスクだけを引き受ける。

- 引き受けてよい: ${take}
- 自分で決めない: Issue Type が Design のもの / 選択肢が複数あり意図に依存するもの / 公開 API の意味・互換性・原則の選択 / 完了条件そのものを決めること / 複数のリポジトリに跨る変更 / リポジトリの規約が「人が先に判断する」と定めたもの。
- 当たったときの出口 (どちらかを取り、黙って自分で決めない):
  1. 判断だけを切り出せるなら、Agent ツールに model: \"opus\" を渡し、材料と問いを渡して選択肢・推奨・根拠を返させる。結論は根拠ごと Issue に記録してから続ける。
  2. 切り出せない・委ねても決まらないなら、限界報告 (確かめたこと / 決められなかった点とその理由 / 誰が何を決めれば進められるか) を Issue にコメントし、着手印を外して作業を終える。
- 依頼そのものが格に合わなければ、着手する前にそう伝えて上の出口を選ぶ。${plan_note}"

jq -n --arg c "$context" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
exit 0
