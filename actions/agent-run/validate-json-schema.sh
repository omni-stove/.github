#!/usr/bin/env bash
# 標準入力の JSON を JSON Schema (サブセット) で検証する。違反があれば stderr に出して 1 で終了する。
#   bash validate-json-schema.sh <schema.json> <<<"<value>"
set -uo pipefail

SCHEMA_FILE="${1:?schema file is required}"
value="$(cat)"

if ! jq -e . >/dev/null 2>&1 <<<"$value"; then
  echo "value is not valid JSON" >&2
  exit 1
fi
if ! jq -e . >/dev/null 2>&1 "$SCHEMA_FILE"; then
  echo "schema is not valid JSON" >&2
  exit 1
fi

errors="$(jq -r --slurpfile schema "$SCHEMA_FILE" -f "$(dirname "${BASH_SOURCE[0]}")/validate-json-schema.jq" <<<"$value" 2>&1)" || {
  printf '%s\n' "$errors" >&2
  exit 1
}
if [ -n "$errors" ]; then
  printf '%s\n' "$errors" >&2
  exit 1
fi
