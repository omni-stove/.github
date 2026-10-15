#!/usr/bin/env bash
# エージェントが失敗したとき、原因が GitHub API のレート制限かを判定し、
# 制限が MAX_WAIT_SECONDS 以内に解除されるならそれまで待って再実行を指示する。
#
# 入力 (環境変数):
#   GH_TOKEN          - エージェントが使ったトークン
#   MAX_WAIT_SECONDS  - 待つ上限 (秒)
#   THRESHOLD         - 残量がこれ未満の bucket を枯渇とみなす (既定 10)
# 出力 ($GITHUB_OUTPUT):
#   rate_limited - core / graphql のどちらかが枯渇していれば true
#   retry        - 解除まで待ったので再実行してよければ true
#   reset        - 枯渇した bucket の解除時刻 (epoch 秒)。枯渇していなければ空
# 判定できない・枯渇していない・待ちきれない場合は retry=false で exit 0 する
# (失敗として扱うかは呼び出し側が決める)。
set -uo pipefail

GH_CMD="${GH_CMD:-gh}"
SLEEP_CMD="${SLEEP_CMD:-sleep}"
NOW_CMD="${NOW_CMD:-date +%s}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-0}"
THRESHOLD="${THRESHOLD:-10}"
out="${GITHUB_OUTPUT:-/dev/null}"

emit() { printf 'rate_limited=%s\nretry=%s\nreset=%s\n' "$1" "$2" "$3" >> "${out}"; }

snapshot="$("${GH_CMD}" api rate_limit --jq '"\(.resources.core.remaining) \(.resources.core.reset) \(.resources.graphql.remaining) \(.resources.graphql.reset)"' 2>/dev/null || true)"
if ! [[ "${snapshot}" =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]]; then
  echo "::warning::GitHub API のレート制限残量を取得できず、レート制限による失敗か判定できませんでした"
  emit false false ""
  exit 0
fi
read -r core core_reset graphql graphql_reset <<<"${snapshot}"

reset=""
[ "${core}" -lt "${THRESHOLD}" ] && reset="${core_reset}"
if [ "${graphql}" -lt "${THRESHOLD}" ] && { [ -z "${reset}" ] || [ "${graphql_reset}" -gt "${reset}" ]; }; then
  reset="${graphql_reset}"
fi
if [ -z "${reset}" ]; then
  echo "GitHub API rate limit is not exhausted (core=${core}, graphql=${graphql}); not retrying."
  emit false false ""
  exit 0
fi

# 解除直後の取りこぼしを避けるため、少し余裕を足して待つ。
wait_seconds=$((reset - $(${NOW_CMD}) + 10))
[ "${wait_seconds}" -lt 0 ] && wait_seconds=0
if [ "${MAX_WAIT_SECONDS}" -le 0 ]; then
  echo "::warning::GitHub API のレート制限で失敗しました (再実行は無効)。"
  emit true false "${reset}"
  exit 0
fi
if [ "${wait_seconds}" -gt "${MAX_WAIT_SECONDS}" ]; then
  echo "::warning::GitHub API のレート制限で失敗しました。解除まで ${wait_seconds} 秒かかり上限 ${MAX_WAIT_SECONDS} 秒を超えるため再実行しません。"
  emit true false "${reset}"
  exit 0
fi

echo "::notice::GitHub API のレート制限で失敗したため、解除まで ${wait_seconds} 秒待って再実行します。"
"${SLEEP_CMD}" "${wait_seconds}"
emit true true "${reset}"
