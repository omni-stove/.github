#!/usr/bin/env bats
SCRIPT="${BATS_TEST_DIRNAME}/collect.sh"
STRUCTURED='{"message":"line 1\nAGENT_EOF\nline 2"}'

setup() {
  DIR="$(mktemp -d)"
  export GITHUB_OUTPUT="$DIR/github-output"
  export OUTPUT_FILE="$DIR/output.txt"
  export SCHEMA_FILE="$DIR/schema.json"
  printf '%s' '{"type":"object","required":["message"],"properties":{"message":{"type":"string"}}}' > "$SCHEMA_FILE"
}

teardown() {
  rm -rf "$DIR"
}

assert_structured_outputs() {
  [ "$(grep -c 'AGENT_RUN_OUTPUT_EOF_' "$GITHUB_OUTPUT")" -eq 4 ]
  grep -q '^structured_output<<AGENT_RUN_OUTPUT_EOF_' "$GITHUB_OUTPUT"
  grep -q '^text_output<<AGENT_RUN_OUTPUT_EOF_' "$GITHUB_OUTPUT"
  [ "$(grep -c '"message":"line 1' "$GITHUB_OUTPUT")" -eq 2 ]
  [ "$(cat "$OUTPUT_FILE")" = "$STRUCTURED" ]
}

@test "exposes Claude structured output as both structured and text output" {
  PROVIDER=claude HAS_SCHEMA=true CLAUDE_STRUCTURED="$STRUCTURED" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_structured_outputs
}

@test "exposes Codex structured output as both outputs and copies the execution log" {
  mkdir -p "$DIR/codex-home/sessions/2026"
  printf '{"type":"turn.started"}\n' > "$DIR/codex-home/sessions/2026/rollout.jsonl"
  : > "$DIR/execution.jsonl"
  PROVIDER=codex HAS_SCHEMA=true CODEX_FINAL="$STRUCTURED" CODEX_HOME="$DIR/codex-home" \
    EXECUTION_FILE="$DIR/execution.jsonl" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_structured_outputs
  [ "$(cat "$DIR/execution.jsonl")" = '{"type":"turn.started"}' ]
  grep -qx "execution_file=$DIR/execution.jsonl" "$GITHUB_OUTPUT"
}

@test "reads Claude text output from JSONL" {
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"answer"}]}}' > "$DIR/execution.jsonl"
  PROVIDER=claude HAS_SCHEMA=false CLAUDE_EXECUTION_FILE="$DIR/execution.jsonl" \
    EXECUTION_FILE="$DIR/normalized-execution.jsonl" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -A1 '^text_output<<' "$GITHUB_OUTPUT" | grep -qx 'answer'
  cmp "$DIR/execution.jsonl" "$DIR/normalized-execution.jsonl"
}

@test "fails when structured output is empty" {
  PROVIDER=codex HAS_SCHEMA=true CODEX_FINAL='' run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "fails when structured output is not JSON" {
  PROVIDER=codex HAS_SCHEMA=true CODEX_FINAL='not json' run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "fails when JSON violates the requested schema" {
  printf '%s' '{"type":"object","required":["count"],"additionalProperties":false,"properties":{"count":{"type":"integer"}}}' > "$SCHEMA_FILE"
  PROVIDER=codex HAS_SCHEMA=true CODEX_FINAL='{"count":"one"}' run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not satisfy json-schema"* ]]
}
