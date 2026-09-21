#!/usr/bin/env bash
# repo-standards プラグイン共通ライブラリ。各 rs-*.sh から source される。要 jq。
#
# チェックリスト正本 (repo-standards.json) の解決チェーン:
#   ① $REPO_STANDARDS_JSON (開発・テスト用の上書き)
#   ② プラグイン同梱の repo-standards.json (主経路。正本そのもの。ADR 0022)
#   ③ ~/.claude/repo-standards.json (旧経路。setup リポの ansible が張っていた symlink)
#   ④ ~/.setup/claude/repo-standards.json (旧経路。playbook 未実行の新マシン向けだった)
#
# ③④ は移設の移行期だけの保険で、setup 側から実体が消えれば自然に外れる (dangling symlink は
# [ -r ] を通らない)。同梱コピーを $CLAUDE_PLUGIN_ROOT でなくこのスクリプト自身の位置から
# 引くのは、テストが rs-*.sh を直接叩く (プラグインとして起動しない) 経路でも効かせるため。
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
  for p in "${REPO_STANDARDS_JSON:-}" "$bundled" \
    "$HOME/.claude/repo-standards.json" "$HOME/.setup/claude/repo-standards.json"; do
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
