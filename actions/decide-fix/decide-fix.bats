#!/usr/bin/env bats
# decide-fix.sh の単体テスト。gh はオプトアウトファイルの中身を返すスタブに差し替える。

setup() {
  ROOT="$(mktemp -d)"
  export GITHUB_OUTPUT="${ROOT}/output"
  : > "$GITHUB_OUTPUT"
  OPT_OUT="${ROOT}/opt-out"
  export GH_CMD="${ROOT}/gh"
  cat > "$GH_CMD" <<STUB
#!/usr/bin/env bash
[ -f "${OPT_OUT}" ] || exit 1
cat "${OPT_OUT}"
STUB
  chmod +x "$GH_CMD"
  export REPO=o/r PR_REPO=o/r PR_AUTHOR=alice HAS_AGENT_APP=true
  export OPT_OUT_PATH=.github/autofix-opt-out.yml
  SCRIPT="${BATS_TEST_DIRNAME}/decide-fix.sh"
}

teardown() {
  rm -rf "$ROOT"
}

@test "trigger=ci when lint or test failed" {
  LINT_TEST_RESULTS="success failure" REVIEW_COMMENT_COUNT=2 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'should_fix=true' "$GITHUB_OUTPUT"
  grep -qx 'trigger=ci' "$GITHUB_OUTPUT"
  grep -qx 'fix_review_comments=true' "$GITHUB_OUTPUT"
}

@test "trigger=review when lint/test passed and the review has comments" {
  LINT_TEST_RESULTS="success skipped" REVIEW_COMMENT_COUNT=1 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'trigger=review' "$GITHUB_OUTPUT"
}

@test "no fix when nothing failed and there are no comments" {
  LINT_TEST_RESULTS="success cancelled" REVIEW_COMMENT_COUNT=0 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'should_fix=false' "$GITHUB_OUTPUT"
  ! grep -q '^trigger=' "$GITHUB_OUTPUT"
}

@test "no fix for a fork PR" {
  PR_REPO=someone/r LINT_TEST_RESULTS=failure run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'should_fix=false' "$GITHUB_OUTPUT"
}

@test "no fix without the agent App, with a warning" {
  HAS_AGENT_APP=false LINT_TEST_RESULTS=failure run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'should_fix=false' "$GITHUB_OUTPUT"
  [[ "$output" == *"::warning::"* ]]
}

@test "skip-autofix label stops review fixes but not lint/test fixes" {
  PR_LABELS_JSON='["Skip-Autofix"]' REVIEW_COMMENT_COUNT=3 run bash "$SCRIPT"
  grep -qx 'should_fix=false' "$GITHUB_OUTPUT"
  : > "$GITHUB_OUTPUT"
  PR_LABELS_JSON='["skip-autofix"]' LINT_TEST_RESULTS=failure REVIEW_COMMENT_COUNT=3 run bash "$SCRIPT"
  grep -qx 'trigger=ci' "$GITHUB_OUTPUT"
  grep -qx 'fix_review_comments=false' "$GITHUB_OUTPUT"
}

@test "an opted-out author in flow style gets no review fix" {
  printf 'users: [bob, Alice]  # note [#1]\n' > "$OPT_OUT"
  REVIEW_COMMENT_COUNT=1 run bash "$SCRIPT"
  grep -qx 'should_fix=false' "$GITHUB_OUTPUT"
}

@test "an opted-out author in block style gets no review fix" {
  printf 'users:\n  - bob\n  - "alice"  # temporarily\n' > "$OPT_OUT"
  REVIEW_COMMENT_COUNT=1 run bash "$SCRIPT"
  grep -qx 'should_fix=false' "$GITHUB_OUTPUT"
}

@test "a commented-out author is not opted out" {
  printf 'users:\n  # - alice\n  - bob\n' > "$OPT_OUT"
  REVIEW_COMMENT_COUNT=1 run bash "$SCRIPT"
  grep -qx 'trigger=review' "$GITHUB_OUTPUT"
}

@test "force-autofix overrides the opt-out, skip-autofix wins over force" {
  printf 'users: [alice]\n' > "$OPT_OUT"
  PR_LABELS_JSON='["force-autofix"]' REVIEW_COMMENT_COUNT=1 run bash "$SCRIPT"
  grep -qx 'trigger=review' "$GITHUB_OUTPUT"
  : > "$GITHUB_OUTPUT"
  PR_LABELS_JSON='["force-autofix","skip-autofix"]' REVIEW_COMMENT_COUNT=1 run bash "$SCRIPT"
  grep -qx 'should_fix=false' "$GITHUB_OUTPUT"
}

@test "a missing opt-out file or broken labels fall back to fixing" {
  PR_LABELS_JSON='not json' REVIEW_COMMENT_COUNT=1 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'trigger=review' "$GITHUB_OUTPUT"
}
