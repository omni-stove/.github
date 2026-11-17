#!/usr/bin/env bats
# decide-merge.sh の単体テスト。

setup() {
  ROOT="$(mktemp -d)"
  export GITHUB_OUTPUT="${ROOT}/output"
  : > "$GITHUB_OUTPUT"
  export REPO=o/r PR_REPO=o/r HAS_AGENT_APP=true FINALIZE=true DECISION=approve
  SCRIPT="${BATS_TEST_DIRNAME}/decide-merge.sh"
  export REVIEWS="${ROOT}/reviews.json" PR_NUMBER=5 REVIEWER_LOGIN='rev[bot]'
  mkdir -p "${ROOT}/bin"
  cat > "${ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ -f "$REVIEWS" ] || exit 1
while [ $# -gt 0 ] && [ "$1" != --jq ]; do shift; done
jq -r "$2" "$REVIEWS"
EOF
  chmod +x "${ROOT}/bin/gh"
  export GH_CMD="${ROOT}/bin/gh"
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

@test "a conflict-resolution-only run merges when the reviewer's latest decision is approve" {
  echo '[{"user":{"login":"rev[bot]"},"state":"CHANGES_REQUESTED"},{"user":{"login":"rev[bot]"},"state":"APPROVED"},{"user":{"login":"rev[bot]"},"state":"COMMENTED"},{"user":{"login":"human"},"state":"CHANGES_REQUESTED"}]' > "$REVIEWS"
  RESOLUTION_ONLY=true DECISION= run bash "$SCRIPT"
  grep -qx 'should_merge=true' "$GITHUB_OUTPUT"
}

@test "a conflict-resolution-only run does not merge when the reviewer's latest decision is not approve" {
  echo '[{"user":{"login":"rev[bot]"},"state":"APPROVED"},{"user":{"login":"rev[bot]"},"state":"CHANGES_REQUESTED"}]' > "$REVIEWS"
  RESOLUTION_ONLY=true DECISION= run bash "$SCRIPT"
  grep -qx 'should_merge=false' "$GITHUB_OUTPUT"
  : > "$GITHUB_OUTPUT"
  echo '[{"user":{"login":"other[bot]"},"state":"APPROVED"}]' > "$REVIEWS"
  RESOLUTION_ONLY=true DECISION= run bash "$SCRIPT"
  grep -qx 'should_merge=false' "$GITHUB_OUTPUT"
}

@test "a conflict-resolution-only run does not merge when the reviews cannot be read" {
  RESOLUTION_ONLY=true DECISION= run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'should_merge=false' "$GITHUB_OUTPUT"
}
