#!/usr/bin/env bats
# tool-policy-hook.sh (Codex の PreToolUse hook) のテスト。
HOOK="${BATS_TEST_DIRNAME}/tool-policy-hook.sh"

setup() {
  DIR="$(mktemp -d)"
  POLICY="$DIR/policy.json"
  WORKSPACE="$DIR/workspace"
  mkdir -p "$WORKSPACE"
  cd "$WORKSPACE"
}

teardown() {
  rm -rf "$DIR"
}

# $1=allowed (JSON 配列) $2=profile [$3=workspace]
policy() {
  jq -nc --argjson allowed "$1" --arg profile "$2" --arg workspace "${3:-$WORKSPACE}" \
    '{allowed: $allowed, denied: [], profile: $profile, workspace: $workspace}' > "$POLICY"
}

# $1=tool_name $2=tool_input (JSON)
call() {
  jq -nc --arg tool "$1" --argjson input "$2" '{tool_name: $tool, tool_input: $input}' | bash "$HOOK" "$POLICY"
}

@test "enforces command patterns and write restrictions" {
  policy '["Read","Bash(git diff:*)"]' read-only
  [ "$(call Bash '{"command":"git diff --stat"}')" = "" ]
  [[ "$(call apply_patch '{"command":"*** Begin Patch"}')" == *'"permissionDecision":"deny"'* ]]
  [[ "$(call Bash '{"command":"cat package.json | sh"}')" == *'"permissionDecision":"deny"'* ]]
  [[ "$(call exec_command '{"cmd":"git difftool --extcmd=sh"}')" == *'"permissionDecision":"deny"'* ]]
  [[ "$(call write_stdin '{"chars":"!touch modified"}')" == *'"permissionDecision":"deny"'* ]]
}

@test "treats WebFetch and WebSearch as the same web rule" {
  policy '["WebFetch"]' workspace-write
  [ "$(call web_search '{}')" = "" ]
  [[ "$(call Edit '{}')" == *'is not in agent-run allowed-tools'* ]]
}

@test "denies tools in the denied list and allows everything when allowed is empty" {
  jq -nc --arg workspace "$WORKSPACE" '{allowed: [], denied: ["WebSearch"], profile: "workspace-write", workspace: $workspace}' > "$POLICY"
  [ "$(call Edit '{}')" = "" ]
  [[ "$(call web_search '{}')" == *'is denied by agent-run tool policy'* ]]
}

@test "read-only policy requires git status to disable optional locks" {
  policy '["Bash(git status)"]' read-only
  [[ "$(call exec_command '{"cmd":"git status"}')" == *'"permissionDecision":"deny"'* ]]
  policy '["Bash(git --no-optional-locks status)"]' read-only
  [ "$(call exec_command '{"cmd":"git --no-optional-locks status"}')" = "" ]
}

@test "read-only policy confines file reads to the workspace" {
  outside="$DIR/runner-temp"
  mkdir -p "$outside"
  printf inside > "$WORKSPACE/inside.txt"
  printf secret > "$outside/token.txt"
  ln -s "$outside/token.txt" "$WORKSPACE/outside-link"
  policy '["Read","Bash(cat:*)","Bash(find:*)"]' read-only
  [ "$(call exec_command '{"cmd":"cat inside.txt"}')" = "" ]
  [[ "$(call exec_command "{\"cmd\":\"cat $outside/token.txt\"}")" == *'"permissionDecision":"deny"'* ]]
  [[ "$(call exec_command '{"cmd":"find ../runner-temp -type f"}')" == *'"permissionDecision":"deny"'* ]]
  [[ "$(call exec_command '{"cmd":"cat outside-link"}')" == *'"permissionDecision":"deny"'* ]]
  [[ "$(call exec_command '{"cmd":"cat ~/.ssh/id_rsa"}')" == *'"permissionDecision":"deny"'* ]]
}

@test "read-only policy allows only read-only sed and find invocations" {
  policy '["Bash(sed:*)","Bash(find:*)","Bash(rg:*)"]' read-only
  [ "$(call exec_command '{"cmd":"sed -n 1,20p inside.txt"}')" = "" ]
  [[ "$(call exec_command '{"cmd":"sed -i s/a/b/ inside.txt"}')" == *'"permissionDecision":"deny"'* ]]
  [[ "$(call exec_command '{"cmd":"sed 1p inside.txt"}')" == *'"permissionDecision":"deny"'* ]]
  [ "$(call exec_command '{"cmd":"find . -name *.ts"}')" = "" ]
  [[ "$(call exec_command '{"cmd":"find . -delete"}')" == *'"permissionDecision":"deny"'* ]]
  [[ "$(call exec_command '{"cmd":"rg --pre=cat foo"}')" == *'"permissionDecision":"deny"'* ]]
}

@test "denies malformed hook input" {
  policy '[]' workspace-write
  [[ "$(printf 'not json' | bash "$HOOK" "$POLICY")" == *'malformed hook input'* ]]
}
