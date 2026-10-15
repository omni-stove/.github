#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "::error::$1" >&2
  exit 1
}

provider="${PROVIDER:-}"
tier="${TIER:-}"

# 同じ tier の Claude / Codex モデルを並べて定義し、provider を切り替えても性能帯が揃うようにする。
case "$tier" in
  max) claude_model=fable codex_tier=astra ;;
  high) claude_model=opus codex_tier=sol ;;
  medium) claude_model=sonnet codex_tier=terra ;;
  low) claude_model=haiku codex_tier=luna ;;
  *) fail "tier must be max, high, medium, or low: ${tier}" ;;
esac

case "$provider" in
  # Claude Code の alias はそれ自体が最新世代を指すため、API で解決せずそのまま渡す。
  claude) model="$claude_model" ;;
  codex) ;;
  *) fail "provider must be claude or codex: ${provider}" ;;
esac

if [ "$provider" = codex ]; then
  [ -n "${OPENAI_API_KEY:-}" ] || fail 'OPENAI_API_KEY is required to resolve a Codex model'
  # 解決に失敗したとき古い固定 ID に黙って落とすと、最新追従が壊れたことに気づけないため fail closed にする。
  models="$(curl -fsS -H "Authorization: Bearer ${OPENAI_API_KEY}" https://api.openai.com/v1/models)" ||
    fail 'failed to list OpenAI models'
  # 日付付きスナップショット (gpt-6.1-sol-2026-09-29 など) は世代比較を曖昧にするため対象外にする。
  version="$(
    jq -r --arg tier "$codex_tier" \
      '.data[].id | capture("^gpt-(?<version>[0-9]+(\\.[0-9]+)*)-" + $tier + "$") | .version' <<<"$models" |
      sort -V | tail -n 1
  )"
  [ -n "$version" ] || fail "no OpenAI model found for tier: ${codex_tier}"
  model="gpt-${version}-${codex_tier}"
fi

echo "Model: ${tier} -> ${provider} ${model}"
{
  echo "provider=${provider}"
  echo "model=${model}"
} >>"$GITHUB_OUTPUT"
