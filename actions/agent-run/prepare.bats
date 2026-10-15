#!/usr/bin/env bats
# prepare.sh のテスト。provider 非依存の入力を Claude / Codex の設定に変換する部分を検証する。
SCRIPT="${BATS_TEST_DIRNAME}/prepare.sh"

setup() {
  DIR="$(mktemp -d)"
  export RUNNER_TEMP="$DIR"
  export GITHUB_OUTPUT="$DIR/github-output"
  export GITHUB_WORKSPACE="$DIR/workspace"
  mkdir -p "$GITHUB_WORKSPACE"
  export ANTHROPIC_API_KEY=anthropic-test-key
  export OPENAI_API_KEY=openai-test-key
  export CLAUDE_CODE_OAUTH_TOKEN=""
  export JSON_SCHEMA="" ALLOWED_TOOLS="" DISALLOWED_TOOLS="" SETTINGS="" PERMISSION_PROFILE="" EFFORT="" \
    EXTRA_CLAUDE_ARGS="" EXTRA_CODEX_ARGS="" ALLOWED_BOTS="" SYSTEM_PROMPT="" GITHUB_ACTOR=""
  cd "$GITHUB_WORKSPACE"
}

teardown() {
  rm -rf "$DIR"
}

output_value() {
  sed -n "s/^$1=//p" "$GITHUB_OUTPUT"
}

@test "keeps the user prompt separate and creates Codex configuration" {
  PROVIDER=codex PROMPT=$'task\nAGENT_RUN_PROMPT_EOF' SYSTEM_PROMPT=system JSON_SCHEMA='{"type":"object"}' \
    ALLOWED_TOOLS='Read,Edit' ALLOWED_BOTS='*' GITHUB_ACTOR='dependabot[bot]' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q $'^task$' "$GITHUB_OUTPUT"
  grep -q '^AGENT_RUN_PROMPT_EOF$' "$GITHUB_OUTPUT"
  grep -qx 'permission_profile=workspace-write' "$GITHUB_OUTPUT"
  grep -qx 'codex_permission_profile=workspace-network' "$GITHUB_OUTPUT"
  grep -qx 'claude_permission_args=--permission-mode dontAsk' "$GITHUB_OUTPUT"
  grep -qxF 'codex_bot_users=dependabot[bot]' "$GITHUB_OUTPUT"
  [ "$(cat "$(output_value schema_file)")" = '{"type":"object"}' ]
  config="$(cat "$(output_value codex_home)/config.toml")"
  [[ "$config" == *'developer_instructions = "system"'* ]]
  [[ "$config" != *'[[hooks.PreToolUse]]'* ]]
  [[ "$config" == *'[permissions.workspace-network]'$'\n''extends = ":workspace"'* ]]
  [[ "$config" == *'[permissions.workspace-network.network]'$'\n''enabled = true'* ]]
  system_config="$(cat "$(output_value codex_system_config_file)")"
  [[ "$system_config" == *'[[hooks.PreToolUse]]'$'\n''matcher = ".*"'* ]]
  [[ "$system_config" == *'tool-policy-hook.sh'* ]]
}

@test "maps the common permission profile for Claude and Codex" {
  PROVIDER=claude PROMPT=task ALLOWED_TOOLS=Read PERMISSION_PROFILE=read-only run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'permission_profile=read-only' "$GITHUB_OUTPUT"
  grep -qx 'codex_permission_profile=:read-only' "$GITHUB_OUTPUT"
  grep -qx 'claude_permission_args=--permission-mode dontAsk' "$GITHUB_OUTPUT"
  grep -qx 'claude_disallowed_tools=Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,Task,Agent,TodoWrite' "$GITHUB_OUTPUT"
  grep -qxF "claude_tool_args=--allowedTools 'Read' --tools 'Read' --disallowedTools 'Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,Task,Agent,TodoWrite'" "$GITHUB_OUTPUT"

  : > "$GITHUB_OUTPUT"
  PROVIDER=claude PROMPT=task PERMISSION_PROFILE=danger-full-access run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'claude_permission_args=--dangerously-skip-permissions' "$GITHUB_OUTPUT"
}

@test "requires only the selected provider credential" {
  PROVIDER=codex PROMPT=task ANTHROPIC_API_KEY="" run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  PROVIDER=codex PROMPT=task OPENAI_API_KEY="" run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"OPENAI_API_KEY is required"* ]]

  PROVIDER=claude PROMPT=task ANTHROPIC_API_KEY="" run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN is required"* ]]

  PROVIDER=claude PROMPT=task ANTHROPIC_API_KEY="" CLAUDE_CODE_OAUTH_TOKEN=oauth run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "validates the common effort and reports ignored provider extensions" {
  PROVIDER=codex PROMPT=task EFFORT=high EXTRA_CLAUDE_ARGS='--max-turns 20' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"extra-claude-args is provider-specific"* ]]

  PROVIDER=codex PROMPT=task EFFORT=extreme run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"effort must be"* ]]
}

@test "rejects a read-only profile with write tools" {
  PROVIDER=claude PROMPT=task ALLOWED_TOOLS='Read,Write' PERMISSION_PROFILE=read-only run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"conflicts with Write"* ]]
}

@test "rejects argument wildcards and unsafe commands for Claude Bash rules in a read-only profile" {
  for rule in 'Read,Bash(git diff:*)' 'Read,Bash(node:*)' 'Read,Bash(scripts/update/*)' 'Bash(git status)'; do
    : > "$GITHUB_OUTPUT"
    PROVIDER=claude PROMPT=task ALLOWED_TOOLS="$rule" PERMISSION_PROFILE=read-only run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires a safe Bash command"* ]]
  done

  : > "$GITHUB_OUTPUT"
  PROVIDER=claude PROMPT=task ALLOWED_TOOLS='Bash(git --no-optional-locks status)' PERMISSION_PROFILE=read-only run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'claude_disallowed_tools=Edit,Write,NotebookEdit,WebFetch,WebSearch,Task,Agent,TodoWrite' "$GITHUB_OUTPUT"
}

@test "translates settings permissions and rejects unsupported Codex settings" {
  PROVIDER=codex PROMPT=task SETTINGS='{"permissions":{"allow":["Read","Bash(git diff:*)"],"deny":["WebSearch"]}}' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qxF 'claude_allowed_tools=Read,Bash(git diff:*)' "$GITHUB_OUTPUT"
  grep -qx 'claude_disallowed_tools=Edit,Write,NotebookEdit,WebFetch,WebSearch,Task,Agent,TodoWrite' "$GITHUB_OUTPUT"
  [[ "$(cat "$(output_value codex_home)/config.toml")" == *'web_search = false'* ]]
  policy="$(ls "$RUNNER_TEMP"/agent-run-tool-policy-*.json)"
  [ "$(jq -r '.allowed | join(",")' "$policy")" = 'Read,Bash(git diff:*)' ]
  [ "$(jq -r '.denied | join(",")' "$policy")" = 'WebSearch,Edit,Write,NotebookEdit,WebFetch,Task,Agent,TodoWrite' ]
  [ "$(jq -r '.profile' "$policy")" = 'read-only' ]

  PROVIDER=codex PROMPT=task SETTINGS='{"hooks":{"PreToolUse":[]}}' run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot be translated to Codex"* ]]

  PROVIDER=codex PROMPT=task SETTINGS='not json' run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"settings must be valid JSON"* ]]
}

@test "splits tool rules on top-level commas only and emits schema args" {
  PROVIDER=claude PROMPT=task ALLOWED_TOOLS='Read, Bash(a,b), Grep' DISALLOWED_TOOLS='Skill' PERMISSION_PROFILE=workspace-write \
    JSON_SCHEMA='{"type":"object","properties":{"x":{"type":"string"}}}' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qxF 'claude_allowed_tools=Read,Bash(a,b),Grep' "$GITHUB_OUTPUT"
  grep -qx 'claude_tools=Read,Bash,Grep' "$GITHUB_OUTPUT"
  grep -qx 'claude_skill_args=--disable-slash-commands' "$GITHUB_OUTPUT"
  grep -qxF "claude_schema_args=--json-schema '{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}}}'" "$GITHUB_OUTPUT"
  [[ "$(cat "$(output_value codex_home)/config.toml")" == *'Do not load or invoke skills for this run.'* ]]

  PROVIDER=claude PROMPT=task ALLOWED_TOOLS='Bash(a' run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unbalanced parentheses"* ]]
}

@test "disables repository skills for Codex when Skill is denied" {
  mkdir -p "$GITHUB_WORKSPACE/.agents/skills/cap" "$GITHUB_WORKSPACE/.agents/skills/empty" "$GITHUB_WORKSPACE/apps/web/.agents/skills/deploy"
  : > "$GITHUB_WORKSPACE/.agents/skills/cap/SKILL.md"
  : > "$GITHUB_WORKSPACE/apps/web/.agents/skills/deploy/SKILL.md"
  PROVIDER=codex PROMPT=task DISALLOWED_TOOLS=Skill run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  config="$(cat "$(output_value codex_home)/config.toml")"
  [[ "$config" == *"path = \"$GITHUB_WORKSPACE/.agents/skills/cap\""$'\n''enabled = false'* ]]
  [[ "$config" == *"path = \"$GITHUB_WORKSPACE/apps/web/.agents/skills/deploy\""* ]]
  [[ "$config" != *"skills/empty"* ]]
}
