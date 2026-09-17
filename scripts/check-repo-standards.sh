#!/usr/bin/env bash
# 判定基準の正本 repo-standards.json のスキーマ検査。要 jq。
#
#   ./scripts/check-repo-standards.sh [manifest]
#
# 正本は plugins/repo-standards/repo-standards.json (ADR 0022 で setup リポから移設)。
# 消費側 (rs-*.sh) は jq の名前指定でフィールドを読むので、値が欠けても空文字でも
# 実行時には落ちず「何も判定しないまま ok に見える」形で壊れる。それを CI で捕まえる。
# enum と必須フィールドは消費側スクリプトとの契約なので、変えるときは両方を直す。
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
manifest="${1:-$repo_root/plugins/repo-standards/repo-standards.json}"

command -v jq >/dev/null 2>&1 || { echo "jq が要る" >&2; exit 2; }
[ -r "$manifest" ] || { echo "正本が読めない: $manifest" >&2; exit 2; }
jq -e . "$manifest" >/dev/null 2>&1 || { echo "JSON として壊れている: $manifest" >&2; exit 2; }

failures=0

# assert_empty <検査名> <jq プログラム>
#   jq が 1 行でも出したら違反。出た行がそのまま違反の内訳になる
#   jq 自体が失敗したときも違反として扱う (空出力を合格と誤読しないため)
assert_empty() {
  local name=$1 prog=$2 out rc
  out=$(jq -r "$prog" "$manifest" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "NG  $name (検査自体が失敗)"
    printf '%s\n' "$out" | sed 's/^/      /'
    failures=$((failures + 1))
  elif [ -n "$out" ]; then
    echo "NG  $name"
    printf '%s\n' "$out" | sed 's/^/      /'
    failures=$((failures + 1))
  else
    echo "ok  $name"
  fi
}

# 契約の定義。消費側と共有している語彙
common_defs='
def layers: ["repo","github","claude"];
def levels: ["required","recommended","rejected"];
def check_types: ["file_exists","file_absent","glob_exists","gh_api","builtin","llm"];
def fix_kinds: ["deterministic","generative","destructive"];
def required_fields: {
  "file_exists":["path"], "file_absent":["path"], "glob_exists":["path"],
  "gh_api":["endpoint","jq","expect"], "builtin":["name"], "llm":["prompt"]
};
def destructive_markers: ["削除","git rm ","履歴の書き換え"];
def blank: tostring | test("^\\s*$");
'

assert_empty "version が 1" \
  "$common_defs"'if .version == 1 then empty else "version=\(.version)" end'

assert_empty "kind id が重複していない" \
  "$common_defs"'[.kinds[].id] | group_by(.) | map(select(length > 1)) | .[] | "重複: \(.[0])"'

# marker: null の kind が無いと、どの marker にも合致しないリポの kind が決まらない
assert_empty "フォールバック用の marker: null な kind がある" \
  "$common_defs"'if ([.kinds[] | select(.marker == null)] | length) > 0 then empty else "marker: null な kind が無い" end'

assert_empty "item id が重複していない" \
  "$common_defs"'[.items[].id] | group_by(.) | map(select(length > 1)) | .[] | "重複: \(.[0])"'

assert_empty "layer / level / check.type が enum に収まる" \
  "$common_defs"'.items[] | . as $i
   | (if (layers | index($i.layer)) == null then "\($i.id): 未知の layer \($i.layer)" else empty end),
     (if (levels | index($i.level)) == null then "\($i.id): 未知の level \($i.level)" else empty end),
     (if (check_types | index($i.check.type)) == null then "\($i.id): 未知の check.type \($i.check.type)" else empty end)'

assert_empty "check.type ごとの必須フィールドが揃っている" \
  "$common_defs"'.items[] | . as $i | (required_fields[$i.check.type] // []) as $req
   | $req[] | . as $f | select(($i.check | has($f)) | not) | "\($i.id): check.\($f) が無い"'

# 必須フィールドが空文字でも存在チェックだけは通ってしまう。空の prompt は LLM 判定が
# 何も判定できないまま ok に見え、空の path は全ファイルに一致する
assert_empty "check の必須フィールドが空でない" \
  "$common_defs"'.items[] | . as $i | (required_fields[$i.check.type] // []) as $req
   | $req[] | . as $f | select(($i.check | has($f)) and ($i.check[$f] | blank)) | "\($i.id): check.\($f) が空"'

assert_empty "applies_to が空でなく、定義済みの kind に解決する" \
  "$common_defs"'([.kinds[].id] + ["all"]) as $known | .items[] | . as $i
   | (if (($i.applies_to // []) | length) == 0 then "\($i.id): applies_to が空" else empty end),
     ($i.applies_to[]? | . as $t | select(($known | index($t)) == null) | "\($i.id): 未定義の kind \($t)")'

assert_empty "when は visibility のみ、値は public / private" \
  "$common_defs"'.items[] | select(has("when")) | . as $i
   | ($i.when | keys | .[] | select(. != "visibility") | "\($i.id): when.\(.) は未対応"),
     (if (["public","private"] | index($i.when.visibility)) == null
      then "\($i.id): when.visibility=\($i.when.visibility)" else empty end)'

# required 違反は必ず修正提案とセットで報告する。fix 無しでは監査が行き止まりになる
assert_empty "required 項目に fix がある" \
  "$common_defs"'.items[] | select(.level == "required")
   | select((.fix // "") | blank) | "\(.id): required なのに fix が無い"'

assert_empty "fix_kind が enum に収まる" \
  "$common_defs"'.items[] | . as $i | select($i | has("fix_kind"))
   | select((fix_kinds | index($i.fix_kind)) == null) | "\($i.id): 未知の fix_kind \($i.fix_kind)"'

# fix_kind は fix の性質を宣言するフィールド。fix が無い項目に付けると意味が濁り、
# fix があるのに付いていないと修正側が LLM 推定へ落ちて承認の粒度がブレる
assert_empty "fix と fix_kind が対で存在する" \
  "$common_defs"'.items[] | . as $i | (($i.fix // "") | blank | not) as $has_fix
   | if $has_fix and ($i | has("fix_kind") | not) then "\($i.id): fix があるのに fix_kind が無い"
     elif ($has_fix | not) and ($i | has("fix_kind")) then "\($i.id): fix が無いのに fix_kind がある"
     else empty end'

# 削除・追跡外し・履歴の書き換えを促す fix が deterministic に紛れると、
# まとめて 1 承認の群に入って自動適用されてしまう
assert_empty "破壊的な fix が destructive として宣言されている" \
  "$common_defs"'.items[] | . as $i | ($i.fix // "") as $fix
   | select([destructive_markers[] | . as $m | select($fix | contains($m))] | length > 0)
   | select($i.fix_kind != "destructive") | "\($i.id): 破壊的な fix なのに fix_kind=\($i.fix_kind // "(無し)")"'

# why はレポートにそのまま出す根拠。無いと「なぜ直すのか」が説明できない
assert_empty "全項目に why がある" \
  "$common_defs"'.items[] | select((.why // "") | blank) | "\(.id): why が無い"'

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK ($(jq -r '.items | length' "$manifest") 項目)"
