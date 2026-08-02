#!/usr/bin/env bash
# プラグインの version を bump する。version の正は plugin.json のみ
# (marketplace.json には書かない)。要 jq。
# 使い方: scripts/bump-version.sh <plugin-name> <major|minor|patch>
set -euo pipefail
cd "$(dirname "$0")/.."

name="${1:?usage: bump-version.sh <plugin-name> <major|minor|patch>}"
kind="${2:?usage: bump-version.sh <plugin-name> <major|minor|patch>}"
pj="plugins/$name/.claude-plugin/plugin.json"
[ -f "$pj" ] || { echo "NG: $pj が無い" >&2; exit 1; }

cur=$(jq -r .version "$pj")
[[ "$cur" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "NG: 現 version が semver でない: $cur" >&2; exit 1; }
IFS=. read -r ma mi pa <<<"$cur"
case "$kind" in
  major) new="$((ma+1)).0.0" ;;
  minor) new="$ma.$((mi+1)).0" ;;
  patch) new="$ma.$mi.$((pa+1))" ;;
  *) echo "NG: 不明な種別「${kind}」(major|minor|patch)" >&2; exit 2 ;;
esac

jq --arg v "$new" '.version = $v' "$pj" > "$pj.tmp" && mv "$pj.tmp" "$pj"
echo "$name: $cur -> $new"
