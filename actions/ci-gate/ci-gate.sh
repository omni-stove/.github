#!/usr/bin/env bash
# needs の結果を集約して CI Gate の成否を決める。actions/ci-gate から呼ばれる。
#
# 入力 (環境変数):
#   RESULTS                - toJSON(needs) の JSON、または 1 行 1 件の `name=result` / `result`
#   BYPASS_LABELS          - 素通しにするラベル (カンマ区切り。大文字小文字は区別しない)
#   BYPASS_BRANCH_PREFIXES - 素通しにする head ブランチ名の接頭辞 (カンマ区切り)
#   LABELS_JSON            - PR のラベル名の JSON 配列 (PR 以外のイベントでは空や null)
#   HEAD_REF               - PR の head ブランチ名
#   GITHUB_OUTPUT          - 出力先 (bypassed / failed_jobs)
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
RESULTS="${RESULTS:-}"
BYPASS_LABELS="${BYPASS_LABELS:-}"
BYPASS_BRANCH_PREFIXES="${BYPASS_BRANCH_PREFIXES:-}"
LABELS_JSON="${LABELS_JSON:-}"
HEAD_REF="${HEAD_REF:-}"

emit() { echo "$1" >> "$GITHUB_OUTPUT"; }

# PR に指定ラベルが付いているか。GitHub のラベル名比較は大文字小文字を区別しないため
# ascii_downcase で揃える。配列でない / 壊れた JSON はラベル無し扱い。
has_label() {
  local label="$1"
  [ -n "$LABELS_JSON" ] || return 1
  jq -e --arg label "$label" \
    'if type == "array" then any(ascii_downcase == ($label | ascii_downcase)) else false end' \
    <<<"$LABELS_JSON" >/dev/null 2>&1
}

# --- 緊急避難口: ラベル / ブランチ名で素通しにする。
# カンマ区切りを 1 行 1 件に展開する (ラベル名に空白が入ることがあるため空白では割らない)。
# パイプではなく here-string で回すのは、ループ内の exit を現在のシェルで効かせるため。
while IFS= read -r label; do
  label="$(printf '%s' "$label" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$label" ] || continue
  if has_label "$label"; then
    echo "::notice::'${label}' ラベルが付いているため CI Gate をスキップして success にします。"
    emit "bypassed=true"
    emit "failed_jobs="
    exit 0
  fi
done <<<"$(printf '%s' "$BYPASS_LABELS" | tr ',' '\n')"
while IFS= read -r prefix; do
  prefix="$(printf '%s' "$prefix" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$prefix" ] || continue
  if [ -n "$HEAD_REF" ] && [[ "$HEAD_REF" == "$prefix"* ]]; then
    echo "::notice::head ブランチ '${HEAD_REF}' が '${prefix}' で始まるため CI Gate をスキップして success にします。"
    emit "bypassed=true"
    emit "failed_jobs="
    exit 0
  fi
done <<<"$(printf '%s' "$BYPASS_BRANCH_PREFIXES" | tr ',' '\n')"
emit "bypassed=false"

# --- 結果を `name=result` の行に正規化する。JSON (toJSON(needs)) なら jq で展開する。
normalized=""
if printf '%s' "$RESULTS" | jq -e 'type == "object"' >/dev/null 2>&1; then
  normalized="$(jq -r 'to_entries[] | "\(.key)=\(.value.result // "")"' <<<"$RESULTS")"
else
  normalized="$RESULTS"
fi

failed=""
while IFS= read -r line; do
  line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$line" ] || continue
  name="${line%%=*}"
  result="${line#*=}"
  [ "$name" != "$line" ] || name="(unnamed)"
  echo "${name}: ${result}"
  case "$result" in
    failure | cancelled) failed="${failed}${name} " ;;
  esac
done <<<"$normalized"

failed="${failed% }"
emit "failed_jobs=${failed}"
if [ -n "$failed" ]; then
  echo "::error::失敗またはキャンセルされたジョブがあります: ${failed}。マージできません。"
  exit 1
fi
echo "失敗・キャンセルされたジョブはありません。"
