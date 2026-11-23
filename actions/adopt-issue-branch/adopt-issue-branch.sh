#!/usr/bin/env bash
# Issue Worker のブランチが前の run で push されたまま PR になっていなければ、エージェントを走らせずに
# そのブランチをそのまま PR にする。
#
# 採用するのは、remote にブランチがあり、base より先のコミットを持ち、そのブランチから作った PR が
# 一つも無い (open / closed / merged のいずれも) ときだけ。open PR があるなら再実行はそこへ積み、
# closed / merged の PR があるならブランチは片付け済みの古いものなので、どちらも採用しない。
# PR 文面はエージェントの出力が無いので Issue のタイトルと Closes だけで組み立てる。
#
# 入力 (環境変数):
#   BRANCH   - Issue Worker の head ブランチ名
#   BASE     - PR の base ブランチ名
#   ISSUE    - 対象 Issue 番号
#   TITLE    - Issue のタイトル (PR の title にする)
#   LABELS   - PR に付けるラベル (スペース区切り、任意)
#   DRAFT    - "true" なら draft PR にする (任意)
#   GH_TOKEN - gh 認証用
#   GH_CMD   - テストで gh を差し替える (既定: gh)
# 出力 (GITHUB_OUTPUT があれば): pr_url / pr_number (採用しなかったときは空)
set -euo pipefail

: "${BRANCH:?BRANCH is required}"
: "${BASE:?BASE is required}"
: "${ISSUE:?ISSUE is required}"
: "${TITLE:?TITLE is required}"

GH_CMD="${GH_CMD:-gh}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

output() {
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
}

skip() {
  echo "==> not adopting ${BRANCH}: $1" >&2
  output pr_url ""
  output pr_number ""
  exit 0
}

if ! git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null; then
  skip "no such branch on origin"
fi

# squash マージされたブランチは base の祖先にならず先行コミットが残って見えるため、
# コミット数ではなく PR の有無で片付け済みかを判定する。
prs="$("$GH_CMD" pr list --head "$BRANCH" --state all --json number --jq 'length')"
[ "$prs" = "0" ] || skip "a PR from it already exists"

git fetch origin "$BASE" "$BRANCH" >&2
ahead="$(git rev-list --count "origin/${BASE}..origin/${BRANCH}")"
[ "$ahead" != "0" ] || skip "no commits ahead of ${BASE}"

purpose="- Closes #${ISSUE}"$'\n\n'"前の run で push されたまま PR になっていなかったブランチを、エージェントを再実行せずに PR にした。"
body="$("${SCRIPT_DIR}/../create-issue-pr/pr-body-template.sh" "$purpose" "" "")"

create_args=()
[ "${DRAFT:-}" = "true" ] && create_args+=(--draft)
pr_url="$("$GH_CMD" pr create --base "$BASE" --head "$BRANCH" --title "$TITLE" --body "$body" \
  ${create_args[@]+"${create_args[@]}"} | tail -n 1)"
echo "==> adopted ${BRANCH} as ${pr_url}" >&2

# gh pr create --label は無いラベルで PR 作成ごと失敗するため、作った後に 1 つずつ付ける。
for label in ${LABELS:-}; do
  "$GH_CMD" pr edit "$pr_url" --add-label "$label" >/dev/null \
    || echo "::warning::label '${label}' could not be added to ${pr_url}" >&2
done

output pr_url "$pr_url"
output pr_number "$(printf '%s' "$pr_url" | grep -oE '/pull/[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
