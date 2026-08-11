#!/usr/bin/env bash
# 最小トークンの簡易監査。rs-audit-repo.sh + rs-audit-github.sh の機械判定だけを走らせ、
# 逸脱した項目 (ng / warn) を 1 行ずつに圧縮して報告する。LLM 判定 (status: manual) には
# 踏み込まず件数だけ数える。
#
#   bash rs-audit-min.sh [--no-github] [--width N] [--save]
#
#     --no-github  gh api を使う層② (GitHub 設定) を丸ごと省く。オフライン・未認証時や
#                  ローカル構成だけ見たいときに使う
#     --width N    detail の切り詰め幅 (既定 60 文字)。0 で detail を出さない
#     --save       機械判定を findings へ保存し、修正フロー (repo-audit-fix) へ
#                  引き渡せるようにする。出力は圧縮テキストのまま (保存の副作用だけ足す)
#
# 他の rs-*.sh と違い出力は JSON Lines ではなくプレーンテキスト。トークン最小化が目的の
# スクリプトなので、機械可読性より 1 項目 1 行の短さを優先する (rs-lib.sh 冒頭の出力契約の
# 唯一の例外)。JSON Lines と findings への保存が要るときは rs-audit-repo.sh /
# rs-audit-github.sh を直接呼ぶ本監査 (repo-audit スキル) を使う。
#
# 既定では findings を保存しない (triage 専用)。保存するのは --save を明示したときだけで、
# 安い層の判定が本監査の判定を無警告で置き換えないよう、書き戻し側に上書き規則がある
# (rs-findings.sh の `set --source min`。min の verdict は陳腐化していない full の
# verdict を上書きしない)。機械判定そのものは層によらず同じ結果なので保存してよい。
#
# レポートツールでありゲートではないので、検出結果によらず exit 0 を保つ
# (非 0 で落ちるのは jq 不在などスクリプト自体の異常のみ)。
set -uo pipefail

here=$(dirname "$0")
command -v jq >/dev/null 2>&1 || { echo "rs-audit-min: jq が必要 (brew install jq)" >&2; exit 2; }

with_github=1
width=60
save=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-github) with_github=0; shift ;;
    --width) width=${2:-60}; shift 2 ;;
    --save) save=1; shift ;;
    *) echo "rs-audit-min: 不明な引数: $1" >&2; exit 2 ;;
  esac
done
case "$width" in ''|*[!0-9]*) echo "rs-audit-min: --width は 0 以上の整数" >&2; exit 2 ;; esac

raw=$({
  bash "$here/rs-audit-repo.sh"
  [ "$with_github" -eq 1 ] && bash "$here/rs-audit-github.sh"
})

# 保存の出力 (JSON Lines 全行 + 集計) は捨てる。ここに流すとこのスクリプトの存在理由
# であるトークン最小化が消える。保存できたかどうかだけを次アクションの 1 行に畳む
saved=0
if [ "$save" -eq 1 ]; then
  out=$(printf '%s\n' "$raw" | bash "$here/rs-findings.sh" save 2>/dev/null)
  printf '%s\n' "$out" | grep -q '"id":"findings-store"' || saved=1
fi

printf '%s\n' "$raw" | jq -sr --argjson w "$width" --argjson save "$save" --argjson saved "$saved" '
  (map(select(.id == "_meta"))) as $meta
  | (map(select(.id != null and .id != "_meta" and .id != "_next"))) as $rows
  | ((($meta | map(select(.layer == "repo")))[0]) // {}) as $mr
  | ((($meta | map(select(.layer == "github")))[0]) // {}) as $mg
  | (reduce $rows[] as $r ({}; .[$r.status] = ((.[$r.status] // 0) + 1))) as $c
  | (($c.ng // 0) + ($c.warn // 0)) as $bad
  | ($rows | map(select(.id == "standards-manifest-missing")) | length > 0) as $nomanifest
  | ($rows | map(select(.id == "repo-uninitialized")) | length > 0) as $uninit
  # GitHub 上のリポを特定できたときだけ repo= を名乗る。特定できないときに
  # 作業ディレクトリ名を repo= として出すと、worktree 名などを GitHub のリポ名と
  # 取り違えるので、キー自体を dir= に変えて出所を明示する
  | [ (if ($mg.repo // "") != "" then "repo=\($mg.repo)"
       else "dir=\(($mr.root // "?") | split("/") | last)" end)
      + " kind=\($mr.kind // "?")"
      + " visibility=\($mr.visibility // $mg.visibility // "?")" ]
    + ($rows
       | map(select(.status == "ng" or .status == "warn"))
       | sort_by((if .status == "ng" then 0 else 1 end), .id)
       | map((if .status == "ng" then "NG  " else "WARN" end) + " " + .id
             + (if $w == 0 then ""
                else "  " + ((.detail // "") | gsub("\\s+"; " ")
                             | if length > $w then .[0:$w] + "…" else . end)
                end)))
    + [ "ok=\($c.ok // 0) ng=\($c.ng // 0) warn=\($c.warn // 0) skip=\($c.skip // 0) manual=\($c.manual // 0)" ]
    + [ "次: "
        + (if $nomanifest then "正本 repo-standards.json が無い — setup リポのセットアップが先"
           # 監査でなく生成の段階。修正フローへ送っても、リポの実体を材料にする
           # 生成的 fix (README・CLAUDE.md・CI) が空虚な雛形にしかならない
           elif $uninit then "コミットがまだ無い — 監査でなく雛形生成の段階。/repo-bootstrap で作る"
           elif $save == 1 and $saved == 0 then "findings に保存できない (git リポジトリ外)"
           elif $bad == 0 then "機械判定は逸脱なし"
           elif $save == 1 then "findings に保存済み。修正は /repo-audit-fix (確度が要るなら /repo-audit)"
           else "詳細と修正は /repo-audit → /repo-audit-fix" end)
        # 「未実施」とは書かない。このスクリプトが判定しないのは常に真だが、呼び出し側
        # (repo-audit-min スキル) は続けて rs-evidence.sh + 判定係で埋めるため
        + (if ($c.manual // 0) > 0 then " (LLM 判定 \($c.manual) 件はこのスクリプトの対象外)" else "" end) ]
  | .[]
'

exit 0
