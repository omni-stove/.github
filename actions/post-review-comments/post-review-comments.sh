#!/usr/bin/env bash
# Code Review の構造化出力 (インライン指摘の配列) を本文付きの review として投稿する。
# comments API への個別投稿は本文なし review を生成するため使わず、通常は一括投稿する。
# 422 のときだけ指摘単位で並列再試行する。既存指摘との重複は投稿前に除外する。
# actions/post-review-comments から呼ばれる。
#
# 入力 (環境変数):
#   REPO           - owner/name
#   PR             - PR 番号
#   COMMIT         - インラインコメントを紐づけるコミット SHA
#   COMMENTS_JSON  - 構造化出力 JSON 文字列 ({"comments":[...]})。review がスキップ / 失敗した
#                    ときも空文字になるため、空 = 指摘 0 件とは断定できない (REVIEW_RESULT 参照)。
#   REVIEW_RESULT  - フォールバックコメントの削除可否の判定材料。success 以外なら
#                    フォールバックコメントを削除しない (未解決の指摘がどこにも残らなくなるため)。
#   GH_TOKEN       - gh 認証トークン
#   PARALLELISM    - 422 後の並列再試行数 (既定: 6。セカンダリレート制限に配慮した値)
#   GH_CMD         - gh コマンド名 (既定: gh。テストでモックを差し込むため)
#   REVIEWER_LOGIN - フォールバックコメントの投稿者として検証する login (既定: github-actions[bot])。
#                    body のマーカー一致だけで対象を選ぶと第三者が偽装したコメントを更新・削除
#                    してしまうため、投稿者でも絞る。
set -euo pipefail

: "${REPO:?REPO is required}"
: "${PR:?PR is required}"
: "${COMMIT:?COMMIT is required}"

PARALLELISM="${PARALLELISM:-6}"
GH_CMD="${GH_CMD:-gh}"
REVIEWER_LOGIN="${REVIEWER_LOGIN:-github-actions[bot]}"
FALLBACK_HEADER="### 🤖 Code Review (インライン化できなかった指摘)"
export REPO PR COMMIT GH_CMD

# 既存のフォールバックコメント ID を古い順に 1 行 1 件で列挙する (無ければ空)。
find_existing_fallback_ids() {
  REVIEWER="${REVIEWER_LOGIN}" HEADER="${FALLBACK_HEADER}" "${GH_CMD}" api --paginate "repos/${REPO}/issues/${PR}/comments" \
    --jq '.[] | select(.user.login == env.REVIEWER) | select(.body | startswith(env.HEADER)) | .id' \
    2>/dev/null || true
}

delete_fallback_comment() {
  local id="$1"
  if "${GH_CMD}" api "repos/${REPO}/issues/comments/${id}" -X DELETE > /dev/null; then
    echo "フォールバックコメントを削除しました (comment #${id})。"
    return 0
  fi
  echo "::warning::フォールバックコメントの削除に失敗しました (comment #${id})。古い指摘が残っている可能性があります。"
  return 1
}

# フォールバックコメントは「直近のレビューで現在も失敗している finding」だけを表す不変条件を
# 保つ。レビューが実施されていない (REVIEW_RESULT != success) 経路では「指摘 0 件」と断定
# できないため、何も削除せず既存コメントを残す。
delete_stale_fallback() {
  local id
  if [ "${REVIEW_RESULT:-}" != "success" ]; then
    echo "レビュー未実施 (REVIEW_RESULT=${REVIEW_RESULT:-未設定}) のため、既存のフォールバックコメントは削除せず残します。"
    return 0
  fi
  while IFS= read -r id; do
    [ -n "${id}" ] || continue
    echo "失敗している指摘が無いため、フォールバックコメントを削除します。"
    delete_fallback_comment "${id}" || true
  done < <(find_existing_fallback_ids)
}

# structured_output ({"comments":[...]}) から .comments 配列を取り出し、一時ファイルに正規化する。
COMMENTS_JSON="${COMMENTS_JSON:-}"
COMMENTS_FILE="$(mktemp)"
if [ -z "${COMMENTS_JSON}" ]; then
  echo "COMMENTS_JSON が空です。投稿をスキップします。"
  delete_stale_fallback
  exit 0
fi
if ! jq -e '.comments | type == "array"' <<<"${COMMENTS_JSON}" > /dev/null 2>&1; then
  echo "::error::COMMENTS_JSON が {\"comments\":[...]} 形式ではありません。"
  exit 1
fi
jq '.comments' <<<"${COMMENTS_JSON}" > "${COMMENTS_FILE}"

COUNT=$(jq 'length' "${COMMENTS_FILE}")
echo "レビューエージェントが出力したコメント件数: ${COUNT}"
if [ "${COUNT}" -eq 0 ]; then
  echo "投稿するコメントはありません。"
  delete_stale_fallback
  exit 0
fi

# 既存のインラインコメントを 1 回だけ取得 (path|line|body の組で重複判定する)。
# ファイル単位コメントは line が null になり、本文にも "(Lnn の指摘) " 接頭辞が乗るため、
# 接頭辞から行番号を復元したキーも併せて出力する。
"${GH_CMD}" api --paginate "repos/${REPO}/pulls/${PR}/comments" \
  --jq '.[]
        | ([.path, (.line // .original_line // 0), .body] | @tsv),
          (select(.body | test("^\\(L[0-9]+ の指摘\\) "))
           | [.path,
              (.body | capture("^\\(L(?<n>[0-9]+) の指摘\\) ") | .n),
              (.body | sub("^\\(L[0-9]+ の指摘\\) "; ""))] | @tsv)' \
  > existing.tsv || : > existing.tsv

# 重複していない新規コメントだけを NDJSON に絞り込む。重複判定キーは既存側と同じ @tsv で
# 生成し、grep -qxF (行全体の完全一致) で突き合わせる。
jq -c '.[]' "${COMMENTS_FILE}" | while IFS= read -r c; do
  p=$(jq -r '.path' <<<"$c")
  l=$(jq -r '.line' <<<"$c")
  key=$(jq -r '[.path, .line, .body] | @tsv' <<<"$c")
  if grep -qxF "$key" existing.tsv; then
    echo "skip (duplicate): ${p}:${l}" >&2
    continue
  fi
  echo "$c"
done > to-post.ndjson

NEW=$(wc -l < to-post.ndjson | tr -d '[:space:]')
echo "新規投稿件数: ${NEW}"
if [ "${NEW}" -eq 0 ]; then
  delete_stale_fallback
  exit 0
fi

# インライン投稿に失敗した指摘を退避する NDJSON。最後に通常コメントへフォールバックする。
FAILED_FILE="${WORK_FAILED_FILE:-failed-comments.ndjson}"
: > "${FAILED_FILE}"
export FAILED_FILE

# 通常は全指摘を本文付き review の comments 配列として一括投稿し、空メッセージと review の
# 乱立を防ぐ。行不整合で 422 のときだけ指摘単位で再試行する。
REVIEW_BODY="自動コードレビューで ${NEW} 件のインライン指摘を投稿しました。"
BATCH_PAYLOAD=$(jq -cs \
  --arg commit_id "${COMMIT}" \
  --arg body "${REVIEW_BODY}" \
  '{commit_id: $commit_id, body: $body, event: "COMMENT", comments: map({path, line, side: (.side // "RIGHT"), body})}' \
  to-post.ndjson)
BATCH_ERROR=""
if BATCH_ERROR=$(printf '%s' "${BATCH_PAYLOAD}" | \
    "${GH_CMD}" api "repos/${REPO}/pulls/${PR}/reviews" --input - 2>&1 > /dev/null); then
  echo "posted ${NEW} inline findings in one review"
  delete_stale_fallback
  exit 0
fi
if [[ "${BATCH_ERROR}" != *"HTTP 422"* ]]; then
  echo "::warning::review の一括投稿に失敗したため通常コメントへフォールバックします: ${BATCH_ERROR}"
  cp to-post.ndjson "${FAILED_FILE}"
fi

# 1 件を投稿する関数。JSON は stdin で受け取る。行指定が 422 ならファイル単位コメント
# (subject_type=file) に落とす。それ以外の失敗 (403 / 5xx 等) は一時的な可能性があるため
# ファイル単位にせずフォールバックに退避し、次回実行で行指定として投稿し直せるようにする。
post_one() {
  local c path line side body review_body payload err
  c=$(cat)
  path=$(jq -r '.path' <<<"$c")
  line=$(jq -r '.line' <<<"$c")
  side=$(jq -r '.side // "RIGHT"' <<<"$c")
  body=$(jq -r '.body' <<<"$c")
  review_body="自動コードレビューで 1 件のインライン指摘を投稿しました。"
  payload=$(jq -cn \
    --arg commit_id "${COMMIT}" --arg review_body "$review_body" \
    --arg path "$path" --argjson line "$line" --arg side "$side" --arg body "$body" \
    '{commit_id: $commit_id, body: $review_body, event: "COMMENT", comments: [{path: $path, line: $line, side: $side, body: $body}]}')
  if err=$(printf '%s' "$payload" | \
      "${GH_CMD}" api "repos/${REPO}/pulls/${PR}/reviews" --input - 2>&1 > /dev/null); then
    echo "posted: ${path}:${line}"
    return
  fi

  case "$err" in
    *"HTTP 422"*)
      echo "::warning::行指定のインライン投稿に失敗 (422、ファイル単位で再試行): ${path}:${line}: ${err}"
      payload=$(jq -cn \
        --arg commit_id "${COMMIT}" --arg review_body "$review_body" \
        --arg path "$path" --arg body "(L${line} の指摘) ${body}" \
        '{commit_id: $commit_id, body: $review_body, event: "COMMENT", comments: [{path: $path, subject_type: "file", body: $body}]}')
      if err=$(printf '%s' "$payload" | \
          "${GH_CMD}" api "repos/${REPO}/pulls/${PR}/reviews" --input - 2>&1 > /dev/null); then
        echo "posted (file-level): ${path}:${line}"
        return
      fi
      echo "::warning::ファイル単位の投稿にも失敗 (フォールバックへ退避): ${path}:${line}: ${err}"
      ;;
    *)
      echo "::warning::行指定のインライン投稿に失敗 (422 以外のためファイル単位を試さずフォールバックへ退避): ${path}:${line}: ${err}"
      ;;
  esac

  ( flock -x 9; printf '%s\n' "$c" >&9 ) 9>> "${FAILED_FILE}"
}
export -f post_one

# shellcheck disable=SC2016 # $1 は bash -c の子シェルで解決する位置パラメータ。
if [ -z "${BATCH_ERROR}" ] || [[ "${BATCH_ERROR}" == *"HTTP 422"* ]]; then
  while IFS= read -r line; do printf '%s\0' "$line"; done < to-post.ndjson \
    | xargs -0 -P "${PARALLELISM}" -I {} bash -c 'printf "%s" "$1" | post_one' _ {}
fi

# --- フォールバック投稿: インライン化に失敗した指摘を 1 件の通常コメントにまとめて投稿する。
FAILED_COUNT=$(wc -l < "${FAILED_FILE}" | tr -d '[:space:]')
if [ "${FAILED_COUNT}" -eq 0 ]; then
  delete_stale_fallback
  exit 0
fi

echo "インライン投稿に失敗した指摘 ${FAILED_COUNT} 件を通常コメントへフォールバックします。"

FALLBACK_BODY=$(
  {
    printf '%s\n\n' "${FALLBACK_HEADER}"
    printf '%s\n\n' "以下の指摘は対象行が diff に乗らずインラインコメントにできませんでした。内容を確認してください。"
    jq -r '"- **\(.path):\(.line)**\n\n  " + (.body | gsub("\n"; "\n  "))' "${FAILED_FILE}"
  }
)

# 既存のフォールバックコメントがあれば更新 (PATCH)、なければ新規投稿して重複を防ぐ。
# 過去の実行で重複が生まれている可能性があるため、最も古い 1 件を残して PATCH し、残りは削除する。
EXISTING_FALLBACK_ID=""
STALE_FALLBACK_IDS=""
while IFS= read -r fallback_id; do
  [ -n "${fallback_id}" ] || continue
  if [ -z "${EXISTING_FALLBACK_ID}" ]; then
    EXISTING_FALLBACK_ID="${fallback_id}"
  else
    STALE_FALLBACK_IDS="${STALE_FALLBACK_IDS}${fallback_id}"$'\n'
  fi
done < <(find_existing_fallback_ids)

if [ -n "${STALE_FALLBACK_IDS}" ]; then
  echo "::warning::フォールバックコメントが重複しています。comment #${EXISTING_FALLBACK_ID} を残して他を削除します。"
  while IFS= read -r stale_id; do
    [ -n "${stale_id}" ] || continue
    delete_fallback_comment "${stale_id}" || true
  done <<<"${STALE_FALLBACK_IDS}"
fi

if [ -n "${EXISTING_FALLBACK_ID}" ]; then
  if "${GH_CMD}" api "repos/${REPO}/issues/comments/${EXISTING_FALLBACK_ID}" \
      -X PATCH -f body="${FALLBACK_BODY}" > /dev/null; then
    echo "フォールバックコメントを更新しました (${FAILED_COUNT} 件分, comment #${EXISTING_FALLBACK_ID})。"
  else
    echo "::error::フォールバックコメントの更新に失敗しました。指摘 ${FAILED_COUNT} 件が PR に残りません。"
    exit 1
  fi
else
  if "${GH_CMD}" api "repos/${REPO}/issues/${PR}/comments" \
      -f body="${FALLBACK_BODY}" > /dev/null; then
    echo "フォールバックコメントを投稿しました (${FAILED_COUNT} 件分)。"
  else
    echo "::error::フォールバックコメントの投稿に失敗しました。指摘 ${FAILED_COUNT} 件が PR に残りません。"
    exit 1
  fi
fi
