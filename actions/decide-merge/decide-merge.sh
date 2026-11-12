#!/usr/bin/env bash
# CI Gate を通った PR を自動マージ (ci-gate.yml の merge ジョブ) するかを決める。actions/decide-merge から呼ばれる。
# CI Gate 自体の成否は見ない (merge ジョブが needs.ci-gate.result == 'success' で見る)。
#
#   - fork の PR / draft の PR はマージしない
#   - SKIP_LABELS のどれかが付いた PR はマージしない
#   - 自動修正がこれから push する (SHOULD_FIX=true) ならマージしない。修正後の CI でまた判定する
#   - finalize を使う (FINALIZE=true) なら、提出した判定が approve のときだけマージする。CI Gate は lint / test の
#     結果だけで通るため、レビュー指摘で request-changes を出した PR も通ってしまう
#   - マージに使う agent App が無いときはマージしない
#
# 入力 (環境変数):
#   REPO           - owner/name
#   PR_REPO        - PR の head リポジトリ (owner/name)
#   PR_DRAFT       - draft PR なら 'true'
#   PR_LABELS_JSON - PR のラベル名の JSON 配列
#   SKIP_LABELS    - マージしない PR のラベル (カンマ区切り。既定: skip-automerge,prototype)
#   SHOULD_FIX     - 自動修正を起動するなら 'true'
#   FINALIZE       - finalize を使うなら 'true'
#   DECISION       - finalize が提出した判定 (approve | request-changes。提出していなければ空)
#   HAS_AGENT_APP  - agent App の secrets があれば 'true'
#   GITHUB_OUTPUT  - 出力先 (should_merge)
set -euo pipefail

: "${REPO:?REPO is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

PR_REPO="${PR_REPO:-$REPO}"
PR_LABELS_JSON="${PR_LABELS_JSON:-}"
SKIP_LABELS="${SKIP_LABELS-skip-automerge,prototype}"

no_merge() {
  echo "should_merge=false" >> "$GITHUB_OUTPUT"
  echo "$1"
  exit 0
}

# GitHub のラベル名比較は大文字小文字を区別しないため ascii_downcase で揃える。配列でない / 壊れた
# JSON はラベル無し扱い。
has_label() {
  [ -n "$PR_LABELS_JSON" ] || return 1
  jq -e --arg label "$1" \
    'if type == "array" then any(ascii_downcase == ($label | ascii_downcase)) else false end' \
    <<<"$PR_LABELS_JSON" >/dev/null 2>&1
}

[ "$PR_REPO" = "$REPO" ] || no_merge "PR is from a fork (${PR_REPO}); not auto-merging."
[ "${PR_DRAFT:-}" != "true" ] || no_merge "PR is a draft; not auto-merging."

# ラベル名に空白が入ることがあるため空白では割らない。here-string で回すのはループ内の no_merge の exit を効かせるため。
while IFS= read -r label; do
  label="$(printf '%s' "$label" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$label" ] || continue
  ! has_label "$label" || no_merge "'${label}' label; not auto-merging."
done <<<"$(printf '%s' "$SKIP_LABELS" | tr ',' '\n')"

[ "${SHOULD_FIX:-}" != "true" ] || no_merge "Auto-fix will push; not auto-merging this run."

if [ "${FINALIZE:-}" = "true" ] && [ "${DECISION:-}" != "approve" ]; then
  no_merge "Review decision is '${DECISION:-none}', not approve; not auto-merging."
fi

# github.token でマージすると既定ブランチへの push を契機にした workflow も closing keyword による Issue の
# 自動クローズも起きず、呼び出し側に contents: write も要る。
if [ "${HAS_AGENT_APP:-}" != "true" ]; then
  echo "::warning::AGENT_GH_APP_ID / AGENT_GH_APP_PRIVATE_KEY が無いため自動マージしません。"
  no_merge "No agent App; not auto-merging."
fi

echo "should_merge=true" >> "$GITHUB_OUTPUT"
echo "Will auto-merge."
