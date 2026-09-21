#!/usr/bin/env bash
# 標準 (repo-standards.json) が各リポに設置させたものが、設置先で実際に使われているかを測る。
# 要 jq と gh (認証済み。非公開リポも見るので CI では回さず手元で実行する)。
#
#   scripts/measure-standards-usage.sh [<項目 id>...]     # 省略時は測れる全項目
#
#     OWNER=<login>        対象の持ち主 (既定: gh の認証ユーザー)
#     REPOS="o/a o/b"      対象リポを直接指定する (既定: OWNER の source リポのうち、アーカイブされて
#                          おらず直近 SINCE_DAYS 日に push のあるもの)
#     SINCE_DAYS=90        「直近」の幅
#     SAMPLE=50            1 リポあたりに見る Issue / PR の件数
#
# detail にはリポ名が入る。非公開リポの名前を含むので、**detail を公開の場 (正本の result・PR・Issue) へ
# そのまま貼らない** — 外へ出すのは installed / used の件数だけにする。
#
# 出力は項目ごとに JSON Lines 1 行:
#   {"id":…,"installed":設置リポ数,"used":うち使われているリポ数,"skipped":測れなかったリポ数,"detail":"リポごとの内訳"}
#
# このプラグインはリポジトリを設定する道具なので、呼ばれた回数は有用性の物差しにならない。測るのは
# 「設置させたものが使われているか」で、結果は正本の evidence (kind: observation) に measured_at と
# ともに書く。180 日で期限が切れ、check-repo-standards.sh が PR CI を落として再測定を強制する (ADR 0029)。
#
# 読み取りの gh 呼び出ししかしない。1 リポで gh が失敗したら、そのリポを skipped に数えて続ける
# (非公開リポの権限や一時的な失敗で、測定全体を止めない)。常に exit 0 — レポートであってゲートではない。
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "jq が要る" >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { echo "gh が要る" >&2; exit 2; }

since_days=${SINCE_DAYS:-90}
sample=${SAMPLE:-50}
all_ids="issue-template-exists pr-template-exists dependabot-config changelog-exists adr-exists scheduled-freshness pr-visual-evidence"

ids=${*:-$all_ids}
for id in $ids; do
  case " $all_ids " in *" $id "*) ;; *) echo "測り方を持たない項目: $id (測れるのは: $all_ids)" >&2; exit 2 ;; esac
done

# 日付の比較は ISO 8601 の文字列比較で足りる (同じ書式・UTC)。GNU / BSD の date 両対応
cutoff=$(date -u -v-"${since_days}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-${since_days} days" +%Y-%m-%dT%H:%M:%SZ)

if [ -n "${REPOS:-}" ]; then
  repos=$REPOS
else
  owner=${OWNER:-$(gh api user --jq .login 2>/dev/null)} || owner=""
  [ -n "$owner" ] || { echo "対象の持ち主を決められない (OWNER か REPOS を渡す)" >&2; exit 2; }
  repos=$(gh repo list "$owner" --source --no-archived --limit 200 --json nameWithOwner,pushedAt 2>/dev/null \
    | jq -r --arg c "$cutoff" '.[] | select(.pushedAt > $c) | .nameWithOwner') || repos=""
fi
[ -n "$repos" ] || { echo "対象リポが 0 件" >&2; exit 2; }

# ---- 1 リポぶんの材料 (項目をまたいで使い回す。失敗したら return 1 = このリポは skipped) ----
load_repo() {
  local r=$1
  tree=$(gh api "repos/$r/git/trees/HEAD?recursive=1" --jq '.tree[].path' 2>/dev/null) || return 1
  # Issue / PR は複数の項目が使うので、ここで 1 回だけ取る (probe は $(...) の中で走るので、
  # probe の中で取ると次の項目へ持ち越せない)。要る項目が選ばれていなければ取らない
  issues="" prs=""
  case " $ids " in *" issue-template-exists "*)
    issues=$(gh issue list -R "$r" --state all --limit "$sample" --json body 2>/dev/null) || return 1 ;; esac
  case " $ids " in *" pr-template-exists "*|*" pr-visual-evidence "*)
    prs=$(gh pr list -R "$r" --state all --limit "$sample" --json body,author,state 2>/dev/null) || return 1 ;; esac
}
in_tree() { grep -qiE "$1" <<<"$tree"; }
first_in_tree() { grep -iE "$1" <<<"$tree" | head -1; }
# 使用が 1/3 以上なら「使われている」。ADR 0029 の見直し基準と同じ線
enough() { [ "$2" -gt 0 ] && [ $(( $1 * 3 )) -ge "$2" ]; }

# ---- 項目ごとの測り方。出力は none (未設置・対象外) / used:<内訳> / unused:<内訳>。失敗は return 1 ----

# テンプレートのファイル群から「本文に残るはずの見出し」を JSON 配列で返す。md は見出し行、
# フォーム (yml) は label (GitHub が「### ラベル」として本文へ展開する)
template_heads() { # $1=repo $2..=パス
  local r=$1 f; shift
  for f in "$@"; do
    gh api "repos/$r/contents/$f" -H 'Accept: application/vnd.github.raw' 2>/dev/null
    echo
  done | sed -nE 's/^#{2,3} +(.+)$/\1/p; s/^ *label: *["'"'"']?([^"'"'"']+)["'"'"']? *$/\1/p' \
       | jq -Rsc 'split("\n") | map(select(length > 1)) | unique'
}
# 本文が見出しの半分以上 (最低 1 つ) を含む件数。gh issue create / gh pr create --body はテンプレートを
# 通らないので、「テンプレートが在る」ことと「その構成で書かれている」ことは別に測る必要がある
count_following() { # $1=heads(JSON) $2=items(JSON、.body を持つ配列)
  jq --argjson h "$1" '[.[] | (.body // "") as $b
    | select(([$h[] | select(. as $x | $b | contains($x))] | length) as $hit
             | $hit > 0 and $hit * 2 >= ($h | length))] | length' <<<"$2"
}

probe_issue_template_exists() {
  local files heads n k
  files=$(grep -E '^\.github/ISSUE_TEMPLATE/[^/]+\.(md|ya?ml)$' <<<"$tree" | grep -vE '/config\.ya?ml$' | head -6) || true
  [ -n "$files" ] || { echo none; return; }
  # shellcheck disable=SC2086
  heads=$(template_heads "$1" $files) || return 1
  [ "$(jq 'length' <<<"$heads")" -gt 0 ] || return 1
  n=$(jq 'length' <<<"$issues")
  # テンプレートは複数あり Issue はそのどれか 1 つに沿うので、全見出しの半分でなく 2 つ以上で数える
  k=$(jq --argjson h "$heads" '[.[] | (.body // "") as $b
        | select(([$h[] | select(. as $x | $b | contains($x))] | length) >= ([2, ($h | length)] | min))] | length' <<<"$issues")
  if enough "$k" "$n"; then echo "used:$k/$n"; else echo "unused:$k/$n"; fi
}

probe_pr_template_exists() {
  local p heads humans n k
  p=$(first_in_tree '^(\.github/|docs/)?pull_request_template\.md$') || true
  [ -n "$p" ] || { echo none; return; }
  heads=$(template_heads "$1" "$p") || return 1
  [ "$(jq 'length' <<<"$heads")" -gt 0 ] || return 1
  # bot の PR はテンプレートを通らないので母数から外す
  humans=$(jq -c '[.[] | select(.author.is_bot | not)]' <<<"$prs")
  n=$(jq 'length' <<<"$humans")
  k=$(count_following "$heads" "$humans")
  if enough "$k" "$n"; then echo "used:$k/$n"; else echo "unused:$k/$n"; fi
}

probe_dependabot_config() {
  in_tree '^\.github/dependabot\.ya?ml$' || { echo none; return; }
  local d n m
  d=$(gh pr list -R "$1" --state all --limit "$sample" --author app/dependabot --json state 2>/dev/null) || return 1
  n=$(jq 'length' <<<"$d"); m=$(jq '[.[] | select(.state == "MERGED")] | length' <<<"$d")
  if [ "$m" -gt 0 ]; then echo "used:merged $m/$n"; else echo "unused:merged $m/$n"; fi
}

probe_changelog_exists() {
  local p rel last
  p=$(first_in_tree '^(docs/)?CHANGELOG(\.md)?$') || true
  [ -n "$p" ] || { echo none; return; }
  # リリースしないリポは監査でも対象外 (builtin_changelog_exists が skip にする)
  rel=$(gh api "repos/$1/releases/latest" --jq '.published_at' 2>/dev/null) || { echo none; return; }
  last=$(gh api "repos/$1/commits?path=$p&per_page=1" --jq '.[0].commit.committer.date' 2>/dev/null) || return 1
  # 直近のリリースの日 (の 1 日前) 以降に CHANGELOG が更新されていれば、リリースに追随している
  if [[ "${last:0:10}" > "$(jq -rn --arg d "$rel" '($d | fromdateiso8601) - 172800 | strftime("%Y-%m-%d")')" ]]; then
    echo "used:更新 ${last:0:10} / リリース ${rel:0:10}"
  else
    echo "unused:更新 ${last:0:10} / リリース ${rel:0:10}"
  fi
}

probe_adr_exists() {
  local dir n last
  dir=$(grep -oE '^docs/(decisions|adr|architecture-decisions)/' <<<"$tree" | head -1) || true
  [ -n "$dir" ] || { echo none; return; }
  n=$(grep -E "^${dir}[^/]+\.md$" <<<"$tree" | grep -vc '/README\.md$')
  [ "$n" -gt 0 ] || { echo "unused:0 本"; return; }
  last=$(gh api "repos/$1/commits?path=${dir%/}&per_page=1" --jq '.[0].commit.committer.date' 2>/dev/null) || return 1
  # 対象は直近に push のあるリポだけなので、その間に 1 本も増えも直りもしないなら書かれていない
  if [[ "$last" > "$cutoff" ]]; then echo "used:$n 本 / 最終 ${last:0:10}"; else echo "unused:$n 本 / 最終 ${last:0:10}"; fi
}

probe_scheduled_freshness() {
  local runs latest
  runs=$(gh run list -R "$1" --event schedule --limit 5 --json conclusion,createdAt 2>/dev/null) || return 1
  # schedule の run が 1 本も無い = 未設置か、一度も起動していない (区別は付かないので対象外に倒す)
  [ "$(jq 'length' <<<"$runs")" -gt 0 ] || { echo none; return; }
  latest=$(jq -r '.[0] | "\(.conclusion) \(.createdAt[0:10])"' <<<"$runs")
  # 赤のまま放置された定期検査は、検知しても誰も閉じていない (claude-plugins#136 が 5 週そうだった)
  if jq -e --arg c "$cutoff" '.[0] | .conclusion == "success" and .createdAt > $c' <<<"$runs" >/dev/null; then
    echo "used:$latest"
  else
    echo "unused:$latest"
  fi
}

probe_pr_visual_evidence() {
  local n k
  n=$(jq '[.[] | select(.author.is_bot | not)] | length' <<<"$prs")
  [ "$n" -gt 0 ] || { echo none; return; }
  k=$(jq '[.[] | select(.author.is_bot | not) | select((.body // "") | test("gyazo\\.com"))] | length' <<<"$prs")
  # GUI を伴わないリポでは 0 が正常なので、1 件でもあれば「この作法が届いている」とみなす
  if [ "$k" -gt 0 ]; then echo "used:$k/$n"; else echo "unused:$k/$n"; fi
}

# ---- 集計 ----
results=$(mktemp)
trap 'rm -f "$results"' EXIT
for r in $repos; do
  if ! load_repo "$r"; then
    for id in $ids; do printf '%s\t%s\tskipped\t\n' "$id" "$r" >> "$results"; done
    continue
  fi
  for id in $ids; do
    if out=$("probe_${id//-/_}" "$r"); then
      printf '%s\t%s\t%s\t%s\n' "$id" "$r" "${out%%:*}" "$( [ "$out" = "${out#*:}" ] || echo "${out#*:}" )" >> "$results"
    else
      printf '%s\t%s\tskipped\t\n' "$id" "$r" >> "$results"
    fi
  done
done

for id in $ids; do
  jq -Rsc --arg id "$id" '
    [split("\n")[] | select(length > 0) | split("\t") | select(.[0] == $id)
     | {repo: (.[1] | split("/") | last), status: .[2], detail: (.[3] // "")}] as $rows
    | {id: $id,
       installed: ([$rows[] | select(.status == "used" or .status == "unused")] | length),
       used:      ([$rows[] | select(.status == "used")] | length),
       skipped:   ([$rows[] | select(.status == "skipped")] | length),
       detail:    ([$rows[] | select(.status == "used" or .status == "unused")
                    | "\(.repo) \(if .status == "used" then "○" else "×" end) \(.detail)"] | join(" / "))}
  ' "$results"
done
exit 0
