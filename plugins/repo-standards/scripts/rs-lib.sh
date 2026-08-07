#!/usr/bin/env bash
# repo-standards プラグイン共通ライブラリ。各 rs-*.sh から source される。要 jq。
#
# チェックリスト正本 (repo-standards.json) の解決チェーン:
#   ① $REPO_STANDARDS_JSON (開発・テスト用の上書き)
#   ② ~/.claude/repo-standards.json (主経路。setup リポの ansible が張る symlink)
#   ③ ~/.setup/claude/repo-standards.json (playbook 未実行の新マシン向けフォールバック)
#
# 出力契約 (rs-audit-min.sh を除く全 rs-*.sh 共通): JSON Lines。1 チェック = 1 行
#   {"id","layer","level","status","detail","fix"?}
#   status: ok / ng (required 違反) / warn (recommended 違反・rejected 検出)
#         / skip (対象外・前提不足。理由を detail に) / manual (LLM 判定へ委譲)
# スクリプトはレポートツールでありゲートではない。チェック結果がどうであれ exit 0 を保ち、
# スクリプト自体の異常 (jq 不在など) のみ非 0 で落ちる。
#
# この JSON Lines を保存し、LLM 判定 (verdict) と適用判断 (decision) を足して
# 監査 → 修正へ引き渡すのが rs-findings.sh。行スキーマの拡張分はそちらの冒頭を参照。
# rs-audit-min.sh はこの JSON Lines を人間 / LLM 向けの圧縮テキストへ畳む出口で、
# トークン最小化のため出力契約から外れる (理由はそちらの冒頭を参照)。

resolve_standards() {
  local p
  for p in "${REPO_STANDARDS_JSON:-}" "$HOME/.claude/repo-standards.json" "$HOME/.setup/claude/repo-standards.json"; do
    [ -n "$p" ] && [ -r "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

# emit <id> <layer> <level> <status> <detail> [fix] [fix_kind]
# fix_kind は修正の性質 (deterministic / generative / destructive) を正本が宣言するための
# 任意フィールド。修正側 (repo-audit-fix) の承認粒度がこれで決まる。正本がまだ持たない
# 項目では空になり出力から落ちる — 値の妥当性は正本側のテストが守る (ADR 0006 と同じ契約)
emit() {
  jq -cn --arg id "$1" --arg layer "$2" --arg level "$3" --arg status "$4" \
    --arg detail "$5" --arg fix "${6:-}" --arg fix_kind "${7:-}" \
    '{id:$id,layer:$layer,level:$level,status:$status,detail:$detail}
     + (if $fix != "" then {fix:$fix} else {} end)
     + (if $fix_kind != "" then {fix_kind:$fix_kind} else {} end)'
}

# 検査失敗時の status を level から導く (required → ng / recommended・rejected → warn)
fail_status() {
  case "$1" in required) echo ng ;; *) echo warn ;; esac
}

# 正本不在の共通レポート (呼び出し側はこの後 exit 0 する)
emit_manifest_missing() {
  emit standards-manifest-missing meta required ng \
    "チェックリスト正本 repo-standards.json が見つからない" \
    "setup リポ (github.com/shinyaoguri/setup) を clone し ansible-playbook playbook_sillicon_mac.yml --tags claude を実行する"
}
