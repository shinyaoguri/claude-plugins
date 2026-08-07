#!/usr/bin/env bash
# LLM 判定 (check.type == "llm") の材料をスクリプト側で先に集めて 1 本のテキストにまとめる。
#
#   bash rs-evidence.sh [id...]     # 省略時は正本の llm 項目すべて
#
# なぜスクリプトで集めるのか: LLM 判定のコストの大半は「材料を探す探索」であって
# 「材料を読む」ことではない。ls・git log・gh・jq で決定論的に取れるものを先に畳んで
# 渡せば、判定側はツールをほとんど呼ばずに済み、安いモデル 1 本で完結する。
#
# 秘密情報は値を出さない。.mcp.json / settings.json はキー名と「環境変数参照かリテラルか」
# だけを報告する (直書きの検出には値そのものは要らない。値を渡せば判定のためだけに
# 秘密をサブエージェントのコンテキストへ持ち出すことになる)。
#
# 出力はプレーンテキスト。1 項目 = 「### <id>」+ 判定観点 + 材料。
# 材料の集め方は id ごとの evidence_<id> 関数で、正本に無い / 未実装の id は
# 判定観点だけ出して材料収集を判定側に委ねる (rs-audit-repo.sh の builtin と同じ契約)。
set -uo pipefail
. "$(dirname "$0")/rs-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "rs-evidence: jq が必要 (brew install jq)" >&2; exit 2; }

manifest=$(resolve_standards) || { echo "rs-evidence: 正本 repo-standards.json が見つからない" >&2; exit 2; }
root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "rs-evidence: git リポジトリではない" >&2; exit 2; }
cd "$root"

# 1 ファイルから取り込む上限。CLAUDE.md のように全文が判定精度に直結するものだけ
# 全文を渡し、それでも肥大したリポで青天井にならないよう頭を止める
MAX_LINES=200

# ---- 材料の収集 (id ごと) ----

adr_dir() {
  local p
  for p in docs/decisions docs/adr docs/architecture-decisions; do
    [ -d "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

evidence_adr_covers_decisions() {
  local dir f
  if ! dir=$(adr_dir); then
    echo "ADR ディレクトリが無い (adr-exists 側の指摘に委ねる → この項目は skip)"
    return
  fi
  echo "ADR 一覧 ($dir):"
  # 見出し・状態・4 節の有無まで畳む。全文を渡さずに (2)(3) の観点を判定できる粒度。
  # 文字数での切り詰めはしない (cut -c / awk substr はバイト単位で動く実装があり、
  # 日本語を途中で割ると壊れた UTF-8 が判定側へ流れる)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '  %s | %s | %s | 節: %s\n' \
      "$(basename "$f")" \
      "$(grep -m1 '^# ' "$f" | sed 's/^# //')" \
      "$(grep -m1 '状態' "$f" | sed 's/^[-* ]*//; s/\*\*//g')" \
      "$(grep -oE '\*\*(状態|文脈|決定|影響)\*\*' "$f" | tr -d '*' | sort -u | paste -sd/ -)"
  done < <(find "$dir" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' | sort)
  echo
  echo "直近 30 コミット:"
  git log --oneline -30 2>/dev/null | sed 's/^/  /'
}

evidence_work_log_externalized() {
  local n
  n=$(git log --since='30 days ago' --oneline 2>/dev/null | wc -l | tr -d ' ')
  echo "直近 30 日のコミット数: $n"
  [ "$n" -eq 0 ] && { echo "→ 動いていないリポなので skip"; return; }
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    echo "open Issue:"
    gh issue list --state open --limit 20 --json number,title,comments \
      --jq '.[] | "  #\(.number) \(.title) (コメント \(.comments | length))"' 2>/dev/null \
      || echo "  (取得できず)"
    echo "open PR:"
    gh pr list --state open --limit 10 --json number,title --jq '.[] | "  #\(.number) \(.title)"' 2>/dev/null \
      || echo "  (取得できず)"
  else
    echo "(gh が無い / 未認証のため Issue・PR を確認できない)"
  fi
  echo "計画文書の候補:"
  # 候補が 1 つも無いのは正常なので終了ステータスは見ない。成功を強制するイディオムは
  # 付けない — このスクリプトは set -e ではないので不要なうえ、guardrail の
  # 「検査の素通し」検出に引っかかり、本物の握り潰しと区別がつかなくなる
  ls -1 ROADMAP.md docs/roadmap.md docs/plan.md 2>/dev/null | sed 's/^/  /'
  find docs -maxdepth 2 -type d 2>/dev/null | sed 's/^/  dir: /' | head -10
}

evidence_claude_md_quality() {
  [ -f CLAUDE.md ] || { echo "CLAUDE.md が無い (claude-md-exists 側の指摘に委ねる)"; return; }
  echo "CLAUDE.md: $(wc -l < CLAUDE.md | tr -d ' ') 行 / $(wc -c < CLAUDE.md | tr -d ' ') バイト"
  echo "--- 本文 (先頭 $MAX_LINES 行) ---"
  head -"$MAX_LINES" CLAUDE.md
}

evidence_claude_skills_placement() {
  local f
  [ -d .claude/skills ] || { echo ".claude/skills/ が無い (対象外)"; return; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    echo "--- $f ($(wc -l < "$f" | tr -d ' ') 行) ---"
    # frontmatter (description が起動判定の正本) と見出しだけ。本文は判定に不要。
    # BSD sed は 1,/re/{n,$p} 形式のネストしたアドレスを解釈しないので awk で書く
    awk 'NR==1 && $0=="---" {inside=1; next} inside && $0=="---" {exit} inside' "$f"
    grep -E '^#{1,3} ' "$f" | head -20
  done < <(find .claude/skills -maxdepth 2 -name 'SKILL.md' | sort)
}

evidence_claude_permissions_curated() {
  if [ -f .claude/settings.json ]; then
    echo ".claude/settings.json の permissions:"
    jq -r '.permissions // {} | to_entries[] | "  \(.key): \(.value | join(", "))"' \
      .claude/settings.json 2>/dev/null || echo "  (JSON として読めない)"
  else
    echo ".claude/settings.json が無い (permissions 未整備)"
  fi
  echo "このリポで実際に使うコマンドの手がかり:"
  jq -r '.scripts // {} | to_entries[] | "  npm run \(.key)"' package.json 2>/dev/null | head -10
  grep -hoE '^[a-z][a-z0-9_-]*:' Makefile 2>/dev/null | sed 's/:$//;s/^/  make /' | head -10
  find .github/workflows -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null \
    | xargs grep -hoE 'run: .*' 2>/dev/null | sed 's/^/  CI /' | sort -u | head -15
}

evidence_claude_mcp_config_sane() {
  [ -f .mcp.json ] || { echo ".mcp.json が無い (対象外)"; return; }
  echo "サーバ一覧 (値は出さず、参照形式だけ報告する):"
  # env の各値が ${VAR} 形式か、リテラル直書きかだけを判定して渡す。
  # 直書きの検出に値そのものは不要で、渡せば秘密の持ち出しになる
  jq -r '
    .mcpServers // {} | to_entries[]
    | "  \(.key): command=\(.value.command // .value.url // "?")"
      + ((.value.env // {}) | to_entries
         | map("\n    env \(.key) = " + (if (.value|tostring) | test("^\\$\\{?[A-Za-z_]") then "環境変数参照" else "リテラル直書き" end))
         | join(""))
  ' .mcp.json 2>/dev/null || echo "  (JSON として読めない)"
}

# ---- 出力 ----

ids=("$@")
if [ ${#ids[@]} -eq 0 ]; then
  while IFS= read -r id; do ids+=("$id"); done \
    < <(jq -r '.items[] | select((.check.type // "") == "llm") | .id' "$manifest")
fi

for id in "${ids[@]}"; do
  prompt=$(jq -r --arg id "$id" '.items[] | select(.id == $id) | .check.prompt // ""' "$manifest")
  printf '### %s\n' "$id"
  if [ -n "$prompt" ]; then
    printf '判定観点: %s\n\n' "$prompt"
  else
    printf '判定観点: (正本に %s が無い — 判定不能として skip する)\n\n' "$id"
    continue
  fi
  fn="evidence_$(printf '%s' "$id" | tr '-' '_')"
  if declare -F "$fn" >/dev/null; then
    "$fn"
  else
    echo "(この項目の材料収集は rs-evidence.sh に未実装。判定側が自分で読むこと)"
  fi
  printf '\n'
done

exit 0
