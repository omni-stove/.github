#!/usr/bin/env bash
# PR のまだ生きているインラインレビューコメントを取得し、GITHUB_OUTPUT に body として出す。
# actions/fix-context から呼ばれる。
#
# 解決済み (isResolved) と outdated (その後の push で位置がずれ、もう現在のコードを指していない) の
# スレッドは落とす。REST の pulls/{pr}/comments ではこのフラグが取れないため graphql を使う。
# 末尾が BOT_LOGIN の返信であるスレッド (修正 bot が対応済み) も落とし、その後に人間が返信したら戻す。
# 見出しの [comment_id=N] はスレッド先頭コメントの databaseId で、エージェントが対応内容を
# そのスレッドへ返信するのに使う。全コメントに付けるとスレッドへ重複返信するため先頭だけに付ける。
#
# 入力 (環境変数):
#   PR        - PR 番号
#   REPO      - owner/name
#   GH_TOKEN  - gh 認証トークン
#   BOT_LOGIN - 修正 bot の login (graphql の author.login は `[bot]` を含まない app slug)
#   FIX_REVIEW_COMMENTS - 'false' なら取得せず body を空にする (オプトアウト)
#   MAX_BYTES - body の最大バイト数 (既定: 32000)
#   GH_CMD    - gh コマンド名 (既定: gh)
#   GITHUB_OUTPUT - 出力先 (body / has_comments)
set -euo pipefail

: "${PR:?PR is required}"
: "${REPO:?REPO is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

# shellcheck source=actions/fix-context/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

GH_CMD="${GH_CMD:-gh}"
BOT_LOGIN="${BOT_LOGIN:-}"
FIX_REVIEW_COMMENTS="${FIX_REVIEW_COMMENTS:-true}"
MAX_BYTES="${MAX_BYTES:-32000}"

fetch_active_review_comments() {
  # subject_type=file のコメントは line / originalLine が両方 null になるので、post-review-comments が
  # 付ける "(Lnn の指摘) " 接頭辞から行番号を復元し、無ければ "file" にする。
  # shellcheck disable=SC2016
  BOT_LOGIN="$BOT_LOGIN" "${GH_CMD}" api graphql -f query='query($owner:String!,$repo:String!,$pr:Int!){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){
        reviewThreads(first:100){
          nodes{
            isResolved
            isOutdated
            comments(first:100){
              nodes{ databaseId author{login} path line originalLine body }
            }
          }
        }
      }
    }
  }' \
    -f owner="${REPO%%/*}" -f repo="${REPO#*/}" -F pr="${PR}" \
    --jq '[.data.repository.pullRequest.reviewThreads.nodes[]
            | select(.isResolved == false and .isOutdated == false)
            | select(env.BOT_LOGIN == "" or (.comments.nodes | length) == 1 or .comments.nodes[-1].author.login != env.BOT_LOGIN)
            | (.comments.nodes[0].databaseId) as $reply_to
            | .comments.nodes[]
            | . + {reply_to: $reply_to}]
          | map("### @\(.author.login) \(.path):\(.line // .originalLine // ((.body | capture("^\\(L(?<n>[0-9]+) の指摘\\) ")) | .n) // "file")"
                + (if .databaseId == .reply_to then " [comment_id=\(.reply_to)]" else "" end)
                + "\n\(.body)\n")
          | join("\n")'
}

comments=""
if [ "$FIX_REVIEW_COMMENTS" = "false" ]; then
  echo "FIX_REVIEW_COMMENTS=false; skipping review comments."
else
  comments="$(fetch_active_review_comments)"
fi

body=""
has_comments=false
if [ -n "$comments" ]; then
  has_comments=true
  body="Unresolved review comments are below; skip ones already fixed or no longer relevant.
Each heading carries the \`[comment_id=N]\` to reply to for that comment.

<review-comments>
$(truncate_bytes "$comments" "$MAX_BYTES" "review comments")
</review-comments>"
fi
emit_multiline body "$body"
echo "has_comments=${has_comments}" >> "$GITHUB_OUTPUT"
