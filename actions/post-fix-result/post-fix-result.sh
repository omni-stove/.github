#!/usr/bin/env bash
# 自動修正の結果を PR に残す。actions/post-fix-result から呼ばれる。本文の生成 (判断) はエージェントが
# 構造化出力で返し、投稿 (決定論) はここが担う。
#
#   loop     - 連続上限で打ち切ったことを marker 付きコメントで upsert する (毎回の run で増やさない)
#   skipped  - 緊急避難口のラベルで push を見送ったので何も投稿しない
#   external - 原因が PR の差分外にあり push を見送ったことと、エージェントの summary を投稿する
#   conflict - rebase のコンフリクトで push を見送ったことを upsert し、summary も投稿する
#   それ以外 - summary を投稿する。pushed なら指摘ごとの対応 (.replies) を各スレッドへ返信する
#              (push していないのに「処理済み」の返信だけ残さないため pushed のときだけ)
# summary が空でも、何が起きたか追えるよう既定文言で 1 件は残す。
#
# 入力 (環境変数):
#   PR / REPO        - 対象 PR
#   RESULT           - 上の結果 (エージェントが途中で落ちたら空)
#   STRUCTURED       - エージェントの structured_output。.summary / .replies を使う
#   REF              - PR の head ブランチ名 (コンフリクト通知の文面に使う)
#   MAX_CONSECUTIVE  - 連続上限 (打ち切り通知の文面に使う)
#   RATE_LIMITED / RATE_LIMIT_RESET - エージェントが GitHub API のレート制限で落ちたか / 解除時刻 (epoch 秒)
#   RUN_URL          - この run の URL
#   GH_TOKEN         - gh 認証トークン
#   GH_CMD           - gh コマンド名 (既定: gh)
set -euo pipefail

: "${PR:?PR is required}"
: "${REPO:?REPO is required}"

GH_CMD="${GH_CMD:-gh}"
RESULT="${RESULT:-}"
RUN_URL="${RUN_URL:-}"
run_link=""
[ -z "$RUN_URL" ] || run_link=$'\n\n'"実行ログ: ${RUN_URL}"

# marker を先頭に持つ既存コメントがあれば更新し、無ければ作る。marker は jq に生展開すると " や \ で
# 構文が壊れ、gh の --jq は --arg を受けないため env で渡す。
upsert_comment() {
  local marker="$1" body="$2" id
  body="${marker}"$'\n'"${body}"
  id="$(MARKER="$marker" "${GH_CMD}" api "repos/${REPO}/issues/${PR}/comments" --paginate \
    --jq 'first(.[] | select(.body | startswith(env.MARKER)) | .id) // empty' 2>/dev/null || true)"
  if [ -n "$id" ]; then
    "${GH_CMD}" api -X PATCH "repos/${REPO}/issues/comments/${id}" -f body="$body" >/dev/null
  else
    "${GH_CMD}" api "repos/${REPO}/issues/${PR}/comments" -f body="$body" >/dev/null
  fi
}

summary_body() {
  local body reset_at
  body="$(printf '%s' "${STRUCTURED:-}" | jq -er '.summary // ""' 2>/dev/null || true)"
  if [ -z "${body//[$' \t\n']/}" ] && [ "${RATE_LIMITED:-}" = "true" ]; then
    reset_at=""
    if [[ "${RATE_LIMIT_RESET:-}" =~ ^[0-9]+$ ]]; then
      reset_at="$(TZ=Asia/Tokyo date -d "@${RATE_LIMIT_RESET}" '+%H:%M' 2>/dev/null || TZ=Asia/Tokyo date -r "${RATE_LIMIT_RESET}" '+%H:%M' 2>/dev/null || true)"
    fi
    body="(GitHub API のレート制限で自動修正を実行できなかった。${reset_at:+制限は ${reset_at} (JST) ごろに解除される。}解除後に CI を再実行すると自動修正がもう一度走る。)"
  fi
  [ -n "${body//[$' \t\n']/}" ] || body="(自動修正は実行されたが、サマリが返らなかった。ジョブログを確認してほしい。)"
  printf '%s' "$body"
}

post_replies() {
  local replies reply comment_id note posted=0 failed=0
  replies="$(printf '%s' "${STRUCTURED:-}" | jq -c '
    (.replies // [])
    | if type == "array" then . else [] end
    | map(select((.comment_id | type) == "number" and (.note | type) == "string"))
    | map(select(.note | test("[^[:space:]]")))
    | .[]' 2>/dev/null || true)"
  while IFS= read -r reply; do
    [ -n "$reply" ] || continue
    comment_id="$(jq -r '.comment_id' <<<"$reply")"
    note="$(jq -r '.note' <<<"$reply")"
    # 返信は表示上の補助で、修正の push は済んでいる。1 件失敗しても残りを投げ切る。
    if "${GH_CMD}" api --method POST "repos/${REPO}/pulls/${PR}/comments/${comment_id}/replies" \
      -f body="$note" >/dev/null 2>&1; then
      posted=$((posted + 1))
    else
      failed=$((failed + 1))
      echo "::warning::review comment ${comment_id} への返信に失敗した。"
    fi
  done <<<"$replies"
  echo "posted ${posted} reply/replies (${failed} failed)."
}

case "$RESULT" in
  skipped)
    echo "push was skipped by a bypass label; posting nothing."
    exit 0
    ;;
  loop)
    upsert_comment "<!-- agent-fix-giveup -->" "自動修正が ${MAX_CONSECUTIVE:-3} 回続けても CI とレビュー指摘が解消しなかったため、自動修正を止めた。手で直して push すると再開する。${run_link}"
    exit 0
    ;;
  conflict)
    upsert_comment "<!-- agent-fix-conflict -->" "自動修正 (\`[agent-fix]\`) を最新の \`${REF:-head}\` に rebase するとコンフリクトしたため、push を見送った。手で直してほしい。${run_link}"
    ;;
esac

body="$(summary_body)"
if [ "$RESULT" = "external" ]; then
  body="lint / test の失敗の原因がこの PR の差分外にあるため、自動修正は push しなかった。"$'\n\n'"${body}"
fi
"${GH_CMD}" pr comment "$PR" --repo "$REPO" --body "${body}${run_link}"

[ "$RESULT" != "pushed" ] || post_replies
