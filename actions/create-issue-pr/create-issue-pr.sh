#!/usr/bin/env bash
# Issue 起点のジョブ (issue-worker.yml) で、エージェントが編集した内容を PR にする。
# エージェントにはコード編集と PR 文面 (構造化出力) だけを担当させ、branch・ラベル・draft の
# 確定と commit / push / PR 作成という決定論手順はこのスクリプトが握る。
#
# PR 文面 (コミットメッセージ・title・本文の各節) はエージェントの構造化出力から取る。
# いずれかが空なら既定文言で埋める。PR body は pr-body-template.sh で組み立てる。
# 変更が無ければ (エージェントが何も編集しなかった) PR を作らず、理由を Issue にコメントして終了コード 0。
#
# 入力 (環境変数):
#   STRUCTURED     - エージェントの structured_output (JSON 文字列)。.message/.title と
#                    テンプレ節 (.purpose/.approach/.verification/.review_points) を使う。
#                    .closes_issue が true なら Issue を "Closes"、それ以外は "refs" で参照する
#   BRANCH         - 作成する PR の head ブランチ名
#   BASE           - PR の base ブランチ名
#   ISSUE          - 対象 Issue 番号 (任意)。「目的」節の先頭に Closes / refs で参照する
#   LABELS         - PR に付けるラベル (スペース区切り、任意)
#   DRAFT          - "true" なら draft PR にする (任意)
#   START_SHA      - エージェント実行前の HEAD (任意)。エージェントが commit してしまった変更も拾う
#   GH_TOKEN       - gh 認証用
#   GH_CMD / CREATE_PR_CMD - テストで差し替える (既定: gh / 隣の create-pr.sh)
# 出力 (GITHUB_OUTPUT があれば): pr_url / pr_number (PR を作らなかったときは空)
set -euo pipefail

: "${BRANCH:?BRANCH is required}"
: "${BASE:?BASE is required}"

GH_CMD="${GH_CMD:-gh}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATE_PR_CMD="${CREATE_PR_CMD:-${SCRIPT_DIR}/create-pr.sh}"

field() {
  printf '%s' "${STRUCTURED:-}" | jq -er --arg k "$1" '.[$k] // ""' 2>/dev/null || echo ""
}
message="$(field message)"
title="$(field title)"
purpose="$(field purpose)"
approach="$(field approach)"
verification="$(field verification)"
review_points="$(field review_points)"
closes_issue="$(printf '%s' "${STRUCTURED:-}" | jq -r '.closes_issue == true' 2>/dev/null || echo "false")"
if [ "${closes_issue}" = "true" ]; then
  issue_keyword="Closes"
else
  issue_keyword="refs"
fi

# GitHub はコミットメッセージや PR 本文の close 系キーワードでも Issue を閉じる。閉じるかを
# closes_issue だけで決めるため、エージェントの文面からはキーワードを外して "#<番号>" だけ残す。
strip_closing_keywords() {
  printf '%s' "$1" | perl -pe 's/\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b:?\s*(?=(?:[\w.-]+\/[\w.-]+)?#\d)//gi'
}
message="$(strip_closing_keywords "${message}")"
title="$(strip_closing_keywords "${title}")"
purpose="$(strip_closing_keywords "${purpose}")"
approach="$(strip_closing_keywords "${approach}")"
verification="$(strip_closing_keywords "${verification}")"
review_points="$(strip_closing_keywords "${review_points}")"

[ -n "${message}" ] || message="${title:-Apply changes from issue}"
[ -n "${title}" ] || title="${message}"

output() {
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
}

has_changes=false
[ -z "$(git status --porcelain)" ] || has_changes=true
if [ -n "${START_SHA:-}" ] && [ "$(git rev-parse HEAD)" != "${START_SHA}" ]; then
  has_changes=true
fi

# PR が無いと Issue 側は無言になるので、理由を Issue にコメントして残す。コメントの失敗は成否に影響させない。
if [ "$has_changes" = false ]; then
  echo "no changes to commit; skipping PR" >&2
  if [ -n "${ISSUE:-}" ]; then
    comment="エージェントはコードを変更せずに終了したため、PR は作成していない。"$'\n\n'"> ${message//$'\n'/$'\n'> }"
    if [ -n "${GITHUB_RUN_ID:-}" ]; then
      comment="${comment}"$'\n\n'"実行ログ: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
    fi
    "${GH_CMD}" issue comment "${ISSUE}" --body "${comment}" >/dev/null \
      || echo "issue comment (no PR) failed (non-fatal)" >&2
  fi
  output pr_url ""
  output pr_number ""
  exit 0
fi

issue_ref=""
[ -z "${ISSUE:-}" ] || issue_ref="- ${issue_keyword} #${ISSUE}"$'\n\n'
body="$("${SCRIPT_DIR}/pr-body-template.sh" "${issue_ref}${purpose}" "${approach}" "${verification}" "${review_points}")"

extra_args=()
for label in ${LABELS:-}; do
  extra_args+=(--label "${label}")
done
[ "${DRAFT:-}" = "true" ] && extra_args+=(--draft)

pr_url="$("${CREATE_PR_CMD}" "${BRANCH}" "${BASE}" "${message}" "${title}" "${body}" \
  ${extra_args[@]+"${extra_args[@]}"} | tee /dev/stderr | tail -n 1)"
output pr_url "${pr_url}"
output pr_number "$(printf '%s' "${pr_url}" | grep -oE '/pull/[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
