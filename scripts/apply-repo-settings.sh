#!/usr/bin/env bash
# GitHub のリポジトリ設定を .github/repo-settings.json のとおりに保つ。要 gh / jq。
#
#   ./scripts/apply-repo-settings.sh           # 差分を報告する (差分ありで exit 1)
#   ./scripts/apply-repo-settings.sh --apply   # 定義どおりに適用する
#
# GitHub のリポジトリ設定は git 管理外なので、変更しても diff にも履歴にも残らない。
# 定義をリポ内に置くことで (1) 変更が PR の diff に現れて根拠が残り、(2) 承認が
# PR レビューに一元化され、(3) 手で変えられてもドリフトとして CI が検出する
# (ADR 0008)。
#
# 定義に書いたキーだけを見る。書いていない設定には触れないので、段階的に
# 管理範囲を広げられる。ネストしたオブジェクト (security_and_analysis など) も
# 定義に書いた深さだけを見る (兄弟キーは API が足して返すため無視する)。
set -uo pipefail
cd "$(dirname "$0")/.."

def=${REPO_SETTINGS_DEF:-.github/repo-settings.json}   # テスト用の注入口
[ -r "$def" ] || { echo "NG: $def が無い" >&2; exit 1; }

mode=check
[ "${1:-}" = "--apply" ] && mode=apply

command -v gh >/dev/null 2>&1 || { echo "NG: gh が無い" >&2; exit 1; }
repo=${REPO_SETTINGS_REPO:-}                          # テスト用の注入口
if [ -z "$repo" ]; then
  repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
    || { echo "NG: GitHub 上のリポジトリを特定できない" >&2; exit 1; }
fi

drift=0
note() { echo "DRIFT: $*"; drift=1; }

# ---- リポジトリ設定 ----
want_repo=$(jq -c .repo "$def")
current_repo=${REPO_SETTINGS_CURRENT_JSON:-}          # テスト用の注入口
if [ -z "$current_repo" ]; then
  current_repo=$(gh api "repos/$repo" 2>/dev/null) \
    || { echo "NG: repos/$repo を取得できない (トークン権限を確認)" >&2; exit 1; }
fi

# want に書いたキーだけを have から再帰的に射影する。GitHub API のレスポンスは
# 定義に書かない兄弟キーを含む (security_and_analysis なら dependabot_security_updates
# など) ため、キー単位の完全一致ではネストしたオブジェクトを管理範囲に置けない。
# want にあって have に無いキーは射影結果から落ちるので、欠損は差分として現れる
project='
def project($have; $want):
  if ($want | type) == "object" and ($have | type) == "object"
  then reduce ($want | keys_unsorted[]) as $k
         ({}; if ($have | has($k)) then . + {($k): project($have[$k]; $want[$k])} else . end)
  else $have end;
'

while IFS= read -r k; do
  # -S でキー順を揃える (文字列比較なので、順序違いを差分にしない)
  want=$(jq -cS --arg k "$k" '.[$k]' <<<"$want_repo")
  # `.[$k] // null` は使えない。jq の // は false も代替してしまい、false を
  # 設定した項目が常に差分に見える
  have=$(jq -cS --argjson want "$want" --arg k "$k" \
    "$project"'if has($k) then project(.[$k]; $want) else null end' <<<"$current_repo")
  [ "$want" = "$have" ] || note "repo.$k: $have → $want"
done < <(jq -r '.repo | keys[]' "$def")

# ---- ruleset ----
# 定義したキーだけを正規化して比較する (API は id / created_at 等を足して返すため)。
# rules は順序が保証されないので type でソートする
normalize_ruleset() {
  jq -S '{
    name, target, enforcement,
    bypass_actors: (.bypass_actors // []),
    conditions,
    rules: (.rules | sort_by(.type))
  }'
}

want_rs=$(jq -c .ruleset "$def" | normalize_ruleset)
rs_name=$(jq -r .ruleset.name "$def")

rulesets=${REPO_RULESETS_JSON:-}                       # テスト用の注入口
if [ -z "$rulesets" ]; then
  rulesets=$(gh api "repos/$repo/rulesets" 2>/dev/null) || rulesets=""
fi

if [ -z "$rulesets" ]; then
  # 読めない場合はゲートにしない。CI のトークン権限は環境によって違う
  echo "SKIP: ruleset を取得できない (トークン権限を確認)"
else
  rs_id=$(jq -r --arg n "$rs_name" '.[] | select(.name == $n) | .id' <<<"$rulesets" | head -1)
  if [ -z "$rs_id" ]; then
    note "ruleset '$rs_name' が存在しない"
  else
    have_rs=${REPO_RULESET_DETAIL_JSON:-}
    [ -z "$have_rs" ] && have_rs=$(gh api "repos/$repo/rulesets/$rs_id" 2>/dev/null)
    have_rs=$(normalize_ruleset <<<"$have_rs")
    if [ "$want_rs" != "$(printf '%s' "$have_rs")" ]; then
      note "ruleset '$rs_name' の内容が定義と違う"
      diff <(printf '%s\n' "$have_rs") <(printf '%s\n' "$want_rs") | sed 's/^/       /'
    fi
  fi
fi

# ---- 結果 ----
if [ "$mode" = check ]; then
  if [ "$drift" -eq 0 ]; then
    echo "OK: repo-settings (定義どおり)"
    exit 0
  fi
  echo "定義と食い違っている。./scripts/apply-repo-settings.sh --apply で合わせる" >&2
  exit 1
fi

# ---- 適用 ----
if [ "$drift" -eq 0 ]; then
  echo "OK: repo-settings (適用不要)"
  exit 0
fi

jq -c .repo "$def" | gh api -X PATCH "repos/$repo" --input - >/dev/null
echo "適用: リポジトリ設定"

if [ -n "$rulesets" ]; then
  rs_id=$(jq -r --arg n "$rs_name" '.[] | select(.name == $n) | .id' <<<"$rulesets" | head -1)
  if [ -z "$rs_id" ]; then
    jq -c .ruleset "$def" | gh api -X POST "repos/$repo/rulesets" --input - >/dev/null
    echo "適用: ruleset '$rs_name' を作成"
  else
    jq -c .ruleset "$def" | gh api -X PUT "repos/$repo/rulesets/$rs_id" --input - >/dev/null
    echo "適用: ruleset '$rs_name' を更新"
  fi
fi
