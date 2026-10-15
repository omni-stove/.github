#!/usr/bin/env bats
# validate-json-schema.sh のテスト。
SCRIPT="${BATS_TEST_DIRNAME}/validate-json-schema.sh"

setup() {
  DIR="$(mktemp -d)"
  SCHEMA="$DIR/schema.json"
}

teardown() {
  rm -rf "$DIR"
}

# $1=schema $2=value
validate() {
  printf '%s' "$1" > "$SCHEMA"
  printf '%s' "$2" | bash "$SCRIPT" "$SCHEMA"
}

@test "accepts a value that satisfies the schema" {
  run validate '{"type":"object","required":["comments"],"properties":{"comments":{"type":"array","items":{"type":"object","properties":{"line":{"type":"integer"},"category":{"type":"string","enum":["security","correctness"]}},"required":["line","category"],"additionalProperties":false}}},"additionalProperties":false}' \
    '{"comments":[{"line":3,"category":"security"}]}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "reports type, required, enum, additionalProperties and items violations" {
  run validate '{"type":"object","required":["count"],"additionalProperties":false,"properties":{"count":{"type":"integer"},"kind":{"type":"string","enum":["a"]},"list":{"type":"array","items":{"type":"integer"},"minItems":2}}}' \
    '{"count":"one","kind":"b","list":[1,"x"],"extra":true}'
  [ "$status" -eq 1 ]
  [[ "$output" == *'$.count must be integer'* ]]
  [[ "$output" == *'$.kind is not in enum'* ]]
  [[ "$output" == *'$.list has fewer than minItems'* ]]
  [[ "$output" == *'$.list[1] must be integer'* ]]
  [[ "$output" == *'$.extra is not allowed'* ]]
  run validate '{"type":"object","required":["a"]}' '{}'
  [ "$status" -eq 1 ]
  [[ "$output" == *'$.a is required'* ]]
}

@test "treats integers as numbers but not floats as integers" {
  run validate '{"type":"number"}' '3'
  [ "$status" -eq 0 ]
  run validate '{"type":"integer"}' '3.5'
  [ "$status" -eq 1 ]
}

@test "checks string and number constraints and combinators" {
  run validate '{"type":"string","pattern":"^[a-z]+$","minLength":2}' '"a1"'
  [ "$status" -eq 1 ]
  [[ "$output" == *'does not match pattern'* ]]
  run validate '{"type":"integer","minimum":1,"maximum":5}' '9'
  [ "$status" -eq 1 ]
  [[ "$output" == *'above maximum'* ]]
  run validate '{"oneOf":[{"type":"string"},{"type":"integer"}]}' '"a"'
  [ "$status" -eq 0 ]
  run validate '{"oneOf":[{"type":"string"},{"type":"string"}]}' '"a"'
  [ "$status" -eq 1 ]
  [[ "$output" == *'does not satisfy oneOf'* ]]
  run validate '{"not":{"type":"string"}}' '"a"'
  [ "$status" -eq 1 ]
  [[ "$output" == *'forbidden not schema'* ]]
}

@test "rejects schemas with unsupported keywords and invalid JSON input" {
  run validate '{"type":"object","patternProperties":{}}' '{}'
  [ "$status" -eq 1 ]
  [[ "$output" == *'$.patternProperties is not supported'* ]]
  run validate '{"type":"object"}' 'not json'
  [ "$status" -eq 1 ]
  [[ "$output" == *'value is not valid JSON'* ]]
}
