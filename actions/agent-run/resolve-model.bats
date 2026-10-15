#!/usr/bin/env bats
SCRIPT="${BATS_TEST_DIRNAME}/resolve-model.sh"

setup() {
  DIR="$(mktemp -d)"
  mkdir "$DIR/bin"
  export PATH="$DIR/bin:$PATH"
  export GITHUB_OUTPUT="$DIR/github-output"
  export OPENAI_API_KEY=openai-test-key
}

teardown() {
  rm -rf "$DIR"
}

stub_models() {
  # $@=モデル ID
  local ids
  ids="$(printf '%s\n' "$@" | jq -R . | jq -sc 'map({id: .})')"
  printf '#!/usr/bin/env bash\nprintf %%s %q\n' "{\"data\":$ids}" > "$DIR/bin/curl"
  chmod +x "$DIR/bin/curl"
}

stub_curl_failure() {
  printf '#!/usr/bin/env bash\nexit 22\n' > "$DIR/bin/curl"
  chmod +x "$DIR/bin/curl"
}

MODELS=(gpt-5.6-sol gpt-6-sol gpt-6.1-sol gpt-6.1-sol-2026-09-29 gpt-6-luna gpt-5.6-terra gpt-6.1-astra gpt-10-solar)

@test "maps each tier to its Claude alias without calling the API" {
  stub_curl_failure
  PROVIDER=claude TIER=high run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'provider=claude' "$GITHUB_OUTPUT"
  grep -qx 'model=opus' "$GITHUB_OUTPUT"
  : > "$GITHUB_OUTPUT"
  PROVIDER=claude TIER=medium run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'model=sonnet' "$GITHUB_OUTPUT"
  : > "$GITHUB_OUTPUT"
  PROVIDER=claude TIER=max run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'model=fable' "$GITHUB_OUTPUT"
  : > "$GITHUB_OUTPUT"
  PROVIDER=claude TIER=low run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'model=haiku' "$GITHUB_OUTPUT"
}

@test "resolves a Codex tier to its newest generation" {
  stub_models "${MODELS[@]}"
  PROVIDER=codex TIER=high run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'provider=codex' "$GITHUB_OUTPUT"
  grep -qx 'model=gpt-6.1-sol' "$GITHUB_OUTPUT"
  : > "$GITHUB_OUTPUT"
  PROVIDER=codex TIER=max run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'model=gpt-6.1-astra' "$GITHUB_OUTPUT"
  : > "$GITHUB_OUTPUT"
  PROVIDER=codex TIER=low run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'model=gpt-6-luna' "$GITHUB_OUTPUT"
}

@test "compares Codex generations as version numbers" {
  stub_models "${MODELS[@]}" gpt-6.9-sol gpt-6.10-sol
  PROVIDER=codex TIER=high run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'model=gpt-6.10-sol' "$GITHUB_OUTPUT"
}

@test "resolves a Codex tier missing from the newest generation to its latest available model" {
  stub_models "${MODELS[@]}"
  PROVIDER=codex TIER=medium run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'model=gpt-5.6-terra' "$GITHUB_OUTPUT"
}

@test "fails on an unknown tier or provider" {
  PROVIDER=claude TIER=xhigh run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tier must be max, high, medium, or low: xhigh"* ]]
  PROVIDER=gemini TIER=high run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"provider must be claude or codex: gemini"* ]]
}

@test "fails when no model exists for the tier" {
  stub_models gpt-6-sol
  PROVIDER=codex TIER=medium run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no OpenAI model found for tier: terra"* ]]
}

@test "fails when listing models fails" {
  stub_curl_failure
  PROVIDER=codex TIER=high run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to list OpenAI models"* ]]
}
