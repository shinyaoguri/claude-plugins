#!/usr/bin/env bash
# repo-standards プラグインの rs-findings.sh のテスト。
# 一時 git リポジトリに監査出力を流し込み、保存・引き継ぎ・集計の結果を検証する。
# 関数を source せずエンドツーエンドで見るのは、repo-audit → repo-audit-fix の
# 受け渡し契約 (行スキーマと decision の遷移) ごと守るため。
#
#   bash scripts/test-rs-findings.sh
set -uo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
target="$repo_root/plugins/repo-standards/scripts/rs-findings.sh"

# 一時リポでコミットするため author/committer を明示する。CI の runner には git の
# user 設定が無く auto-detect に失敗してコミットが落ちる (macOS は hostname から
# 補完するのでローカルでは再現しない)。HEAD が進まないと verdict の陳腐化を検証できない
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

failures=0

# 判定には 20 バイト以上の根拠が要る (rs-findings.sh の MIN_EVIDENCE_BYTES)。
# テストの本題ではないので共通の文字列を使う
EV="この項目の根拠をここに一文で書く"

check() { # check <期待> <実際> <ケース名>
  if [ "$1" = "$2" ]; then
    echo "  [ok]   $3 → $2"
  else
    echo "  [FAIL] $3 → 期待 $1 / 実際 $2"
    failures=$((failures + 1))
  fi
}

# 一時 git リポを作りパスを返す。$(newrepo) はサブシェルなのでカウンタ変数では
# 一意にならず (親に反映されない) 全ケースが同じディレクトリを共有してしまう
newrepo() {
  local d
  d=$(mktemp -d "$tmp/case-XXXXXX")
  ( cd "$d" && git init -q -b main && git commit -q --allow-empty -m init ) >/dev/null 2>&1
  printf '%s\n' "$d"
}

line() { # line <id> <status> [level]
  jq -cn --arg id "$1" --arg st "$2" --arg lv "${3:-recommended}" \
    '{id:$id,layer:"repo",level:$lv,status:$st,detail:"テスト用",fix:"テスト用"}'
}

echo "save: 保存と decision の初期化"

d=$(newrepo)
got=$( cd "$d" && { line a ng required; line b ok; } | bash "$target" save >/dev/null
       bash "$target" list | jq -r '[.id, (.decision // "-")] | join(":")' | tr '\n' ' ' )
check "a:pending b:- " "$got" "ng には pending が付き ok には付かない"

# _meta はヘッダ材料であって検査項目ではない。混ざると id 重複で集計が壊れる
d=$(newrepo)
got=$( cd "$d" && { echo '{"id":"_meta","layer":"repo","kind":"generic"}'; line a warn; } \
       | bash "$target" save >/dev/null
       bash "$target" list | jq -r .id | tr '\n' ' ' )
check "a " "$got" "_meta 行は findings に混ざらない"

echo
echo "save: 前回の判断の引き継ぎ"

d=$(newrepo)
got=$( cd "$d" && line a warn | bash "$target" save >/dev/null
       bash "$target" set --decision approved a >/dev/null
       line a warn | bash "$target" save >/dev/null
       bash "$target" list | jq -r '.decision' )
check "approved" "$got" "status が同じなら承認を引き継ぐ"

# 直った項目に承認が残ると「適用済みか未適用か」が判別できなくなる
d=$(newrepo)
got=$( cd "$d" && line a warn | bash "$target" save >/dev/null
       bash "$target" set --decision approved a >/dev/null
       line a ok | bash "$target" save >/dev/null
       bash "$target" list | jq -r '.decision // "-"' )
check "-" "$got" "ok になれば decision は消える"

# 境界値: 悪化 (warn→ng) は判断のやり直しが要る
d=$(newrepo)
got=$( cd "$d" && line a warn | bash "$target" save >/dev/null
       bash "$target" set --decision approved a >/dev/null
       line a ng required | bash "$target" save >/dev/null
       bash "$target" list | jq -r '.decision' )
check "pending" "$got" "status が変われば未決に戻る"

echo
echo "manual 項目の判定 (verdict)"

d=$(newrepo)
got=$( cd "$d" && line a manual | bash "$target" save >/dev/null
       bash "$target" set --verdict ng --evidence "$EV" a >/dev/null
       bash "$target" list --status ng | jq -r .id )
check "a" "$got" "判定済み manual は実効 status で拾える"

# 判定して ng と分かった項目が集計から抜けると、未対応の必須違反を見落とす
d=$(newrepo)
got=$( cd "$d" && { line a manual; line b ok; } | bash "$target" save >/dev/null
       bash "$target" set --verdict ng --evidence "$EV" a >/dev/null
       bash "$target" summary | jq -r '[.ng, .manual_unjudged] | join(",")' )
check "1,0" "$got" "判定済み manual は集計でも実効 status で数える"

# 境界値: HEAD が進めば判定は陳腐化し、再判定の対象に戻る
d=$(newrepo)
got=$( cd "$d" && line a manual | bash "$target" save >/dev/null
       bash "$target" set --verdict ok --evidence "$EV" a >/dev/null
       before=$(bash "$target" list --needs-verdict | wc -l | tr -d ' ')
       git commit -q --allow-empty -m next
       after=$(bash "$target" list --needs-verdict | wc -l | tr -d ' ')
       echo "$before/$after" )
check "0/1" "$got" "HEAD が進むと再判定の対象になる"

echo
echo "set: 入力の検証 (失敗系)"

d=$(newrepo)
got=$( cd "$d" && line a warn | bash "$target" save >/dev/null
       bash "$target" set --decision approvd a >/dev/null 2>&1; echo $? )
check "2" "$got" "decision の綴り違いは非 0 で拒否する"

d=$(newrepo)
got=$( cd "$d" && line a warn | bash "$target" save >/dev/null
       bash "$target" set --decision approved typo-id 2>&1 >/dev/null | grep -c '未知の id' )
check "1" "$got" "未知の id は警告する"

d=$(newrepo)
got=$( cd "$d" && line a warn | bash "$target" save >/dev/null
       bash "$target" set --decision approved >/dev/null 2>&1; echo $? )
check "2" "$got" "id 無しの set は非 0 で拒否する"

echo
echo "summary: 集計と次アクション"

d=$(newrepo)
got=$( cd "$d" && { line a ng required; line b warn; line c manual; } | bash "$target" save >/dev/null
       bash "$target" summary | jq -r '[.ng, .warn, .manual_unjudged, .pending] | join(",")' )
check "1,1,1,3" "$got" "status ごとの件数と未決数"

# 適用したのに status が動かない項目は埋もれさせない
d=$(newrepo)
got=$( cd "$d" && line a warn | bash "$target" save >/dev/null
       bash "$target" set --decision applied a >/dev/null
       line a warn | bash "$target" save >/dev/null
       bash "$target" summary | jq -r .applied_unresolved )
check "1" "$got" "適用済みで未解消の項目を数える"

# 境界値: manual は適用しても status が動かないので、解消の判断は verdict で見る
d=$(newrepo)
got=$( cd "$d" && line a manual | bash "$target" save >/dev/null
       bash "$target" set --decision applied a >/dev/null
       bash "$target" set --verdict ok --evidence "$EV" a >/dev/null
       bash "$target" summary | jq -r .applied_unresolved )
check "0" "$got" "適用後の判定が ok なら未解消に数えない"

d=$(newrepo)
got=$( cd "$d" && bash "$target" summary | jq -r .hint )
check "findings が空 (先に監査を実行する)" "$got" "findings が無くても落ちない"

echo
echo "前提不足時の報告 (出力契約の範囲内で)"

# git リポ外: 保存は諦めるが監査出力は素通しし、契約内の status で報告する
d="$tmp/not-a-repo"
mkdir -p "$d"
got=$( cd "$d" && line a warn | bash "$target" save 2>/dev/null \
       | jq -r 'select(.id == "findings-store") | .status' )
check "skip" "$got" "git リポ外は skip で報告する"

got=$( cd "$d" && line a warn | bash "$target" save 2>/dev/null | jq -r 'select(.id == "a") | .id' )
check "a" "$got" "git リポ外でも監査出力は素通しする"

got=$( cd "$d" && line a warn | bash "$target" save >/dev/null 2>&1; echo $? )
check "0" "$got" "git リポ外でも exit 0 を保つ"

echo
echo "判定には根拠を必須にする (接地しない判定を記録に残さない)"

d=$(newrepo)
got=$( cd "$d" && line a manual required | bash "$target" save >/dev/null
       bash "$target" set --verdict ng a >/dev/null 2>&1; echo $? )
check "2" "$got" "--evidence 無しの判定は拒否する"

d=$(newrepo)
got=$( cd "$d" && line a manual required | bash "$target" save >/dev/null
       bash "$target" set --verdict ok --evidence "問題なし" a >/dev/null 2>&1; echo $? )
check "2" "$got" "短すぎる根拠 (20 バイト未満) も拒否する"

# 拒否したときに verdict だけ書き込まれていたら、根拠必須は骨抜きになる
d=$(newrepo)
got=$( cd "$d" && line a manual required | bash "$target" save >/dev/null
       bash "$target" set --verdict ng a >/dev/null 2>&1
       bash "$target" list | jq -r '.verdict // "-"' )
check "-" "$got" "拒否された判定は書き込まれない"

d=$(newrepo)
got=$( cd "$d" && line a manual required | bash "$target" save >/dev/null
       bash "$target" set --decision approved a >/dev/null 2>&1; echo $? )
check "0" "$got" "decision だけの更新には根拠を求めない"

echo
echo "verdict: skip (対象外を ok に丸めない)"

d=$(newrepo)
got=$( cd "$d" && line a manual required | bash "$target" save >/dev/null
       bash "$target" set --verdict skip --evidence "$EV" a >/dev/null 2>&1; echo $? )
check "0" "$got" "対象外は skip として記録できる"

# skip を ok に丸めると「満たしている」と読めてしまう。集計でも区別する
d=$(newrepo)
got=$( cd "$d" && line a manual required | bash "$target" save >/dev/null
       bash "$target" set --verdict skip --evidence "$EV" a >/dev/null
       bash "$target" summary | jq -r '[.ng, .warn, .manual_unjudged] | join(",")' )
check "0,0,0" "$got" "skip は ng / warn / 未判定のどれにも数えない"

echo
echo "decision は判定に追従する (修正フローに並ぶ項目を正す)"

d=$(newrepo)
got=$( cd "$d" && line a manual required | bash "$target" save >/dev/null
       bash "$target" set --verdict ok --evidence "$EV" a >/dev/null
       bash "$target" list --decision pending | wc -l | tr -d ' ' )
check "0" "$got" "ok と判定した項目は未決から外れる (承認の要らない項目を並べない)"

d=$(newrepo)
got=$( cd "$d" && line a manual required | bash "$target" save >/dev/null
       bash "$target" set --verdict skip --evidence "$EV" a >/dev/null
       bash "$target" list --decision pending | wc -l | tr -d ' ' )
check "0" "$got" "skip と判定した項目も未決から外れる"

# 再監査で decision が復活すると、毎回同じ項目を承認させることになる
d=$(newrepo)
got=$( cd "$d" && line a manual required | bash "$target" save >/dev/null
       bash "$target" set --verdict ok --evidence "$EV" a >/dev/null
       line a manual required | bash "$target" save >/dev/null
       bash "$target" list | jq -r '.decision // "-"' )
check "-" "$got" "再監査をまたいでも ok の項目に未決が復活しない"

# 反証で ok が覆ったのに未決へ戻らないと、修正フローから丸ごと落ちる
d=$(newrepo)
got=$( cd "$d" && line a manual required | bash "$target" save >/dev/null
       bash "$target" set --verdict ok --evidence "$EV" a >/dev/null
       bash "$target" set --verdict warn --evidence "$EV" a >/dev/null
       bash "$target" list --decision pending | jq -r .id )
check "a" "$got" "ok から warn へ覆ったら未決に復帰する"

# 承認済みの項目を再判定しても承認は保つ (承認は人の判断で、判定とは別)
d=$(newrepo)
got=$( cd "$d" && line a manual required | bash "$target" save >/dev/null
       bash "$target" set --verdict warn --evidence "$EV" a >/dev/null
       bash "$target" set --decision approved a >/dev/null
       bash "$target" set --verdict ng --evidence "$EV" a >/dev/null
       bash "$target" list | jq -r .decision )
check "approved" "$got" "再判定しても既存の decision は壊さない"

echo
echo "verified: 反証パスの再開性"

d=$(newrepo)
got=$( cd "$d" && { line a manual required; line b manual; } | bash "$target" save >/dev/null
       bash "$target" set --verdict ok --evidence "$EV" a >/dev/null
       bash "$target" set --verdict ok --evidence "$EV" b >/dev/null
       bash "$target" list --needs-verify | jq -r .id | tr '\n' ' ' )
check "a " "$got" "required は ok でも反証待ちに入る (見落としの代償が大きい)"

d=$(newrepo)
got=$( cd "$d" && line a manual | bash "$target" save >/dev/null
       bash "$target" set --verdict ng --evidence "$EV" a >/dev/null
       bash "$target" list --needs-verify | jq -r .id )
check "a" "$got" "recommended でも ng / warn と判定したら反証待ちに入る"

d=$(newrepo)
got=$( cd "$d" && line a manual required | bash "$target" save >/dev/null
       bash "$target" set --verdict ok --evidence "$EV" a >/dev/null
       bash "$target" set --verified --evidence "$EV" a >/dev/null
       bash "$target" list --needs-verify | wc -l | tr -d ' ' )
check "0" "$got" "反証を記録したら反証待ちから外れる"

# 反証済みの判定が、再判定後も反証済みに見えると検証が空洞化する
d=$(newrepo)
got=$( cd "$d" && line a manual required | bash "$target" save >/dev/null
       bash "$target" set --verdict ok --evidence "$EV" a >/dev/null
       bash "$target" set --verified --evidence "$EV" a >/dev/null
       bash "$target" set --verdict warn --evidence "$EV" a >/dev/null
       bash "$target" list | jq -r '.verified // "-"' )
check "-" "$got" "verdict を書き換えると verified は落ちる"

# 陳腐化した判定は反証でなく再判定に引き戻す (古い判定を反証しても意味がない)
d=$(newrepo)
got=$( cd "$d" && line a manual required | bash "$target" save >/dev/null
       bash "$target" set --verdict ok --evidence "$EV" a >/dev/null
       git commit -q --allow-empty -m next
       echo "$(bash "$target" list --needs-verify | wc -l | tr -d ' ')/$(bash "$target" list --needs-verdict | wc -l | tr -d ' ')" )
check "0/1" "$got" "HEAD が進んだ判定は反証待ちでなく再判定の対象になる"

d=$(newrepo)
got=$( cd "$d" && line a manual required | bash "$target" save >/dev/null
       bash "$target" set --verdict ok --evidence "$EV" a >/dev/null
       bash "$target" summary | jq -r '[.unverified, .hint] | join(" | ")' )
check "1 | 反証待ち 1 件 — 独立した判定者に覆せるか確かめて set --verified で記録する" "$got" \
  "反証待ちが残っていれば集計が次アクションに出す"

echo
echo "list --level"

d=$(newrepo)
got=$( cd "$d" && { line a ng required; line b warn; } | bash "$target" save >/dev/null
       bash "$target" list --level required | jq -r .id )
check "a" "$got" "level で絞れる (反証対象の抽出に使う)"

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures 件"
  exit 1
fi
echo "OK"
