#!/usr/bin/env bash
# agent-run の provider 非依存な入力 (prompt / tools / settings / schema / permission profile) を
# 検証し、Claude 用の CLI 引数と Codex 用の config.toml / tool-policy hook に変換して
# GITHUB_OUTPUT に書く。actions/agent-run から呼ばれる。
#
# 入力 (環境変数):
#   PROVIDER            - claude | codex
#   PROMPT              - エージェントへのタスク指示
#   SYSTEM_PROMPT       - 追記するシステムプロンプト
#   JSON_SCHEMA         - 構造化出力の JSON Schema (文字列)
#   ALLOWED_TOOLS       - 許可ツール (Claude 形式、カンマ区切り)
#   DISALLOWED_TOOLS    - 禁止ツール (Claude 形式、カンマ区切り)
#   SETTINGS            - settings JSON (permissions.allow / deny を両 provider に適用)
#   PERMISSION_PROFILE  - read-only | workspace-write | danger-full-access (空なら allowed-tools から推定)
#   EFFORT              - low | medium | high | xhigh | max (空なら provider 既定)
#   ALLOWED_BOTS        - allowed_bots (Claude) / allow-bot-users (Codex) 相当
#   EXTRA_CLAUDE_ARGS / EXTRA_CODEX_ARGS - provider 固有の追加引数 (他方では警告して無視)
#   GITHUB_ACTOR        - ALLOWED_BOTS='*' のとき Codex の allow-bot-users に入れる actor
#   ANTHROPIC_API_KEY / CLAUDE_CODE_OAUTH_TOKEN / OPENAI_API_KEY - 選択した provider の認証
#   RUNNER_TEMP / GITHUB_WORKSPACE / GITHUB_OUTPUT
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=actions/agent-run/tool-policy.sh
source "$SELF_DIR/tool-policy.sh"

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

fail() {
  echo "::error::$1" >&2
  exit 1
}
warn() { echo "::warning::$1" >&2; }

# GITHUB_OUTPUT に書く。複数行は heredoc 形式にする。
output() {
  local name="$1" value="$2" delimiter
  if [[ "$value" != *$'\n'* ]]; then
    printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
    return
  fi
  delimiter="AGENT_RUN_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')_$(openssl rand -hex 16)"
  printf '%s<<%s\n%s\n%s\n' "$name" "$delimiter" "$value" "$delimiter" >> "$GITHUB_OUTPUT"
}

# シングルクォートで囲んだシェル引数にする。
shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# 文字列を JSON 文字列リテラルにする (TOML の basic string と同じエスケープ)。
json_string() {
  printf '%s' "$1" | jq -Rs .
}

# 1 行 1 件の列を重複排除する (順序は保つ)。
unique_lines() {
  awk 'NF && !seen[$0]++'
}

# 1 行 1 件の列を JSON 配列にする。
lines_to_json() {
  local lines="$1"
  if [ -z "$lines" ]; then
    printf '[]'
  else
    printf '%s\n' "$lines" | jq -R . | jq -sc .
  fi
}

# 1 行 1 件の列をカンマ区切りにする。
join_comma() {
  printf '%s' "$1" | paste -sd, -
}

# 1 行 1 件の列に値が含まれるか。
has_line() {
  grep -qxF -- "$2" <<<"$1"
}

# カンマ区切りの tool rules を 1 行 1 件に割る。Bash(a,b) のように括弧の中のカンマでは割らない。
split_rules() {
  local value="$1" depth=0 start=0 i ch rule
  for ((i = 0; i <= ${#value}; i++)); do
    ch="${value:i:1}"
    if [ "$ch" = "(" ]; then depth=$((depth + 1)); fi
    if [ "$ch" = ")" ]; then depth=$((depth - 1)); fi
    if { [ "$ch" = "," ] && [ "$depth" -eq 0 ]; } || [ "$i" -eq "${#value}" ]; then
      rule="${value:start:i-start}"
      rule="${rule#"${rule%%[![:space:]]*}"}"
      rule="${rule%"${rule##*[![:space:]]}"}"
      [ -n "$rule" ] && printf '%s\n' "$rule"
      start=$((i + 1))
    fi
  done
  [ "$depth" -eq 0 ] || fail 'tool rules contain unbalanced parentheses'
}

# 1 行 1 件の rule 列から base ツール名の列 (重複排除) を作る。
bases_of() {
  local rule
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    base_tool "$rule"
    echo
  done <<<"$1" | unique_lines
}

# Claude の read-only では Bash(pattern) を安全な固定コマンドだけに限る。
is_safe_claude_readonly_bash_rule() {
  local rule="$1" workspace="$2" pattern
  [[ "$rule" =~ ^Bash\((.*)\)$ ]] || return 1
  pattern="${BASH_REMATCH[1]}"
  [[ "$pattern" != *":*" ]] || return 1
  [[ "$pattern" != *[\*\?\[\]]* ]] || return 1
  is_safe_read_command "$pattern" "$workspace"
}

# ── 入力の検証 ────────────────────────────────────────────────────────────
PROVIDER="${PROVIDER:-}"
case "$PROVIDER" in
  claude | codex) ;;
  *) fail "provider must be claude or codex: ${PROVIDER}" ;;
esac
if [ "$PROVIDER" = claude ] && [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  fail 'ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN is required when provider=claude'
fi
if [ "$PROVIDER" = codex ] && [ -z "${OPENAI_API_KEY:-}" ]; then
  fail 'OPENAI_API_KEY is required when provider=codex'
fi
EFFORT="${EFFORT:-}"
case "$EFFORT" in
  '' | low | medium | high | xhigh | max) ;;
  *) fail "effort must be low, medium, high, xhigh, or max: ${EFFORT}" ;;
esac
if [ "$PROVIDER" = codex ] && [ -n "${EXTRA_CLAUDE_ARGS:-}" ]; then
  warn 'extra-claude-args is provider-specific and was not applied to Codex'
fi
if [ "$PROVIDER" = claude ] && [ -n "${EXTRA_CODEX_ARGS:-}" ]; then
  warn 'extra-codex-args is provider-specific and was not applied to Claude'
fi

# ── settings (permissions.allow / deny) ──────────────────────────────────
settings='{}'
if [ -n "${SETTINGS:-}" ]; then
  jq -e . >/dev/null 2>&1 <<<"$SETTINGS" || fail 'settings must be valid JSON'
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$SETTINGS" || fail 'settings must be a JSON object'
  if [ "$PROVIDER" = codex ]; then
    unsupported="$(jq -r '[keys_unsorted[] | select(. != "permissions")] | join(", ")' <<<"$SETTINGS")"
    [ -z "$unsupported" ] || fail "settings keys cannot be translated to Codex: ${unsupported}"
  fi
  settings="$SETTINGS"
fi
permissions="$(jq -c '.permissions // {}' <<<"$settings")"
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$permissions" || fail 'settings.permissions must be an object'
for key in allow deny; do
  if ! jq -e --arg k "$key" '.[$k] == null or ((.[$k] | type) == "array" and all(.[$k][]; type == "string"))' >/dev/null 2>&1 <<<"$permissions"; then
    fail "settings.permissions.${key} must be an array of strings"
  fi
done
if [ "$PROVIDER" = codex ]; then
  unsupported="$(jq -r '[keys_unsorted[] | select(. != "allow" and . != "deny")] | join(", ")' <<<"$permissions")"
  [ -z "$unsupported" ] || fail "settings.permissions keys cannot be translated to Codex: ${unsupported}"
fi

# ── allowed / denied の統合 ─────────────────────────────────────────────
ALLOWED="$({ split_rules "${ALLOWED_TOOLS:-}"; jq -r '.allow[]?' <<<"$permissions"; } | unique_lines)"
DENIED="$({ split_rules "${DISALLOWED_TOOLS:-}"; jq -r '.deny[]?' <<<"$permissions"; } | unique_lines)"
ALLOWED_BASES="$(bases_of "$ALLOWED")"
DENIED_BASES="$(bases_of "$DENIED")"
READ_ONLY_UNAVAILABLE=$'Edit\nWrite\nNotebookEdit\nWebFetch\nWebSearch\nTask\nAgent\nTodoWrite'

has_write_tool=false
for tool in Edit Write NotebookEdit; do
  if has_line "$ALLOWED_BASES" "$tool"; then has_write_tool=true; fi
done

# ── permission profile ───────────────────────────────────────────────────
profile="${PERMISSION_PROFILE:-}"
if [ -z "$profile" ]; then
  if $has_write_tool; then profile="workspace-write"; else profile="read-only"; fi
fi
case "$profile" in
  read-only | workspace-write | danger-full-access) ;;
  *) fail "permission-profile must be read-only, workspace-write, or danger-full-access: ${profile}" ;;
esac
if [ "$profile" = read-only ]; then
  while IFS= read -r tool; do
    if has_line "$ALLOWED_BASES" "$tool"; then
      fail "read-only permission-profile conflicts with ${tool} in allowed-tools or settings"
    fi
  done <<<"$READ_ONLY_UNAVAILABLE"
fi
workspace="${GITHUB_WORKSPACE:-$PWD}"
if [ "$PROVIDER" = claude ] && [ "$profile" = read-only ]; then
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    [ "$(base_tool "$rule")" = Bash ] || continue
    if ! is_safe_claude_readonly_bash_rule "$rule" "$workspace"; then
      fail "read-only permission-profile requires a safe Bash command for Claude: ${rule}"
    fi
  done <<<"$ALLOWED"
fi

# ── 実行ディレクトリと schema / system prompt ───────────────────────────
run_directory="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/agent-run.XXXXXX")"
schema_file=""
if [ -n "${JSON_SCHEMA:-}" ]; then
  jq -e . >/dev/null 2>&1 <<<"$JSON_SCHEMA" || fail 'json-schema must be valid JSON'
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$JSON_SCHEMA" || fail 'json-schema must be a JSON object'
  schema_file="${run_directory}/output-schema.json"
  printf '%s' "$JSON_SCHEMA" > "$schema_file"
fi
system_prompt_file=""
if [ -n "${SYSTEM_PROMPT:-}" ]; then
  system_prompt_file="${run_directory}/system-prompt.txt"
  printf '%s' "$SYSTEM_PROMPT" > "$system_prompt_file"
fi

# ── Codex: tool-policy hook と config.toml ─────────────────────────────
codex_denied="$DENIED"
if [ "$profile" = read-only ]; then
  codex_denied="$(printf '%s\n%s\n' "$DENIED" "$READ_ONLY_UNAVAILABLE" | unique_lines)"
fi
# /etc/codex/config.toml は sudo が残る間に 1 回しか置けないため、同じ内容の呼び出しが同じ
# hook 設定になるよう内容のハッシュでパスを決める。
policy_json="$(jq -nc \
  --argjson allowed "$(lines_to_json "$ALLOWED")" \
  --argjson denied "$(lines_to_json "$codex_denied")" \
  --arg profile "$profile" --arg workspace "$workspace" \
  '{allowed: $allowed, denied: $denied, profile: $profile, workspace: $workspace}')"
if command -v sha256sum >/dev/null 2>&1; then
  policy_hash="$(printf '%s' "$policy_json" | sha256sum | cut -c1-16)"
else
  policy_hash="$(printf '%s' "$policy_json" | shasum -a 256 | cut -c1-16)"
fi
policy_file="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/agent-run-tool-policy-${policy_hash}.json"
printf '%s' "$policy_json" > "$policy_file"

codex_home="${run_directory}/codex-home"
mkdir -p "$codex_home"
hook="${SELF_DIR}/tool-policy-hook.sh"

# allowed が空なら全ツール可。指定があるときは WebSearch / WebFetch (Agent / Task) のどちらかが
# 含まれるときだけ有効にする。read-only では常に無効。
web_enabled=false
if [ "$profile" != read-only ] && ! has_line "$DENIED_BASES" WebSearch && ! has_line "$DENIED_BASES" WebFetch \
  && { [ -z "$ALLOWED" ] || has_line "$ALLOWED_BASES" WebSearch || has_line "$ALLOWED_BASES" WebFetch; }; then
  web_enabled=true
fi
agents_enabled=false
if [ "$profile" != read-only ] && ! has_line "$DENIED_BASES" Agent && ! has_line "$DENIED_BASES" Task \
  && { [ -z "$ALLOWED" ] || has_line "$ALLOWED_BASES" Agent || has_line "$ALLOWED_BASES" Task; }; then
  agents_enabled=true
fi
skill_denied=false
has_line "$DENIED_BASES" Skill && skill_denied=true

developer_instructions="${SYSTEM_PROMPT:-}"
if $skill_denied; then
  developer_instructions="${developer_instructions}${developer_instructions:+$'\n\n'}Do not load or invoke skills for this run."
fi
config="developer_instructions = $(json_string "$developer_instructions")

[features]
hooks = true

[tools]
web_search = ${web_enabled}

[agents]
enabled = ${agents_enabled}"
# CODEX_HOME の config.toml に置いた hook は trust 済みでないと codex exec が黙ってスキップする。
# system 層 (/etc/codex/config.toml) の hook は managed 扱いで trust 不要なので、hook だけそちらへ置く。
system_config_file="${run_directory}/codex-system-config.toml"
hook_command="bash $(shell_quote "$hook") $(shell_quote "$policy_file")"
printf '%s\n' \
  '[[hooks.PreToolUse]]' \
  'matcher = ".*"' \
  '' \
  '[[hooks.PreToolUse.hooks]]' \
  'type = "command"' \
  "command = $(json_string "$hook_command")" \
  'timeout = 10' > "$system_config_file"
# 組み込みの :workspace は network が塞がり gh で Issue / PR を読めない。
# 書き込み範囲は :workspace のまま network だけ開ける。
codex_workspace_profile="workspace-network"
if [ "$profile" = workspace-write ]; then
  config="${config}

[permissions.${codex_workspace_profile}]
extends = \":workspace\"

[permissions.${codex_workspace_profile}.network]
enabled = true"
fi
if $skill_denied; then
  skill_roots="${PWD}/.agents/skills"$'\n'
  if [ -d "${PWD}/apps" ]; then
    for app in "${PWD}"/apps/*/; do
      [ -d "$app" ] && skill_roots="${skill_roots}${app%/}/.agents/skills"$'\n'
    done
  fi
  while IFS= read -r skill_root; do
    [ -n "$skill_root" ] && [ -d "$skill_root" ] || continue
    for skill in "$skill_root"/*; do
      [ -d "$skill" ] || [ -L "$skill" ] || continue
      [ -f "${skill}/SKILL.md" ] || continue
      config="${config}

[[skills.config]]
path = $(json_string "$skill")
enabled = false"
    done
  done <<<"$skill_roots"
fi
printf '%s\n' "$config" > "${codex_home}/config.toml"

# ── Claude: CLI 引数 ────────────────────────────────────────────────────
profile_denied=""
if [ "$profile" = read-only ]; then
  has_line "$ALLOWED_BASES" Bash || profile_denied=$'Bash\n'
  profile_denied="${profile_denied}${READ_ONLY_UNAVAILABLE}"
fi
claude_denied="$(printf '%s\n%s\n' "$profile_denied" "$DENIED" | unique_lines)"
claude_tools="$ALLOWED_BASES"
if [ "$profile" = danger-full-access ]; then
  claude_permission_args='--dangerously-skip-permissions'
else
  claude_permission_args='--permission-mode dontAsk'
fi
claude_tool_args=""
[ -n "$ALLOWED" ] && claude_tool_args="--allowedTools $(shell_quote "$(join_comma "$ALLOWED")")"
[ -n "$claude_tools" ] && claude_tool_args="${claude_tool_args}${claude_tool_args:+ }--tools $(shell_quote "$(join_comma "$claude_tools")")"
[ -n "$claude_denied" ] && claude_tool_args="${claude_tool_args}${claude_tool_args:+ }--disallowedTools $(shell_quote "$(join_comma "$claude_denied")")"

codex_bot_users="${ALLOWED_BOTS:-}"
[ "$codex_bot_users" = '*' ] && codex_bot_users="${GITHUB_ACTOR:-}"

# ── 出力 ────────────────────────────────────────────────────────────────
output prompt "${PROMPT:-}"
output schema_file "$schema_file"
output system_prompt_file "$system_prompt_file"
output output_file "${run_directory}/final-message.txt"
output execution_file "${run_directory}/execution.jsonl"
output permission_profile "$profile"
if [ "$profile" = workspace-write ]; then
  output codex_permission_profile "$codex_workspace_profile"
else
  output codex_permission_profile ":${profile}"
fi
output claude_permission_args "$claude_permission_args"
output claude_disallowed_tools "$(join_comma "$claude_denied")"
output claude_allowed_tools "$(join_comma "$ALLOWED")"
output claude_tools "$(join_comma "$claude_tools")"
if $skill_denied; then output claude_skill_args '--disable-slash-commands'; else output claude_skill_args ''; fi
output claude_tool_args "$claude_tool_args"
if [ -n "$schema_file" ]; then
  output claude_schema_args "--json-schema $(shell_quote "$JSON_SCHEMA")"
else
  output claude_schema_args ''
fi
output codex_home "$codex_home"
output codex_system_config_file "$system_config_file"
output codex_bot_users "$codex_bot_users"
