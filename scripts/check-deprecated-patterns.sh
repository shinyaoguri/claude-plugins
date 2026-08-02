#!/usr/bin/env bash
# 公式が非推奨・廃止と明言しているプラグイン構成パターンの検査。要 jq。
# CI (ci.yml) とローカルで共用。採用の経緯は docs/decisions/0004-deprecation-guard.md、
# 各項目の根拠は公式ドキュメント (https://code.claude.com/docs/en/plugins-reference /
# plugin-marketplaces / plugins)。
# なお version の二重指定の禁止 (同じく公式非推奨) は check-consistency.sh が検査する。
#
# 検査項目 (それぞれ公式ドキュメントの記述に対応):
#   1. commands/ ディレクトリの不使用      — "Use skills/ for new plugins"
#   2. .claude-plugin/ にはマニフェストのみ — "Only plugin.json goes inside .claude-plugin/"
#   3. プラグイン root の CLAUDE.md 禁止    — "A CLAUDE.md file at the plugin root is not
#                                            loaded as project context"
#   4. shell 実行フィールドで ${user_config.*} 禁止 — v2.1.207+ でロードエラーになる
#   5. プラグイン外へのパス参照 (../) 禁止  — キャッシュへのコピー後に解決できない
#   6. hook command のプラグイン内パスは ${CLAUDE_PLUGIN_ROOT} を前置する
#   7. plugin.json の top-level monitors 禁止 — experimental.monitors へ
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
err() { echo "NG: $*" >&2; fail=1; }

# --- 1. commands/ は使わない (新規は skills/<name>/SKILL.md) -------------------
for d in plugins/*/commands; do
  [ -e "$d" ] || continue
  err "$d: commands/ は互換維持のみで新規利用は非推奨。skills/<name>/SKILL.md に置く"
done

# --- 2. .claude-plugin/ にはマニフェスト以外を置かない -------------------------
while IFS= read -r f; do
  case "$f" in
    .claude-plugin/marketplace.json) ;;
    plugins/*/.claude-plugin/plugin.json) ;;
    *) err "$f: .claude-plugin/ にはマニフェスト (plugin.json / marketplace.json) 以外を置かない" ;;
  esac
done < <(find .claude-plugin plugins/*/.claude-plugin -type f 2>/dev/null)

# --- 3. プラグイン root の CLAUDE.md は読み込まれない ---------------------------
for f in plugins/*/CLAUDE.md; do
  [ -e "$f" ] || continue
  err "$f: プラグイン内の CLAUDE.md はコンテキストに読み込まれない。skills/ か hooks で供給する"
done

# --- 4-6. プラグインの設定 JSON (plugin.json / hooks/*.json / .mcp.json) --------
for j in plugins/*/.claude-plugin/plugin.json plugins/*/hooks/*.json plugins/*/.mcp.json; do
  [ -e "$j" ] || continue
  jq -e . "$j" >/dev/null || { err "$j が JSON として不正"; continue; }

  # 4. shell で実行される command 値に ${user_config.*} を書かない (v2.1.207+ でエラー)
  while IFS= read -r c; do
    err "$j: hook command に \${user_config.*} がある。CLAUDE_PLUGIN_OPTION_<KEY> 環境変数で読む: $c"
  done < <(jq -r '.. | objects | select(.type? == "command") | .command // empty' "$j" \
             | grep -F '${user_config.' || true)

  # 5. ../ でプラグイン root の外を参照しない (キャッシュコピー後に壊れる)
  while IFS= read -r v; do
    err "$j: プラグイン外へのパス参照 (../) はインストール後に解決できない: $v"
  done < <(jq -r '.. | strings' "$j" | grep -F '../' || true)

  # 6. hook command のプラグイン内パスは ${CLAUDE_PLUGIN_ROOT} 経由で書く
  while IFS= read -r c; do
    case "$c" in
      *'${CLAUDE_PLUGIN_ROOT}'*|*'$CLAUDE_PLUGIN_ROOT'*) ;;
      *hooks/*|*scripts/*)
        err "$j: hook command のプラグイン内パスは \${CLAUDE_PLUGIN_ROOT} を前置する (cwd 非依存にする): $c" ;;
    esac
  done < <(jq -r '.. | objects | select(.type? == "command") | .command // empty' "$j")
done

# --- 7. monitors は experimental.monitors 配下に置く ---------------------------
for pj in plugins/*/.claude-plugin/plugin.json; do
  if jq -e 'has("monitors")' "$pj" >/dev/null; then
    err "$pj: top-level の monitors は experimental.monitors へ移す (experimental コンポーネント)"
  fi
done

[ "$fail" -eq 0 ] && echo "OK: deprecated-patterns"
exit "$fail"
