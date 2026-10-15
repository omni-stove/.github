#!/usr/bin/env bash
# lint / test / review の結果を統合し、PR レビューを決定論的に確定する。
# actions/finalize-review から呼ばれる。
#
#   1. レビュー指摘の件数を数える (構造化出力 COMMENTS_JSON の .comments の length)。
#   2. 最終 decision を決める:
#        - lint / test に 1 つでも failure があれば request-changes
#        - failure が無ければ指摘件数で決める: 1 件でもあれば request-changes、0 件なら approve
#   3. reviewer 自身が過去に出した CHANGES_REQUESTED を dismiss してから gh pr review を提出する。
#
# 入力 (環境変数):
#   REPO              - owner/name
#   PR_NUMBER         - PR 番号
#   LINT_TEST_RESULTS - lint/test ジョブの result を空白区切りで列挙したもの
#   COMMENTS_JSON     - review の構造化出力 ({"comments":[...]})。空なら指摘なし。
#   REVIEW_RESULT     - Run Code Review ステップの outcome。success 以外なら実施済みの文言を添えない。
#   GH_TOKEN          - レビュー提出用トークン
#   REVIEWER_LOGIN    - dismiss 対象を絞る reviewer の login (`<app-slug>[bot]`)。空なら dismiss しない。
#   BYPASS_LABELS     - request-changes 本文に添える緊急避難口のラベル (カンマ区切り。空なら案内しない)
#   GH_CMD            - gh コマンド名 (既定: gh)
#   GITHUB_OUTPUT     - 出力先 (decision / review_comment_count / lint_test_failed)
set -euo pipefail

: "${REPO:?REPO is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

GH_CMD="${GH_CMD:-gh}"
LINT_TEST_RESULTS="${LINT_TEST_RESULTS:-}"
COMMENTS_JSON="${COMMENTS_JSON:-}"
REVIEW_RESULT="${REVIEW_RESULT:-}"
REVIEWER_LOGIN="${REVIEWER_LOGIN:-}"
BYPASS_LABELS="${BYPASS_LABELS:-}"

emit() { echo "$1" >> "$GITHUB_OUTPUT"; }

# reviewer bot 自身が過去に出した CHANGES_REQUESTED を dismiss する。
# GitHub は同一レビュアーの CHANGES_REQUESTED を「後から APPROVED を出す」ことでしか解除しない
# ため、毎回の提出前に自分の古い CHANGES_REQUESTED を畳み、「今回の判定だけが残る」状態にする。
# 人間のレビュアーが出した CHANGES_REQUESTED は当然残す。
dismiss_stale_change_requests() {
  local reviews ids id
  if [ -z "$REVIEWER_LOGIN" ]; then
    echo "::warning::REVIEWER_LOGIN が未設定のため、古い CHANGES_REQUESTED の dismiss をスキップします。"
    return 0
  fi
  reviews=$("${GH_CMD}" api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" --paginate 2>/dev/null || echo "")
  if [ -z "$reviews" ]; then
    echo "::warning::既存レビューを取得できなかったため、古い CHANGES_REQUESTED の dismiss をスキップします。"
    return 0
  fi
  ids=$(jq -r --arg login "$REVIEWER_LOGIN" \
    '.[] | select(.state == "CHANGES_REQUESTED") | select(.user.login == $login) | .id' \
    <<<"$reviews" 2>/dev/null || echo "")
  for id in $ids; do
    if "${GH_CMD}" api --method PUT "repos/${REPO}/pulls/${PR_NUMBER}/reviews/${id}/dismissals" \
      -f message="CI を再実行したため、この指摘は最新の判定で置き換えます。" \
      -f event="DISMISS" >/dev/null 2>&1; then
      echo "dismissed stale CHANGES_REQUESTED review ${id}"
    else
      echo "::warning::review ${id} の dismiss に失敗しました (提出は続行します)。"
    fi
  done
}

# --- lint / test に failure があるか。skipped / success / cancelled は failure ではない。
LINT_TEST_FAILED=false
for R in $LINT_TEST_RESULTS; do
  if [ "$R" = "failure" ]; then
    LINT_TEST_FAILED=true
    break
  fi
done

# --- レビュー指摘の件数。壊れた入力は 0 件扱い。
REVIEW_COMMENT_COUNT=$(jq '.comments | if type=="array" then length else 0 end' <<<"${COMMENTS_JSON}" 2>/dev/null || echo 0)
case "$REVIEW_COMMENT_COUNT" in
  '' | *[!0-9]*) REVIEW_COMMENT_COUNT=0 ;;
esac

# --- レビューが失敗 / キャンセルで完了していないか。LLM 障害を「指摘 0 件」と誤認して
# approve しないよう request-changes に倒す (skipped はレビュー対象外なので未完了扱いにしない)。
REVIEW_INCOMPLETE=false
case "$REVIEW_RESULT" in
  failure | cancelled) REVIEW_INCOMPLETE=true ;;
esac

# --- decision を決める。
if [ "$LINT_TEST_FAILED" = "true" ] || [ "$REVIEW_COMMENT_COUNT" -gt 0 ] || [ "$REVIEW_INCOMPLETE" = "true" ]; then
  DECISION=request-changes
else
  DECISION=approve
fi
echo "lint/test failed=${LINT_TEST_FAILED} review_comments=${REVIEW_COMMENT_COUNT} review_incomplete=${REVIEW_INCOMPLETE} -> decision=${DECISION}"

# --- 本文を組み立てる。
REVIEW_EVIDENCE=""
if [ "$REVIEW_RESULT" = "success" ]; then
  REVIEW_EVIDENCE="自動コードレビュー実施済み (指摘 ${REVIEW_COMMENT_COUNT} 件)。"
fi

if [ "$REVIEW_COMMENT_COUNT" -gt 0 ]; then
  REQUEST_CHANGES_BODY="インラインコメントを確認してください。"
elif [ "$LINT_TEST_FAILED" = "true" ]; then
  REQUEST_CHANGES_BODY="lint / test が失敗しています。CI のログを確認してください。"
elif [ "$REVIEW_INCOMPLETE" = "true" ]; then
  REQUEST_CHANGES_BODY="自動コードレビューが完了していません (${REVIEW_RESULT})。CI を再実行してください。"
else
  REQUEST_CHANGES_BODY="CI のログを確認してください。"
fi
# 緊急避難口の案内を request-changes 本文の末尾に添える。CI に止められたその場で
# hotfix フローを提示し、急ぎのときに手段を思い出せるようにする。
if [ -n "$BYPASS_LABELS" ]; then
  # shellcheck disable=SC2016 # バッククォートは Markdown のコードスパンとして literal に出す。
  labels_text="$(printf '%s' "$BYPASS_LABELS" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d' | sed 's/.*/`&`/' | paste -sd '/' - | sed 's#/# / #g')"
  REQUEST_CHANGES_BODY="${REQUEST_CHANGES_BODY} 緊急なら ${labels_text} ラベルでマージできます。"
fi
if [ -n "$REVIEW_EVIDENCE" ]; then
  REQUEST_CHANGES_BODY="${REQUEST_CHANGES_BODY}

${REVIEW_EVIDENCE}"
fi

APPROVE_BODY="LGTM"
if [ -n "$REVIEW_EVIDENCE" ]; then
  APPROVE_BODY="LGTM

${REVIEW_EVIDENCE}"
fi

# --- 新しい review を出す前に、自分の古い CHANGES_REQUESTED を畳む。
dismiss_stale_change_requests

case "$DECISION" in
  approve)
    "${GH_CMD}" pr review "$PR_NUMBER" --repo "$REPO" --approve -b "$APPROVE_BODY"
    ;;
  request-changes)
    "${GH_CMD}" pr review "$PR_NUMBER" --repo "$REPO" --request-changes -b "$REQUEST_CHANGES_BODY"
    ;;
esac

emit "decision=${DECISION}"
emit "review_comment_count=${REVIEW_COMMENT_COUNT}"
emit "lint_test_failed=${LINT_TEST_FAILED}"
