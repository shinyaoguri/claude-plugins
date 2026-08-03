#!/usr/bin/env bash
# repo-standards プラグイン共通ライブラリ。各 rs-*.sh から source される。要 jq。
#
# チェックリスト正本 (repo-standards.json) の解決チェーン:
#   ① $REPO_STANDARDS_JSON (開発・テスト用の上書き)
#   ② ~/.claude/repo-standards.json (主経路。setup リポの ansible が張る symlink)
#   ③ ~/.setup/claude/repo-standards.json (playbook 未実行の新マシン向けフォールバック)
#
# 出力契約 (全 rs-*.sh 共通): JSON Lines。1 チェック = 1 行
#   {"id","layer","level","status","detail","fix"?}
#   status: ok / ng (required 違反) / warn (recommended 違反・rejected 検出)
#         / skip (対象外・前提不足。理由を detail に) / manual (LLM 判定へ委譲)
# スクリプトはレポートツールでありゲートではない。チェック結果がどうであれ exit 0 を保ち、
# スクリプト自体の異常 (jq 不在など) のみ非 0 で落ちる。

resolve_standards() {
  local p
  for p in "${REPO_STANDARDS_JSON:-}" "$HOME/.claude/repo-standards.json" "$HOME/.setup/claude/repo-standards.json"; do
    [ -n "$p" ] && [ -r "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

# emit <id> <layer> <level> <status> <detail> [fix]
emit() {
  jq -cn --arg id "$1" --arg layer "$2" --arg level "$3" --arg status "$4" \
    --arg detail "$5" --arg fix "${6:-}" \
    '{id:$id,layer:$layer,level:$level,status:$status,detail:$detail}
     + (if $fix != "" then {fix:$fix} else {} end)'
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
