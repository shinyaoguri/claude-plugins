#!/usr/bin/env bash
# 監査結果 (findings) の永続化・更新・集計。repo-audit → repo-audit-fix の受け渡しの正本。
# LLM に JSON を手で編集させないための決定論的な口。要 jq。
#
#   { bash rs-audit-repo.sh; bash rs-audit-github.sh; } | bash rs-findings.sh save
#   bash rs-findings.sh list [--status ng,warn] [--decision pending] [--layer repo]
#                            [--level required] [--needs-verdict] [--needs-verify]
#                            [--needs-intent-check] [--intent conflicts]
#   bash rs-findings.sh set --decision approved <id>...
#   bash rs-findings.sh set --verdict warn --evidence "..." [--source min|full] <id>
#   bash rs-findings.sh set --verified --evidence "反証の結果..." <id>
#   bash rs-findings.sh set --intent conflicts --intent-note "衝突の理由..." <id>
#   bash rs-findings.sh summary
#   bash rs-findings.sh path
#
# 保存先: <git common dir>/rs-audit/findings.jsonl。.git 配下なのでコミットに混入せず
# worktree も汚さない (dirty 判定を伴う修正フローと衝突しない)。worktree からでも
# --git-common-dir でリポジトリ本体を指すため、監査対象と結果が 1 対 1 に保たれる。
#
# 行スキーマ = rs-audit-*.sh の出力 (rs-lib.sh 冒頭) に以下を足したもの:
#   verdict   LLM 判定 (ok / warn / ng / skip)。manual 項目の判定に加え、機械判定の
#             ng / warn を偽陽性として覆すのにも使う (下記)
#   verdict_source  その判定を下した層。full (本監査: 項目ごとの判定 + 実ファイル読み)
#             / min (簡易監査: 畳んだ材料で安いモデルが一括判定した暫定値)。
#             省略された古い行は full とみなす
#   evidence  その判定の根拠。verdict を書くときは必須 (下記)
#   head      verdict を付けたときの HEAD。現在の HEAD と違えば判定は陳腐化したとみなす
#   verified  独立した判定者による反証を通ったか。verdict を書き換えると落ちる
#   intent    その指摘の fix を当てたとき、リポ自身が明示している設計意図と衝突するか
#             aligned (衝突しない) / unclear (判断がつかない) / conflicts (衝突する)
#   intent_note  その判断の理由
#   decision  pending (未決) / approved (適用してよい) / rejected (直さないと決めた)
#             / applied (適用済み) / deferred (今回は見送り。Issue へ引き継ぐ)
#   note      decision の理由
#
# intent は verdict を上書きしない。標準に合っていないという事実 (ng / warn) と、
# それがこのリポでは正しい逸脱かもしれないという文脈は別物で、後者で前者を消すと
# 「標準から外れている」こと自体が見えなくなる。intent は repo-audit-fix が
# 適用の扱いを変えるための材料として載る。
#
# 判定を記録するときの決定論的な制約 (文書ルールでなくここで強制する):
#   - **verdict には evidence が必須**。20 バイト以上を求める (「ok」「問題なし」のような
#     接地しない根拠を弾くため。日本語なら 7 文字程度)。後から検証できない判定を
#     監査記録に残さないのが目的
#   - **manual 項目の verdict が ok / skip になったら decision と intent を落とす**。
#     直すものが無いのに未決として残ると、repo-audit-fix が承認の要らない項目まで
#     並べることになる。**機械判定 (status が ng / warn) の行では落とさない** —
#     そこでの verdict ok は「機械判定が偽陽性だった」という異議であって、
#     status が示す事実は消えない。なぜ直さないのか (decision / note / intent) を
#     残せないと、機械判定と LLM 判定が食い違ったケース (監査が一番価値を出す場面)
#     だけ記録が揮発する
#   - **min の verdict は full の verdict を上書きしない**。安い層 (畳んだ材料 +
#     安いモデル + ファイル 3 件まで) の暫定判定が、本監査の判定を無警告で
#     置き換えるのを防ぐ。陳腐化した full (HEAD が進んだもの) は上書きしてよい。
#     min の verdict は常に再判定の対象 (--needs-verdict) に残り、反証待ちには数えない
#   - **verdict を書き換えると verified は落ちる**。反証済みの判定が、再判定後も
#     反証済みに見えるのを防ぐ
#   - **未知の id を含む set は非 0 で拒否し、1 件も書き込まない**。警告だけで成功を
#     返すと、typo した書き戻しが成功したように見えて未決のまま取り残される
set -uo pipefail
. "$(dirname "$0")/rs-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "rs-findings: jq が必要 (brew install jq)" >&2; exit 2; }

usage() {
  sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# 根拠として最低限の接地を求めるバイト数。文字数でなくバイトで測るのは、bash の
# ${#var} も wc -m もロケール依存で、CI (LANG=C) と開発機で基準がずれるため
MIN_EVIDENCE_BYTES=20

# 保存ディレクトリ。worktree では .git がファイルなので --git-common-dir で本体を引く
findings_dir() {
  local top d
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  d=$(cd "$top" && git rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$d" in /*) ;; *) d="$top/$d" ;; esac
  printf '%s/rs-audit\n' "$d"
}

head_now() { git rev-parse --short HEAD 2>/dev/null || echo ""; }

# findings が無い / 空のときに読んでも落ちないよう空配列を返す。
# jq -s は不在ファイルに対し stdout へ [] を出しつつ非 0 で終わるので、
# `|| echo '[]'` 形式にすると出力が二重になり --argjson が壊れる
load() {
  local out
  if out=$(jq -s '.' "$file" 2>/dev/null); then printf '%s\n' "$out"; else echo '[]'; fi
}

cmd=${1:-}
[ -n "$cmd" ] || usage
shift || true

dir=$(findings_dir) || {
  # git リポ外。save は stdin を素通しして保存だけ諦める (監査自体は続けられる)
  [ "$cmd" = save ] && cat
  emit findings-store meta required skip "git リポジトリではないため findings を保存できない"
  exit 0
}
file="$dir/findings.jsonl"
metafile="$dir/meta.jsonl"

# ---- save: 監査出力を保存する。前回の判断を id 単位で引き継ぐ ----
# 引き継ぐのは status が前回と一致する行だけ。status が変わった項目 (直った・悪化した) は
# 判断をやり直すべきなので pending に戻す。これで再監査しても承認履歴が積み上がり、
# かつ古い承認が現状と食い違ったまま残らない。
cmd_save() {
  mkdir -p "$dir"
  local input prev
  input=$(cat)
  printf '%s\n' "$input"          # レポート材料としてそのまま流す

  printf '%s\n' "$input" | jq -c 'select(.id == "_meta")' > "$metafile.tmp" \
    && mv "$metafile.tmp" "$metafile"

  prev=$(load)
  printf '%s\n' "$input" | jq -c --argjson prev "$prev" '
    select(.id != "_meta" and .id != "_next" and (.id != null))
    | . as $new
    | (($prev | map(select(.id == $new.id)))[0] // {}) as $old
    | $new
      + (if ($old.status // "") == $new.status
         then ({verdict: $old.verdict, verdict_source: $old.verdict_source,
                evidence: $old.evidence, head: $old.head,
                verified: $old.verified, intent: $old.intent, intent_note: $old.intent_note,
                decision: $old.decision, note: $old.note}
               | with_entries(select(.value != null)))
         else {} end)
    # 実効 status: manual に判定が付いていれば判定の方が実態を表す
    | (if .status == "manual" and (.verdict // "") != "" then .verdict else .status end) as $eff
    | if .status == "manual" then
        # 未判定の manual は「まだ決められない」ので未決に置く。判定が ng / warn なら
        # 直すかどうかの判断が要るので未決。ok / skip は判断すること自体が無い
        (if $eff == "ng" or $eff == "warn" or ((.verdict // "") == "")
         then (if has("decision") then . else . + {decision: "pending"} end)
         else del(.decision, .note) end)
      elif .status == "ng" or .status == "warn" then
        (if has("decision") then . else . + {decision: "pending"} end)
      # 標準に適合した項目に衝突判断が残っていると、次の逸脱時に古い理由が付いて回る。
      # manual 行の verdict が ok / skip へ変わる経路は cmd_set 側で落としている
      else del(.decision, .note, .verdict, .evidence, .head, .verified, .intent, .intent_note) end
  ' > "$file.tmp" && mv "$file.tmp" "$file"

  cmd_summary
}

# ---- list: 条件で絞って JSON Lines を返す ----
cmd_list() {
  local status="" decision="" layer="" level="" intent="" needs=0 verify=0 intentchk=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --status) status=${2:-}; shift 2 ;;
      --decision) decision=${2:-}; shift 2 ;;
      --layer) layer=${2:-}; shift 2 ;;
      --level) level=${2:-}; shift 2 ;;
      --intent) intent=${2:-}; shift 2 ;;
      --needs-verdict) needs=1; shift ;;
      --needs-verify) verify=1; shift ;;
      --needs-intent-check) intentchk=1; shift ;;
      *) echo "rs-findings: 不明な引数: $1" >&2; exit 2 ;;
    esac
  done
  [ -f "$file" ] || return 0
  # 行を $r に束縛してから絞る。`split(",") | index(.status)` と書くと index の中の
  # `.` がパイプ左の配列を指してしまい "Cannot index array with string" で落ちる
  jq -c --arg s "$status" --arg d "$decision" --arg l "$layer" --arg lv "$level" \
        --arg it "$intent" --arg head "$(head_now)" \
        --argjson needs "$needs" --argjson verify "$verify" --argjson intentchk "$intentchk" '
    . as $r
    | (if $r.status == "manual" and ($r.verdict // "") != "" then $r.verdict else $r.status end) as $eff
    | select($s == "" or (($s | split(",")) | index($eff)))
    | select($d == "" or (($d | split(",")) | index($r.decision // "")))
    | select($l == "" or (($l | split(",")) | index($r.layer)))
    | select($lv == "" or (($lv | split(",")) | index($r.level)))
    # 再判定待ち: 未判定・陳腐化したもの、および min の暫定判定 (本監査では必ず
    # 判定し直す。安い層の判定を本監査の結論として残さないための引き戻し)
    | select($needs == 0 or ($r.status == "manual"
        and (($r.verdict | not) or ($r.head != $head) or (($r.verdict_source // "full") == "min"))))
    # 反証待ち: 判定が付いていて陳腐化しておらず、まだ反証を通っていないもののうち、
    # 誤判定の代償が大きいもの (required の項目、および ng / warn と判定したもの)。
    # 陳腐化した判定は --needs-verdict 側が再判定に引き戻すのでここでは拾わない。
    # min の暫定判定も同様 (反証にかける前に本監査の判定へ置き換わる)
    | select($verify == 0 or (
        $r.status == "manual" and ($r.verdict // "") != "" and ($r.head == $head)
        and (($r.verdict_source // "full") == "full")
        and (($r.verified // false) | not)
        and ($r.level == "required" or $eff == "ng" or $eff == "warn")))
    | select($it == "" or (($it | split(",")) | index($r.intent // "")))
    # 衝突判定待ち: 標準から外れている項目のうち、まだ意図と突き合わせていないもの。
    # 機械判定の ng / warn も対象に含む — LLM が文脈を持ち込める唯一の接点なので
    | select($intentchk == 0 or (
        ($eff == "ng" or $eff == "warn") and (($r.intent // "") == "")))
  ' "$file"
}

# ---- set: 判定・判断を書き込む ----
cmd_set() {
  local decision="" verdict="" evidence="" note="" intent="" intent_note="" verified=0 ids="" id
  local source="full"
  while [ $# -gt 0 ]; do
    case "$1" in
      --decision) decision=${2:-}; shift 2 ;;
      --verdict)  verdict=${2:-};  shift 2 ;;
      --source)   source=${2:-};   shift 2 ;;
      --evidence) evidence=${2:-}; shift 2 ;;
      --note)     note=${2:-};     shift 2 ;;
      --intent)      intent=${2:-};      shift 2 ;;
      --intent-note) intent_note=${2:-}; shift 2 ;;
      --verified) verified=1;      shift ;;
      --*) echo "rs-findings: 不明な引数: $1" >&2; exit 2 ;;
      *) ids="$ids $1"; shift ;;
    esac
  done
  [ -n "$ids" ] || { echo "rs-findings: 対象の id を 1 つ以上指定する" >&2; exit 2; }
  [ -f "$file" ] || { echo "rs-findings: findings が無い (先に save する)" >&2; exit 2; }

  # 値の綴りを固定する (typo で承認状態が壊れるのを防ぐ)
  case "$decision" in
    ""|pending|approved|rejected|applied|deferred) ;;
    *) echo "rs-findings: decision は pending/approved/rejected/applied/deferred のいずれか: $decision" >&2; exit 2 ;;
  esac
  case "$verdict" in
    ""|ok|warn|ng|skip) ;;
    *) echo "rs-findings: verdict は ok/warn/ng/skip のいずれか: $verdict" >&2; exit 2 ;;
  esac
  case "$intent" in
    ""|aligned|unclear|conflicts) ;;
    *) echo "rs-findings: intent は aligned/unclear/conflicts のいずれか: $intent" >&2; exit 2 ;;
  esac
  case "$source" in
    min|full) ;;
    *) echo "rs-findings: --source は min/full のいずれか: $source" >&2; exit 2 ;;
  esac

  # 衝突の判断にも理由を必須にする。conflicts が理由なしで付くと、修正フローが
  # 「なぜ当てないのか」を説明できないまま項目を提示のみに落とすことになる
  if [ -n "$intent" ]; then
    local ibytes
    ibytes=$(printf '%s' "$intent_note" | wc -c | tr -d ' ')
    if [ "$ibytes" -lt "$MIN_EVIDENCE_BYTES" ]; then
      echo "rs-findings: --intent には --intent-note が必須 (${MIN_EVIDENCE_BYTES} バイト以上)。" >&2
      echo "  リポのどの記述と衝突する / しないのかを書く: CLAUDE.md の該当節・ADR 番号など" >&2
      exit 2
    fi
  fi

  # 判定には根拠を必須にする。接地しない判定を記録に残さないための決定論的なガードで、
  # 「後で書けばいい」を許すと結局書かれないまま次のセッションへ渡ることになる
  if [ -n "$verdict" ] || [ "$verified" -eq 1 ]; then
    local bytes
    bytes=$(printf '%s' "$evidence" | wc -c | tr -d ' ')
    if [ "$bytes" -lt "$MIN_EVIDENCE_BYTES" ]; then
      echo "rs-findings: 判定には --evidence が必須 (${MIN_EVIDENCE_BYTES} バイト以上、日本語で 7 文字程度)。" >&2
      echo "  何を見てそう判断したかを書く: ファイル名・行・コミット・Issue 番号など" >&2
      exit 2
    fi
  fi

  # 存在しない id は非 0 で拒否する。警告だけ出して成功を返すと、typo した書き戻しが
  # 成功したように見え、判定を付けたつもりの項目が未決のまま次のセッションへ渡る。
  # 1 件でも未知なら既知の id も含めて書き込まない (一部だけ通った状態を作らない)
  unknown=""
  for id in $ids; do
    jq -e --arg id "$id" 'select(.id == $id)' "$file" >/dev/null 2>&1 \
      || unknown="$unknown $id"
  done
  if [ -n "$unknown" ]; then
    echo "rs-findings: 未知の id:$unknown" >&2
    echo "  rs-findings.sh list で id を確認する (1 件でも未知なら何も書き込まない)" >&2
    exit 2
  fi

  # 安い層 (min) の判定は、陳腐化していない本監査 (full) の判定を上書きしない。
  # 未知 id と違ってこれは運用上の正当な分岐なので全体を拒否せず、該当 id だけ外して
  # 残りは書き込む (min の一括判定が 1 件の衝突で丸ごと落ちると triage にならない)
  local allids="$ids"
  if [ -n "$verdict" ] && [ "$source" = min ]; then
    local kept="" protected=""
    for id in $ids; do
      if jq -e --arg id "$id" --arg head "$(head_now)" '
            select(.id == $id and (.verdict // "") != ""
                   and ((.verdict_source // "full") == "full") and ((.head // "") == $head))
          ' "$file" >/dev/null 2>&1; then
        protected="$protected $id"
      else
        kept="$kept $id"
      fi
    done
    if [ -n "$protected" ]; then
      echo "rs-findings: 本監査 (full) の判定があるため min の判定は書き込まない:$protected" >&2
      echo "  上書きするには repo-audit で判定し直す (min の判定は暫定値として扱う)" >&2
    fi
    ids=$kept
  fi

  local idsjson alljson
  alljson=$(printf '%s\n' $allids | jq -R . | jq -sc .)
  if [ -z "${ids// /}" ]; then
    # 全件が full に保護された。書き込みはせず現状の行を返す (呼び出し側が結果を確認できる)
    jq -c --argjson ids "$alljson" '. as $r | select($ids | index($r.id))' "$file"
    return 0
  fi
  idsjson=$(printf '%s\n' $ids | jq -R . | jq -sc .)
  jq -c --argjson ids "$idsjson" --arg d "$decision" --arg v "$verdict" \
        --arg e "$evidence" --arg n "$note" --arg head "$(head_now)" \
        --arg it "$intent" --arg itn "$intent_note" --arg src "$source" \
        --argjson verified "$verified" '
    . as $r
    | if ($ids | index($r.id)) then
      # verdict を書き換えたら verified は一旦落とす。同じ呼び出しで --verified も
      # 渡されていれば直後に立て直る (判定と反証を 1 回で確定させる経路)
        (if $v != "" then (. + {verdict: $v, head: $head, verdict_source: $src} | del(.verified)) else . end)
      | . + (if $d != "" then {decision: $d} else {} end)
        + (if $e != "" then {evidence: $e} else {} end)
        + (if $n != "" then {note: $n} else {} end)
        + (if $verified == 1 then {verified: true} else {} end)
        + (if $it != "" then {intent: $it, intent_note: $itn} else {} end)
      # decision は判定に追従させる。repo-audit-fix は decision:pending を拾うので、
      # 直すものが無い判定を未決に残せば承認の要らない項目が並び、逆に反証で
      # ok → warn へ戻した項目を未決に復帰させないと修正フローから丸ごと落ちる
      # 衝突判断も同時に落とす。標準を満たしていると判定し直した項目に「意図と
      # 衝突するので当てない」が付いたままだと、同じセッションのレポートが
      # 「ok なのに衝突」という読めない行を出す (save まで待たせない)
      #
      # ただしこれは manual 項目に限る。機械判定 (status が ng / warn) の行に付いた
      # verdict ok は「機械判定が偽陽性だった」という異議で、status が示す事実は
      # 消えない。ここで decision / intent まで落とすと、なぜ直さないのかの根拠が
      # 書いた直後に消え、機械判定と LLM 判定が食い違ったケースだけ記録が揮発する
      | if .status != "manual" then .
        elif (.verdict // "") == "ok" or (.verdict // "") == "skip" then
          del(.decision, .note, .intent, .intent_note)
        elif (.verdict // "") == "ng" or (.verdict // "") == "warn" then
          (if has("decision") then . else . + {decision: "pending"} end)
        else . end
    else . end
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"

  # 更新後の行を返す (呼び出し側が結果を確認できる)。min で保護された id も含めて
  # 返し、書き込まれなかった行の現状が読めるようにする
  jq -c --argjson ids "$alljson" '. as $r | select($ids | index($r.id))' "$file"
}

# ---- summary: 集計と次アクション。監査を報告で終わらせないための _next 行 ----
cmd_summary() {
  [ -s "$file" ] || { jq -cn '{id:"_next",hint:"findings が空 (先に監査を実行する)"}'; return; }
  # 判定済みの manual 行は verdict を実効 status として数える
  # (判定して ng と分かった項目が集計から抜け落ちると、未対応の必須違反を見落とす)
  jq -sc --arg head "$(head_now)" '
    map(. + {_eff: (if .status == "manual" and (.verdict // "") != "" then .verdict else .status end)})
    # 未判定・陳腐化。min の暫定判定はここに数えない — 判定自体はあり、修正フローへは
    # 進めるため ($provisional として別に数え、本監査の再判定対象には --needs-verdict で残す)
    | (map(select(.status == "manual" and ((.verdict | not) or (.head != $head)))) | length) as $mp
    | (map(select(.decision == "pending")) | length) as $pending
    # 反証待ち。判定はあるが独立した検証を通っていない required / ng / warn
    # (min の暫定判定は本監査で判定し直されるので $mp 側に数える)
    | (map(select(.status == "manual" and ((.verdict // "") != "") and (.head == $head)
                  and ((.verdict_source // "full") == "full")
                  and ((.verified // false) | not)
                  and (.level == "required" or ._eff == "ng" or ._eff == "warn")))
       | length) as $unverified
    # 安い層の暫定判定。本監査を通せば full の判定に置き換わる
    | (map(select((.verdict // "") != "" and ((.verdict_source // "full") == "min")))
       | length) as $provisional
    # 機械判定の逸脱を LLM 判定が覆した項目。監査が一番価値を出す食い違いなので
    # 件数として見えるようにする (status が示す事実は消さない)
    | (map(select((.status == "ng" or .status == "warn")
                  and ((.verdict // "") == "ok" or (.verdict // "") == "skip")))
       | length) as $overridden
    | (map(select((._eff == "ng" or ._eff == "warn") and ((.intent // "") == "")))
       | length) as $intent_unchecked
    | (map(select(.intent == "conflicts")) | length) as $conflicts
    # 適用したのに status が変わらない項目。再監査で status が動けば decision は
    # 引き継がれず消えるので、ここに残るのは「直したつもりで直っていない」だけ
    | (map(select(.decision == "applied" and (._eff == "ng" or ._eff == "warn"))) | length) as $unresolved
    | {id: "_next",
       ng:       (map(select(._eff == "ng"))   | length),
       warn:     (map(select(._eff == "warn")) | length),
       manual_unjudged: $mp,
       provisional: $provisional,
       overridden: $overridden,
       unverified: $unverified,
       intent_unchecked: $intent_unchecked,
       conflicts: $conflicts,
       pending:  $pending,
       approved: (map(select(.decision == "approved")) | length),
       applied:  (map(select(.decision == "applied"))  | length),
       deferred: (map(select(.decision == "deferred")) | length),
       rejected: (map(select(.decision == "rejected")) | length),
       applied_unresolved: $unresolved,
       hint:
         ((if length == 0 then "findings が空 (先に監査を実行する)"
           elif $mp > 0 then "manual \($mp) 件が未判定 — 判定して rs-findings.sh set --verdict で記録する"
           elif $unverified > 0 then "反証待ち \($unverified) 件 — 独立した判定者に覆せるか確かめて set --verified で記録する"
           elif $intent_unchecked > 0 then "衝突判定待ち \($intent_unchecked) 件 — fix がリポの設計意図と衝突しないか確かめて set --intent で記録する"
           elif $unresolved > 0 then "適用済みだが解消していない項目が \($unresolved) 件 — 適用内容を見直す"
           elif $conflicts > 0 and $pending > 0 then "未決 \($pending) 件 (うち意図と衝突 \($conflicts) 件) — repo-audit-fix へ。衝突する項目は適用せず提示のみにする"
           elif $pending > 0 then "未決 \($pending) 件 — repo-audit-fix スキルで承認・適用できる"
           else "未決の指摘なし" end)
          # 暫定判定が残っていることは、どの段階にいても伝える (安い層の判定で
          # 修正まで進める設計なので、判定の質が違うことが見えないと混ざる)
          + (if $provisional > 0 then " / 暫定判定 \($provisional) 件 (min 由来。確度が要るなら repo-audit で判定し直す)" else "" end))}
  ' "$file"
}

case "$cmd" in
  save)    cmd_save ;;
  list)    cmd_list "$@" ;;
  set)     cmd_set "$@" ;;
  summary) cmd_summary ;;
  path)    printf '%s\n' "$file" ;;
  *)       usage ;;
esac
exit 0
