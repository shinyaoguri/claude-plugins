#!/usr/bin/env bash
# 監査結果 (findings) の永続化・更新・集計。repo-audit → repo-audit-fix の受け渡しの正本。
# LLM に JSON を手で編集させないための決定論的な口。要 jq。
#
#   { bash rs-audit-repo.sh; bash rs-audit-github.sh; } | bash rs-findings.sh save
#   bash rs-findings.sh list [--status ng,warn] [--decision pending] [--layer repo] [--needs-verdict]
#   bash rs-findings.sh set --decision approved <id>...
#   bash rs-findings.sh set --verdict warn --evidence "..." <id>
#   bash rs-findings.sh summary
#   bash rs-findings.sh path
#
# 保存先: <git common dir>/rs-audit/findings.jsonl。.git 配下なのでコミットに混入せず
# worktree も汚さない (dirty 判定を伴う修正フローと衝突しない)。worktree からでも
# --git-common-dir でリポジトリ本体を指すため、監査対象と結果が 1 対 1 に保たれる。
#
# 行スキーマ = rs-audit-*.sh の出力 (rs-lib.sh 冒頭) に以下を足したもの:
#   verdict   manual 項目に対する LLM 判定 (ok / warn / ng)
#   evidence  その判定の根拠
#   head      verdict を付けたときの HEAD。現在の HEAD と違えば判定は陳腐化したとみなす
#   decision  pending (未決) / approved (適用してよい) / rejected (直さないと決めた)
#             / applied (適用済み) / deferred (今回は見送り。Issue へ引き継ぐ)
#   note      decision の理由
# decision と verdict を持つのは status が ng / warn / manual の行だけ (ok / skip は対象外)。
set -uo pipefail
. "$(dirname "$0")/rs-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "rs-findings: jq が必要 (brew install jq)" >&2; exit 2; }

usage() {
  sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

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
         then ({verdict: $old.verdict, evidence: $old.evidence, head: $old.head,
                decision: $old.decision, note: $old.note}
               | with_entries(select(.value != null)))
         else {} end)
    | if (.status == "ng" or .status == "warn" or .status == "manual")
      then (if has("decision") then . else . + {decision: "pending"} end)
      else del(.decision, .note, .verdict, .evidence, .head) end
  ' > "$file.tmp" && mv "$file.tmp" "$file"

  cmd_summary
}

# ---- list: 条件で絞って JSON Lines を返す ----
cmd_list() {
  local status="" decision="" layer="" needs=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --status) status=${2:-}; shift 2 ;;
      --decision) decision=${2:-}; shift 2 ;;
      --layer) layer=${2:-}; shift 2 ;;
      --needs-verdict) needs=1; shift ;;
      *) echo "rs-findings: 不明な引数: $1" >&2; exit 2 ;;
    esac
  done
  [ -f "$file" ] || return 0
  # 行を $r に束縛してから絞る。`split(",") | index(.status)` と書くと index の中の
  # `.` がパイプ左の配列を指してしまい "Cannot index array with string" で落ちる
  jq -c --arg s "$status" --arg d "$decision" --arg l "$layer" \
        --arg head "$(head_now)" --argjson needs "$needs" '
    . as $r
    | (if $r.status == "manual" and ($r.verdict // "") != "" then $r.verdict else $r.status end) as $eff
    | select($s == "" or (($s | split(",")) | index($eff)))
    | select($d == "" or (($d | split(",")) | index($r.decision // "")))
    | select($l == "" or (($l | split(",")) | index($r.layer)))
    | select($needs == 0 or ($r.status == "manual" and (($r.verdict | not) or ($r.head != $head))))
  ' "$file"
}

# ---- set: 判定・判断を書き込む ----
cmd_set() {
  local decision="" verdict="" evidence="" note="" ids="" id
  while [ $# -gt 0 ]; do
    case "$1" in
      --decision) decision=${2:-}; shift 2 ;;
      --verdict)  verdict=${2:-};  shift 2 ;;
      --evidence) evidence=${2:-}; shift 2 ;;
      --note)     note=${2:-};     shift 2 ;;
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
    ""|ok|warn|ng) ;;
    *) echo "rs-findings: verdict は ok/warn/ng のいずれか: $verdict" >&2; exit 2 ;;
  esac

  # 存在しない id は黙って捨てず報告する (typo だと承認したつもりの項目が未決のまま残る)
  for id in $ids; do
    jq -e --arg id "$id" 'select(.id == $id)' "$file" >/dev/null 2>&1 \
      || echo "rs-findings: 未知の id: $id" >&2
  done

  local idsjson
  idsjson=$(printf '%s\n' $ids | jq -R . | jq -sc .)
  jq -c --argjson ids "$idsjson" --arg d "$decision" --arg v "$verdict" \
        --arg e "$evidence" --arg n "$note" --arg head "$(head_now)" '
    . as $r
    | if ($ids | index($r.id)) then
      . + (if $d != "" then {decision: $d} else {} end)
        + (if $v != "" then {verdict: $v, head: $head} else {} end)
        + (if $e != "" then {evidence: $e} else {} end)
        + (if $n != "" then {note: $n} else {} end)
    else . end
  ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"

  # 更新後の行を返す (呼び出し側が結果を確認できる)
  jq -c --argjson ids "$idsjson" '. as $r | select($ids | index($r.id))' "$file"
}

# ---- summary: 集計と次アクション。監査を報告で終わらせないための _next 行 ----
cmd_summary() {
  [ -s "$file" ] || { jq -cn '{id:"_next",hint:"findings が空 (先に監査を実行する)"}'; return; }
  # 判定済みの manual 行は verdict を実効 status として数える
  # (判定して ng と分かった項目が集計から抜け落ちると、未対応の必須違反を見落とす)
  jq -sc --arg head "$(head_now)" '
    map(. + {_eff: (if .status == "manual" and (.verdict // "") != "" then .verdict else .status end)})
    | (map(select(.status == "manual" and ((.verdict | not) or (.head != $head)))) | length) as $mp
    | (map(select(.decision == "pending")) | length) as $pending
    # 適用したのに status が変わらない項目。再監査で status が動けば decision は
    # 引き継がれず消えるので、ここに残るのは「直したつもりで直っていない」だけ
    | (map(select(.decision == "applied" and (._eff == "ng" or ._eff == "warn"))) | length) as $unresolved
    | {id: "_next",
       ng:       (map(select(._eff == "ng"))   | length),
       warn:     (map(select(._eff == "warn")) | length),
       manual_unjudged: $mp,
       pending:  $pending,
       approved: (map(select(.decision == "approved")) | length),
       applied:  (map(select(.decision == "applied"))  | length),
       deferred: (map(select(.decision == "deferred")) | length),
       rejected: (map(select(.decision == "rejected")) | length),
       applied_unresolved: $unresolved,
       hint:
         (if length == 0 then "findings が空 (先に監査を実行する)"
          elif $mp > 0 then "manual \($mp) 件が未判定 — 判定して rs-findings.sh set --verdict で記録する"
          elif $unresolved > 0 then "適用済みだが解消していない項目が \($unresolved) 件 — 適用内容を見直す"
          elif $pending > 0 then "未決 \($pending) 件 — repo-audit-fix スキルで承認・適用できる"
          else "未決の指摘なし" end)}
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
