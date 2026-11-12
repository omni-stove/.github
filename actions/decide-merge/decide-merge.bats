#!/usr/bin/env bats
# decide-merge.sh の単体テスト。

setup() {
  ROOT="$(mktemp -d)"
  export GITHUB_OUTPUT="${ROOT}/output"
  : > "$GITHUB_OUTPUT"
  export REPO=o/r PR_REPO=o/r HAS_AGENT_APP=true FINALIZE=true DECISION=approve
  SCRIPT="${BATS_TEST_DIRNAME}/decide-merge.sh"
}

teardown() {
  rm -rf "$ROOT"
}

@test "merges an approved PR" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'should_merge=true' "$GITHUB_OUTPUT"
}

@test "merges without finalize regardless of the decision" {
  FINALIZE=false DECISION= run bash "$SCRIPT"
  grep -qx 'should_merge=true' "$GITHUB_OUTPUT"
}

@test "no merge when the review requested changes or was not submitted" {
  DECISION=request-changes run bash "$SCRIPT"
  grep -qx 'should_merge=false' "$GITHUB_OUTPUT"
  : > "$GITHUB_OUTPUT"
  DECISION= run bash "$SCRIPT"
  grep -qx 'should_merge=false' "$GITHUB_OUTPUT"
}

@test "no merge while auto-fix is about to push" {
  SHOULD_FIX=true run bash "$SCRIPT"
  grep -qx 'should_merge=false' "$GITHUB_OUTPUT"
}

@test "no merge for a fork or draft PR" {
  PR_REPO=someone/r run bash "$SCRIPT"
  grep -qx 'should_merge=false' "$GITHUB_OUTPUT"
  : > "$GITHUB_OUTPUT"
  PR_DRAFT=true run bash "$SCRIPT"
  grep -qx 'should_merge=false' "$GITHUB_OUTPUT"
}

@test "skip labels stop the merge, case-insensitively" {
  PR_LABELS_JSON='["bug","Skip-AutoMerge"]' run bash "$SCRIPT"
  grep -qx 'should_merge=false' "$GITHUB_OUTPUT"
  : > "$GITHUB_OUTPUT"
  PR_LABELS_JSON='["prototype"]' run bash "$SCRIPT"
  grep -qx 'should_merge=false' "$GITHUB_OUTPUT"
  : > "$GITHUB_OUTPUT"
  SKIP_LABELS='hold, do not merge' PR_LABELS_JSON='["do not merge"]' run bash "$SCRIPT"
  grep -qx 'should_merge=false' "$GITHUB_OUTPUT"
}

@test "an empty skip list and broken labels JSON merge" {
  SKIP_LABELS= PR_LABELS_JSON='["skip-automerge"]' run bash "$SCRIPT"
  grep -qx 'should_merge=true' "$GITHUB_OUTPUT"
  : > "$GITHUB_OUTPUT"
  PR_LABELS_JSON='not json' run bash "$SCRIPT"
  grep -qx 'should_merge=true' "$GITHUB_OUTPUT"
}

@test "no merge without the agent App, with a warning" {
  HAS_AGENT_APP=false run bash "$SCRIPT"
  grep -qx 'should_merge=false' "$GITHUB_OUTPUT"
  [[ "$output" == *"::warning::"* ]]
}
