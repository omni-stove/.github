#!/usr/bin/env bash
# 作業ツリーのうち PATHSPEC の範囲を HEAD と比べ、追加・変更・削除を git apply できる binary patch にして OUT に書く。
# actions/regen-diff から呼ばれる。差分が無ければ空のファイルを書く。
#
# 入力 (環境変数):
#   PATHSPEC      - 範囲 (git の pathspec。1 行に 1 つ。空行は無視する)
#   OUT           - patch の書き出し先
#   GIT_CMD       - git コマンド名 (既定: git)
#   GITHUB_OUTPUT - 出力先 (changed)
set -euo pipefail

: "${PATHSPEC:?PATHSPEC is required}"
: "${OUT:?OUT is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

GIT_CMD="${GIT_CMD:-git}"

specs=()
while IFS= read -r spec; do
  spec="$(printf '%s' "$spec" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -z "$spec" ] || specs+=("$spec")
done <<<"$PATHSPEC"
[ "${#specs[@]}" -gt 0 ] || { echo "::error::pathspec が空"; exit 1; }

mkdir -p "$(dirname "$OUT")"

# 新しくできたファイル (Unity の .meta など) も拾うには index に載せる必要がある。呼び出し側のジョブの index を
# 書き換えないよう、写しの index に載せて比べる。add を pathspec で絞らないのは、まだどのファイルにも当たらない
# pathspec (.meta の無いリポジトリの "*.meta" など) で add が落ちるため。
index="$(mktemp)"
trap 'rm -f "$index"' EXIT
cp "$("${GIT_CMD}" rev-parse --git-path index)" "$index"
GIT_INDEX_FILE="$index" "${GIT_CMD}" add -A
GIT_INDEX_FILE="$index" "${GIT_CMD}" diff --cached --binary HEAD -- "${specs[@]}" > "$OUT"

if [ -s "$OUT" ]; then
  echo "changed=true" >> "$GITHUB_OUTPUT"
  echo "::notice::作り直しで差分が出た。CI Gate が PR に積む:"
  GIT_INDEX_FILE="$index" "${GIT_CMD}" diff --cached --name-status HEAD -- "${specs[@]}"
else
  echo "changed=false" >> "$GITHUB_OUTPUT"
  echo "No regenerated changes."
fi
