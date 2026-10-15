#!/usr/bin/env bash
# lint / test / review の統合結果から、自動修正 (agent-fix.yml) を起動するかと、そのきっかけを決める。
# actions/decide-fix から呼ばれる。
#
#   - lint / test に failure があれば trigger=ci
#   - そうでなくレビュー指摘があれば trigger=review
#   - どちらも無ければ起動しない
#   - PR に skip-autofix ラベルがある / PR 作成者がオプトアウトファイルに載っていれば、レビュー指摘は
#     直さない (fix_review_comments=false)。lint / test の失敗は直す。force-autofix ラベルはオプトアウトを
#     打ち消す。trigger=ci の修正もレビュー指摘を併せて直すため、should_fix とは別に出す。
#   - fork の PR と、push に使う agent App が無いときは起動しない
#
# 入力 (環境変数):
#   REPO                 - owner/name
#   PR_REPO              - PR の head リポジトリ (owner/name)
#   PR_AUTHOR            - PR 作成者の login
#   PR_LABELS_JSON       - PR のラベル名の JSON 配列
#   LINT_TEST_RESULTS    - lint / test ジョブの result を空白区切りで列挙したもの
#   REVIEW_COMMENT_COUNT - Code Review の指摘件数
#   HAS_AGENT_APP        - agent App の secrets があれば 'true'
#   OPT_OUT_PATH         - オプトアウトファイルのリポジトリ内パス (既定ブランチから読む。空なら見ない)
#   SKIP_LABEL / FORCE_LABEL - PR 単位で止める / オプトアウトを打ち消すラベル (既定: skip-autofix / force-autofix)
#   GH_CMD               - gh コマンド名 (既定: gh)
#   GITHUB_OUTPUT        - 出力先 (should_fix / trigger / fix_review_comments)
set -euo pipefail

: "${REPO:?REPO is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

GH_CMD="${GH_CMD:-gh}"
PR_REPO="${PR_REPO:-$REPO}"
PR_AUTHOR="${PR_AUTHOR:-}"
PR_LABELS_JSON="${PR_LABELS_JSON:-}"
LINT_TEST_RESULTS="${LINT_TEST_RESULTS:-}"
REVIEW_COMMENT_COUNT="${REVIEW_COMMENT_COUNT:-0}"
OPT_OUT_PATH="${OPT_OUT_PATH:-}"
SKIP_LABEL="${SKIP_LABEL:-skip-autofix}"
FORCE_LABEL="${FORCE_LABEL:-force-autofix}"

emit() { echo "$1" >> "$GITHUB_OUTPUT"; }

no_fix() {
  emit "should_fix=false"
  echo "$1"
  exit 0
}

# GitHub のラベル名比較は大文字小文字を区別しないため ascii_downcase で揃える。配列でない / 壊れた
# JSON はラベル無し扱い (止めるのは明示的な意思表示があるときだけにする)。
has_label() {
  [ -n "$PR_LABELS_JSON" ] || return 1
  jq -e --arg label "$1" \
    'if type == "array" then any(ascii_downcase == ($label | ascii_downcase)) else false end' \
    <<<"$PR_LABELS_JSON" >/dev/null 2>&1
}

# オプトアウトファイルは PR の head ではなく既定ブランチから読む。ユーザー名の羅列に限定してあるので
# yq を持ち込まず、YAML の 2 記法 (`users: [a, b]` と `users:` + `- a`) を 1 行 1 名に正規化して照合する。
# login は大文字小文字を区別しない。ファイルが無い / 読めないときはオプトアウトしていない扱い。
has_opted_out() {
  local content
  [ -n "$PR_AUTHOR" ] && [ -n "$OPT_OUT_PATH" ] || return 1
  content="$("${GH_CMD}" api "repos/${REPO}/contents/${OPT_OUT_PATH}" -H 'Accept: application/vnd.github.raw' 2>/dev/null)" || return 1
  {
    # `]` を含まない文字クラスで最初の `]` までに限り、行末コメントの `]` まで貪欲にマッチさせない。
    printf '%s\n' "$content" | sed -n 's/^[[:space:]]*users:[[:space:]]*\[\([^]]*\)\].*$/\1/p' | tr ',' '\n'
    printf '%s\n' "$content" | sed -n 's/^[[:space:]]*-[[:space:]]*//p'
  } \
    | sed 's/#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^["'"'"']//; s/["'"'"']$//' \
    | tr '[:upper:]' '[:lower:]' \
    | grep -qxF "$(printf '%s' "$PR_AUTHOR" | tr '[:upper:]' '[:lower:]')"
}

if [ "$PR_REPO" != "$REPO" ]; then
  no_fix "PR is from a fork (${PR_REPO}); not running auto-fix."
fi

LINT_TEST_FAILED=false
for r in $LINT_TEST_RESULTS; do
  [ "$r" != "failure" ] || { LINT_TEST_FAILED=true; break; }
done

case "$REVIEW_COMMENT_COUNT" in
  '' | *[!0-9]*) REVIEW_COMMENT_COUNT=0 ;;
esac

# PR 単位の指定はその PR を見ている本人の今の意思表示なので、ファイルの設定より優先する。
# skip と force が両方付いていたら止める側を採る (意図しない変更を push するより何もしない方が損失が小さい)。
FIX_REVIEW_COMMENTS=true
if has_label "$SKIP_LABEL"; then
  FIX_REVIEW_COMMENTS=false
  echo "'${SKIP_LABEL}' label; review comments will not be auto-fixed."
elif has_opted_out; then
  if has_label "$FORCE_LABEL"; then
    echo "${PR_AUTHOR} opted out, but the '${FORCE_LABEL}' label overrides it."
  else
    FIX_REVIEW_COMMENTS=false
    echo "${PR_AUTHOR} opted out (${OPT_OUT_PATH}); review comments will not be auto-fixed."
  fi
fi

# オプトアウトしていても lint / test の失敗は直す。失敗した箇所しか触らず、オプトアウトの動機
# (レビュー指摘の自動修正で差分が膨らむ) に当たらないため。
if [ "$LINT_TEST_FAILED" = "true" ]; then
  TRIGGER=ci
elif [ "$REVIEW_COMMENT_COUNT" -gt 0 ] && [ "$FIX_REVIEW_COMMENTS" = "true" ]; then
  TRIGGER=review
else
  no_fix "Nothing to fix (lint/test failed=${LINT_TEST_FAILED} review_comments=${REVIEW_COMMENT_COUNT} fix_review_comments=${FIX_REVIEW_COMMENTS})."
fi

# github.token で push しても次の CI が起動せず、PR の必須チェックが新しい head に付かないまま止まる。
if [ "${HAS_AGENT_APP:-}" != "true" ]; then
  echo "::warning::AGENT_GH_APP_ID / AGENT_GH_APP_PRIVATE_KEY が無いため自動修正を起動しません (github.token の push では CI が再実行されない)。"
  no_fix "No agent App; not running auto-fix."
fi

{
  echo "should_fix=true"
  echo "trigger=${TRIGGER}"
  echo "fix_review_comments=${FIX_REVIEW_COMMENTS}"
} >> "$GITHUB_OUTPUT"
echo "Will run auto-fix (trigger=${TRIGGER} fix_review_comments=${FIX_REVIEW_COMMENTS})."
