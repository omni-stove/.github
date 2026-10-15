#!/usr/bin/env bash
# Codex の PreToolUse hook。agent-run の allowed / disallowed tools と permission profile を
# Codex のツール呼び出しに適用し、違反なら deny を標準出力に返す (許可なら何も出さない)。
#
#   bash tool-policy-hook.sh <policy.json>   (hook の入力 JSON は stdin)
#
# policy.json: {"allowed": [...], "denied": [...], "profile": "read-only|workspace-write|danger-full-access", "workspace": "..."}
set -uo pipefail

# shellcheck source=actions/agent-run/tool-policy.sh
source "$(dirname "${BASH_SOURCE[0]}")/tool-policy.sh"

POLICY_FILE="${1:?policy file is required}"

deny() {
  jq -nc --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
}

policy="$(cat "$POLICY_FILE")"
event="$(cat)"
if ! jq -e . >/dev/null 2>&1 <<<"$event"; then
  deny 'Tool policy received malformed hook input.'
  exit 0
fi

workspace="$(jq -r '.workspace // empty' <<<"$policy")"
[ -n "$workspace" ] || workspace="$PWD"
profile="$(jq -r '.profile // ""' <<<"$policy")"
allowed_rules="$(jq -r '.allowed[]?' <<<"$policy")"
denied_rules="$(jq -r '.denied[]?' <<<"$policy")"

actual_tool="$(jq -r '.tool_name // ""' <<<"$event")"
tool="$(normalize_tool_name "$actual_tool")"
is_write_stdin=false
[ "$actual_tool" = write_stdin ] && is_write_stdin=true
# 末尾の改行も含めて取り出す (改行入りコマンドはシェル分割で拒否するため)。
command="$(jq -r '
  if (.tool_input.cmd | type) == "string" then .tool_input.cmd
  elif (.tool_input.command | type) == "string" then .tool_input.command
  else "" end' <<<"$event"
  printf x)"
command="${command%x}"
command="${command%$'\n'}"

# $1=tool $2=command、stdin=rule (1 行 1 件)。どれかに一致すれば 0。
any_rule_matches() {
  local rule
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    if matches_rule "$1" "$2" "$rule"; then return 0; fi
  done
  return 1
}

explicit_bash_rules=""
bare_bash_allowed=false
while IFS= read -r rule; do
  [ -n "$rule" ] || continue
  if [ "$(base_tool "$rule")" = Bash ]; then
    explicit_bash_rules="${explicit_bash_rules}${rule}"$'\n'
    [[ "$rule" != *"("* ]] && bare_bash_allowed=true
  fi
done <<<"$allowed_rules"

if [ "$profile" = read-only ] && $is_write_stdin; then
  deny 'write_stdin is unavailable in the read-only permission profile.'
elif $is_write_stdin && ! $bare_bash_allowed; then
  deny 'write_stdin requires bare Bash in agent-run allowed-tools.'
elif [ "$profile" = read-only ] && [ "$tool" = apply_patch ]; then
  deny 'apply_patch is unavailable in the read-only permission profile.'
elif [ "$profile" = read-only ] && [ "$tool" = Bash ] && ! $is_write_stdin \
  && ! { is_safe_read_command "$command" "$workspace" && any_rule_matches "$tool" "$command" <<<"$explicit_bash_rules"; }; then
  deny 'Bash command is unavailable in the read-only permission profile.'
elif ! $is_write_stdin && any_rule_matches "$tool" "$command" <<<"$denied_rules"; then
  deny "${tool} is denied by agent-run tool policy."
elif ! $is_write_stdin && [ -n "$allowed_rules" ] && ! any_rule_matches "$tool" "$command" <<<"$allowed_rules"; then
  deny "${tool} is not in agent-run allowed-tools."
fi
