#!/usr/bin/env bash
# PR の説明 (タイトル + 本文) と会話タブのコメントを取得し、GITHUB_OUTPUT に body として出す。
# 「この PR が何をしようとしているか」を知らないまま直すと、作者が意図的にそうした点や議論で
# 決着済みの点を蒸し返すため、修正の背景として渡す。actions/fix-context から呼ばれる。
#
# インラインのレビューコメントはここでは取らない。fetch-review-comments.sh が未解決のものだけに
# 絞って渡しており、重複させると解決済みの指摘まで混ざるため。
#
# 入力 (環境変数):
#   PR        - PR 番号
#   REPO      - owner/name
#   GH_TOKEN  - gh 認証トークン
#   BOT_LOGIN - 会話コメントから除く login。修正 bot 自身が投稿したサマリが次回の背景に返ると、
#               見送った根拠を「議論で決着済み」として自己参照してしまうため
#   MAX_BYTES - 説明・コメントそれぞれの最大バイト数 (既定: 8000)
#   GH_CMD    - gh コマンド名 (既定: gh)
#   GITHUB_OUTPUT - 出力先 (body)
set -euo pipefail

: "${PR:?PR is required}"
: "${REPO:?REPO is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

# shellcheck source=actions/fix-context/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

GH_CMD="${GH_CMD:-gh}"
MAX_BYTES="${MAX_BYTES:-8000}"
BOT_LOGIN="${BOT_LOGIN:-}"

# 背景は精度を上げる補助なので、引けなくても修正自体は止めない。BOT_LOGIN は jq に生展開すると
# " や \ で構文が壊れ、gh の --jq は --arg を受けないため env で渡す。
description="$("${GH_CMD}" pr view "$PR" --repo "$REPO" --json title,body \
  --jq '"# \(.title)\n\n\(.body)"' 2>/dev/null)" || description=""
comments="$(EXCLUDE_LOGIN="$BOT_LOGIN" "${GH_CMD}" issue view "$PR" --repo "$REPO" --json comments \
  --jq '.comments[] | select(env.EXCLUDE_LOGIN == "" or .author.login != env.EXCLUDE_LOGIN) | "### @\(.author.login) (\(.createdAt))\n\(.body)\n"' \
  2>/dev/null)" || comments=""

description="$(truncate_bytes "$description" "$MAX_BYTES" "PR description")"
comments="$(truncate_bytes "$comments" "$MAX_BYTES" "PR comments")"

# 空のときに wrapper だけ残すと、プロンプト側に「空なら無視」の補足が要るため丸ごと出さない。
body=""
if [ -n "$description" ] || [ -n "$comments" ]; then
  body="Background for this PR — use it to understand the author's intent.
Do not undo what the author decided on purpose, and do not re-raise what was already settled here.
"
  [ -z "$description" ] || body+="
<pr-description>
${description}
</pr-description>
"
  [ -z "$comments" ] || body+="
<pr-comments>
${comments}
</pr-comments>
"
fi
emit_multiline body "$body"
echo "pr context: description=$(printf '%s' "$description" | wc -c | tr -d ' ') bytes, comments=$(printf '%s' "$comments" | wc -c | tr -d ' ') bytes"
