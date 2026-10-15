#!/usr/bin/env bash
# 出力の正規化: provider 差 (structured_output vs final-message) を吸収し、共通の
# structured_output / text_output に揃えて GITHUB_OUTPUT に書く。json-schema を渡した
# 実行では、構造化出力が空・JSON でない・スキーマに反する場合に失敗させる。
#
# 入力 (環境変数):
#   PROVIDER              - claude | codex
#   HAS_SCHEMA            - json-schema を渡したら true
#   CLAUDE_STRUCTURED     - claude-code-action の structured_output
#   CLAUDE_EXECUTION_FILE - claude-code-action の execution_file
#   CODEX_FINAL           - codex-action の final-message
#   CODEX_HOME            - Codex の CODEX_HOME (実行ログのコピー元)
#   SCHEMA_FILE           - prepare.sh が書き出した schema
#   OUTPUT_FILE           - 最終メッセージの保存先
#   EXECUTION_FILE        - 実行ログの保存先
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

extract_claude_text() {
  if [ -z "${CLAUDE_EXECUTION_FILE:-}" ] || [ ! -f "$CLAUDE_EXECUTION_FILE" ]; then
    return
  fi
  jq -rs '
    flatten
    | (map(select(.type == "result") | .result) | last)
      // (map(select(.type == "assistant") | .message.content[]?
              | select(.type == "text") | .text) | last)
      // ""
  ' "$CLAUDE_EXECUTION_FILE"
}

case "${PROVIDER:-}" in
  claude)
    structured="${CLAUDE_STRUCTURED:-}"
    if [ "${HAS_SCHEMA:-false}" = "true" ]; then
      text="$structured"
    else
      text="$(extract_claude_text)"
    fi
    execution_file=""
    if [ -n "${EXECUTION_FILE:-}" ] && [ -n "${CLAUDE_EXECUTION_FILE:-}" ] && [ -f "$CLAUDE_EXECUTION_FILE" ]; then
      cp "$CLAUDE_EXECUTION_FILE" "$EXECUTION_FILE"
      execution_file="$EXECUTION_FILE"
    fi
    ;;
  codex)
    text="${CODEX_FINAL:-}"
    if [ "${HAS_SCHEMA:-false}" = "true" ]; then
      structured="$text"
    else
      structured=""
    fi
    execution_file=""
    if [ -n "${CODEX_HOME:-}" ] && [ -n "${EXECUTION_FILE:-}" ]; then
      execution_file="$(bash "$SELF_DIR/copy-codex-execution-log.sh" "$CODEX_HOME" "$EXECUTION_FILE")"
    fi
    ;;
  *)
    echo "::error::provider must be claude or codex: ${PROVIDER:-}" >&2
    exit 1
    ;;
esac

if [ "${HAS_SCHEMA:-false}" = "true" ]; then
  if [ -z "$structured" ]; then
    echo "::error::$PROVIDER returned no structured output" >&2
    exit 1
  fi
  if ! printf '%s' "$structured" | jq -e . >/dev/null; then
    echo "::error::$PROVIDER returned invalid JSON as structured output" >&2
    exit 1
  fi
  if ! printf '%s' "$structured" | bash "$SELF_DIR/validate-json-schema.sh" "$SCHEMA_FILE"; then
    echo "::error::$PROVIDER returned JSON that does not satisfy json-schema" >&2
    exit 1
  fi
fi

printf '%s' "$text" > "$OUTPUT_FILE"

delimiter="AGENT_RUN_OUTPUT_EOF_$(openssl rand -hex 16)"
{
  echo "structured_output<<$delimiter"
  printf '%s\n' "$structured"
  echo "$delimiter"
  echo "text_output<<$delimiter"
  printf '%s\n' "$text"
  echo "$delimiter"
  echo "provider=$PROVIDER"
  echo "output_file=$OUTPUT_FILE"
  echo "execution_file=$execution_file"
} >> "$GITHUB_OUTPUT"
