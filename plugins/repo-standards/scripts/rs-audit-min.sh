#!/usr/bin/env bash
# 最小トークンの簡易監査。rs-audit-repo.sh + rs-audit-github.sh の機械判定だけを走らせ、
# 逸脱した項目 (ng / warn) を 1 行ずつに圧縮して報告する。LLM 判定 (status: manual) には
# 踏み込まず件数だけ数える。
#
#   bash rs-audit-min.sh [--no-github] [--width N] [--cadence bootstrap|drift]
#
#     --no-github  gh api を使う層② (GitHub 設定) を丸ごと省く。オフライン・未認証時や
#                  ローカル構成だけ見たいときに使う
#     --width N    detail の切り詰め幅 (既定 60 文字)。0 で detail を出さない
#     --cadence C  その cadence の項目だけに絞る (drift = 作業が状態を崩していく項目。ADR 0025)
#
# 他の rs-*.sh と違い出力は JSON Lines ではなくプレーンテキスト。トークン最小化が目的の
# スクリプトなので、機械可読性より 1 項目 1 行の短さを優先する (rs-lib.sh 冒頭の出力契約の
# 唯一の例外)。JSON Lines と findings への保存が要るときは rs-audit-repo.sh /
# rs-audit-github.sh を直接呼ぶ本監査 (repo-audit スキル) を使う。
#
# 報告専用で、findings には保存しない。直すなら本監査 (repo-audit) を通す — 安い層の判定を
# 修正フローへ引き渡す経路は、findings の全行に出自を持たせる代償に見合わなかった (ADR 0030)。
#
# レポートツールでありゲートではないので、検出結果によらず exit 0 を保つ
# (非 0 で落ちるのは jq 不在などスクリプト自体の異常のみ)。
set -uo pipefail

here=$(dirname "$0")
command -v jq >/dev/null 2>&1 || { echo "rs-audit-min: jq が必要 (brew install jq)" >&2; exit 2; }

with_github=1 cadence=
width=60
while [ $# -gt 0 ]; do
  case "$1" in
    --no-github) with_github=0; shift ;;
    --width) width=${2:-60}; shift 2 ;;
    --cadence)
      cadence=${2:-}
      case "$cadence" in bootstrap|drift) ;; *) echo "rs-audit-min: --cadence は bootstrap か drift" >&2; exit 2 ;; esac
      shift 2 ;;
    *) echo "rs-audit-min: 不明な引数: $1" >&2; exit 2 ;;
  esac
done
case "$width" in ''|*[!0-9]*) echo "rs-audit-min: --width は 0 以上の整数" >&2; exit 2 ;; esac

raw=$({
  bash "$here/rs-audit-repo.sh" ${cadence:+--cadence "$cadence"}
  [ "$with_github" -eq 1 ] && bash "$here/rs-audit-github.sh" ${cadence:+--cadence "$cadence"}
})

printf '%s\n' "$raw" | jq -sr --argjson w "$width" '
  (map(select(.id == "_meta"))) as $meta
  | (map(select(.id != null and .id != "_meta" and .id != "_next"))) as $rows
  | ((($meta | map(select(.layer == "repo")))[0]) // {}) as $mr
  | ((($meta | map(select(.layer == "github")))[0]) // {}) as $mg
  | (reduce $rows[] as $r ({}; .[$r.status] = ((.[$r.status] // 0) + 1))) as $c
  | (($c.ng // 0) + ($c.warn // 0)) as $bad
  # 前提未達で保留 (blocked) のうち level: required のもの。恒久的に対象外の skip と違い
  # 前提が埋まれば判定対象に戻るので、黙って落とすと required の取りこぼしが検知されない
  | ($rows | map(select(.status == "blocked" and .level == "required"))) as $blocked_req
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
    # required の保留だけ行として出す (recommended まで出すとこのスクリプトの存在理由である
    # トークン最小化に反する。件数は下の集計行で読める)
    + ($blocked_req
       | sort_by(.id)
       | map("BLOCK " + .id
             + (if $w == 0 then ""
                else "  " + ((.detail // "") | gsub("\\s+"; " ")
                             | if length > $w then .[0:$w] + "…" else . end)
                end)))
    + [ "ok=\($c.ok // 0) ng=\($c.ng // 0) warn=\($c.warn // 0) blocked=\($c.blocked // 0) skip=\($c.skip // 0) manual=\($c.manual // 0)" ]
    + [ "次: "
        + (if $nomanifest then "正本 repo-standards.json が無い — プラグインの配布が壊れている。/plugin update repo-standards@shinyaoguri で入れ直す"
           # 監査でなく生成の段階。修正フローへ送っても、リポの実体を材料にする
           # 生成的 fix (README・CLAUDE.md・CI) が空虚な雛形にしかならない
           elif $uninit then "コミットがまだ無い — 監査でなく雛形生成の段階。/repo-bootstrap で作る"
           elif $bad == 0 then "機械判定は逸脱なし"
           else "詳細と修正は /repo-audit → /repo-audit-fix" end)
        # 「未実施」とは書かない。このスクリプトが判定しないのは常に真だが、呼び出し側
        # (repo-audit-min スキル) は続けて rs-evidence.sh + 判定係で埋めるため
        + (if ($c.manual // 0) > 0 then " (LLM 判定 \($c.manual) 件はこのスクリプトの対象外)" else "" end)
        # 保留は「逸脱なし」ではなく「まだ判定できていない」。前提の id は BLOCK 行の
        # detail に入っているので、ここでは持ち越しが要ることだけ言う
        + (if ($blocked_req | length) > 0 then
             " / BLOCK \($blocked_req | length) 件は前提未達で未判定 — 前提を埋めるまで残タスクとして持ち越す"
           else "" end) ]
  | .[]
'

exit 0
