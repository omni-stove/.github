#!/usr/bin/env bash
# エージェントが使う GitHub トークンの REST (core) / GraphQL の残量を記録する。
# 実行前後で呼び、どのジョブが App のレート制限を消費しているかを突き止めるのに使う。
# rate_limit API 自体は残量を消費しない。
#
# 入力 (環境変数):
#   GH_TOKEN  - 対象トークン
#   PHASE     - before | after
#   BEFORE    - PHASE=after のとき、before の出力 (`<core残> <core reset> <graphql残> <graphql reset>`)
# 出力 ($GITHUB_OUTPUT):
#   snapshot  - `<core残> <core reset> <graphql残> <graphql reset>`。取得できなければ空。
# PHASE=after では、同じリセット窓の中ならこのジョブ実行中の消費量を notice と step summary に出す。
# 並行する他ジョブの消費も含むため目安として扱う。
# 記録のための補助なので、取得に失敗してもエージェントの実行は止めない (常に exit 0)。
set -uo pipefail

GH_CMD="${GH_CMD:-gh}"
PHASE="${PHASE:-before}"
out="${GITHUB_OUTPUT:-/dev/null}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

snapshot="$("${GH_CMD}" api rate_limit --jq '"\(.resources.core.remaining) \(.resources.core.reset) \(.resources.graphql.remaining) \(.resources.graphql.reset)"' 2>/dev/null || true)"
if ! [[ "${snapshot}" =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]]; then
  echo "::warning::GitHub API のレート制限残量を取得できませんでした (${PHASE})"
  echo "snapshot=" >> "${out}"
  exit 0
fi
echo "snapshot=${snapshot}" >> "${out}"
read -r core core_reset graphql graphql_reset <<<"${snapshot}"
echo "GitHub API rate limit (${PHASE}): core remaining=${core} reset=${core_reset}, graphql remaining=${graphql} reset=${graphql_reset}"

[ "${PHASE}" = "after" ] || exit 0
read -r b_core b_core_reset b_graphql b_graphql_reset <<<"${BEFORE:-}"
[ -n "${b_core:-}" ] || exit 0

# リセットをまたぐと残量が戻り差分が意味を持たないため、同じ窓のときだけ出す。
used_of() { [ "$1" = "$2" ] && echo "$(($3 - $4))" || echo "n/a (reset)"; }
core_used="$(used_of "${b_core_reset}" "${core_reset}" "${b_core}" "${core}")"
graphql_used="$(used_of "${b_graphql_reset}" "${graphql_reset}" "${b_graphql}" "${graphql}")"
echo "::notice title=GitHub API usage::core ${core_used} / graphql ${graphql_used} (remaining core ${core}, graphql ${graphql})"
{
  echo "### GitHub API usage (agent-run)"
  echo ""
  echo "| | used during this run | remaining |"
  echo "|---|---|---|"
  echo "| core | ${core_used} | ${core} |"
  echo "| graphql | ${graphql_used} | ${graphql} |"
  echo ""
  echo "並行する他ジョブの消費を含む目安。"
} >> "${summary}"
exit 0
