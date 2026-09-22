#!/usr/bin/env bash
# repo-standards プラグイン共通ライブラリ。各 rs-*.sh から source される。要 jq。
#
# チェックリスト正本 (repo-standards.json) の解決:
#   ① $REPO_STANDARDS_JSON (開発・テスト用の上書き)
#   ② プラグイン同梱の repo-standards.json (主経路。正本そのもの。ADR 0022)
#
# 同梱コピーを $CLAUDE_PLUGIN_ROOT でなくこのスクリプト自身の位置から引くのは、テストが rs-*.sh を
# 直接叩く (プラグインとして起動しない) 経路でも効かせるため。setup リポ経由の旧経路 (~/.claude・
# ~/.setup) は移行期の保険だったので外した (ADR 0030)。
#
# 出力契約 (rs-audit-min.sh を除く全 rs-*.sh 共通): JSON Lines。1 チェック = 1 行
#   {"id","layer","level","status","detail","fix"?}
#   status: ok / ng (required 違反) / warn (recommended 違反)
#         / blocked (別の標準項目が未達で今は判定できない。理由と前提の id を detail に)
#         / skip (恒久的に対象外。理由を detail に) / manual (LLM 判定へ委譲)
#
# blocked と skip を分けるのは、前者が「前提が解消されれば判定対象に戻る」一時的な状態
# だから (ADR 0019)。同じ skip に潰すと、前提を先送りしたリポで required 項目が報告からも
# 持ち越しからも黙って消える (claude-plugins issue #97 の実害)。判断の目安:
#   blocked … 前提が別の標準項目 (CI workflow が無いので required checks を判定できない 等)
#   skip    … 前提がリポの性質・環境 (タグが無い / private 限定 / gh 未認証 / 種別が違う)
# blocked に fix は付けない。当てる先はこの項目でなく前提側の項目にある。
# スクリプトはレポートツールでありゲートではない。チェック結果がどうであれ exit 0 を保ち、
# スクリプト自体の異常 (jq 不在など) のみ非 0 で落ちる。
#
# この JSON Lines を保存し、LLM 判定 (verdict) と適用判断 (decision) を足して
# 監査 → 修正へ引き渡すのが rs-findings.sh。行スキーマの拡張分はそちらの冒頭を参照。
# rs-audit-min.sh はこの JSON Lines を人間 / LLM 向けの圧縮テキストへ畳む出口で、
# トークン最小化のため出力契約から外れる (理由はそちらの冒頭を参照)。

resolve_standards() {
  local p bundled
  bundled=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/repo-standards.json
  for p in "${REPO_STANDARDS_JSON:-}" "$bundled"; do
    [ -n "$p" ] && [ -r "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

# emit <id> <layer> <level> <status> <detail> [fix] [fix_kind]
# fix_kind は修正の性質 (deterministic / generative / destructive) を正本が宣言するための
# 任意フィールド。修正側 (repo-audit-fix) の承認粒度がこれで決まる。正本がまだ持たない
# 項目では空になり出力から落ちる — 値の妥当性は scripts/check-repo-standards.sh が守る
emit() {
  jq -cn --arg id "$1" --arg layer "$2" --arg level "$3" --arg status "$4" \
    --arg detail "$5" --arg fix "${6:-}" --arg fix_kind "${7:-}" \
    '{id:$id,layer:$layer,level:$level,status:$status,detail:$detail}
     + (if $fix != "" then {fix:$fix} else {} end)
     + (if $fix_kind != "" then {fix_kind:$fix_kind} else {} end)'
}

# 検査失敗時の status を level から導く (required → ng / それ以外 → warn)
fail_status() {
  case "$1" in required) echo ng ;; *) echo warn ;; esac
}

# 正本不在の共通レポート (呼び出し側はこの後 exit 0 する)
emit_manifest_missing() {
  emit standards-manifest-missing meta required ng \
    "チェックリスト正本 repo-standards.json が見つからない" \
    "正本はプラグインに同梱されているので、ここに来るのは配布が壊れている状態。/plugin update repo-standards@shinyaoguri でプラグインを入れ直す"
}

# --cadence <bootstrap|drift> の引数解析。監査スクリプト共通。既定は全件 — 絞るのは「定期的に
# 見直す」用途のためで、リポを初めて見るときに設置漏れが隠れては困る (ADR 0025)。
# 結果は cadence_filter に入る。呼び出し側は parse_cadence_arg "$@" と書く
parse_cadence_arg() {
  cadence_filter=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --cadence)
        cadence_filter="${2:-}"
        case "$cadence_filter" in
          bootstrap|drift) ;;
          *) echo "$(basename "$0"): --cadence は bootstrap か drift" >&2; exit 2 ;;
        esac
        shift 2 ;;
      *) echo "$(basename "$0"): 不明な引数: $1" >&2; exit 2 ;;
    esac
  done
}

# 項目の when.visibility が今のリポに合わなければ skip を出して 0 を返す (呼び出し側は continue)。
# 合っている・条件が無いときは 1。visibility が unknown のときは、なぜ判定できないかを添える
# emit_visibility_skip <id> <layer> <level> <item json> <visibility> [unknown の理由]
emit_visibility_skip() {
  local want
  want=$(jq -r '.when.visibility // ""' <<<"$4")
  [ -n "$want" ] && [ "$want" != "$5" ] || return 1
  if [ "$5" = unknown ]; then
    emit "$1" "$2" "$3" skip "$want リポのみ対象だが可視性を判定できない — ${6:-理由不明}"
  else
    emit "$1" "$2" "$3" skip "$want リポのみ対象 (このリポは $5)"
  fi
  return 0
}

# builtin_<name> を呼んで結果を emit する。builtin の返り値の契約はここ 1 か所で読む:
#   ok            適合
#   ok:<詳細>     適合。根拠が自明でないとき (どう回り道して見つけたか)
#   skip:<理由>   恒久的に対象外
#   blocked:<理由> 別の標準項目が未達で今は判定できない。fix は渡さない (当てる先は前提側の項目)
#   fail:<詳細>   違反。検査が具体的な違反箇所を掴んでいるとき (どのブランチ・どのファイルか)
#   その他        違反 (why をそのまま detail に)
# emit_builtin_result <id> <layer> <level> <name> <why> <fix> <fix_kind>
emit_builtin_result() {
  local id=$1 layer=$2 level=$3 name=$4 why=$5 fix=$6 fix_kind=$7 result
  if ! declare -F "builtin_$name" >/dev/null; then
    emit "$id" "$layer" "$level" skip "builtin '$name' はこのスクリプトに未実装 (正本との契約ずれ。プラグイン更新が必要)"
    return
  fi
  result=$("builtin_$name")
  case "$result" in
    ok)        emit "$id" "$layer" "$level" ok "" ;;
    ok:*)      emit "$id" "$layer" "$level" ok "${result#ok:}" ;;
    skip:*)    emit "$id" "$layer" "$level" skip "${result#skip:}" ;;
    blocked:*) emit "$id" "$layer" "$level" blocked "${result#blocked:}" ;;
    fail:*)    emit "$id" "$layer" "$level" "$(fail_status "$level")" "${result#fail:} — $why" "$fix" "$fix_kind" ;;
    *)         emit "$id" "$layer" "$level" "$(fail_status "$level")" "$why" "$fix" "$fix_kind" ;;
  esac
}
