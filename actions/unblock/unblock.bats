#!/usr/bin/env bats
# unblock.sh の単体テスト。gh は fixtures/<path>.json を --jq で絞って返すスタブに差し替える。

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/unblock.sh"
  FIX="$BATS_TEST_TMPDIR/fixtures"
  CALLS="$BATS_TEST_TMPDIR/calls"
  mkdir -p "$FIX"
  : > "$CALLS"
  cat > "$BATS_TEST_TMPDIR/gh" <<STUB
#!/usr/bin/env bash
echo "gh \$*" >> "$CALLS"
[ "\$1" = api ] || exit 0
path= jq=
shift
while [ \$# -gt 0 ]; do
  case "\$1" in
    --jq) jq="\$2"; shift 2 ;;
    --paginate) shift ;;
    *) path="\$1"; shift ;;
  esac
done
file="$FIX/\$(printf '%s' "\${path#repos/\{owner\}/\{repo\}/}" | tr '/?&=' '____').json"
[ -f "\$file" ] || exit 1
jq -r "\${jq:-.}" "\$file"
STUB
  chmod +x "$BATS_TEST_TMPDIR/gh"
  export GH_CMD="$BATS_TEST_TMPDIR/gh"
  unset CLOSED_ISSUE PARENTS GITHUB_STEP_SUMMARY
}

# fixture <api path> <json>
fixture() { printf '%s' "$2" > "$FIX/$(printf '%s' "$1" | tr '/?&=' '____').json"; }

# issue <number> <labels json> [type] [state]
issue() {
  printf '{"number":%s,"state":"%s","labels":%s,"type":%s,"user":{"login":"me"},"title":"t%s","html_url":"u%s"}' \
    "$1" "${4:-open}" "$2" "${3:-null}" "$1" "$1"
}

# blocker <number> <state> <state_reason>
blocker() { printf '{"number":%s,"state":"%s","state_reason":%s}' "$1" "$2" "$3"; }

no_comments() { for n in "$@"; do fixture "issues/$n/comments" '[]'; done; }

@test "rejects a non-number" {
  PARENTS=x run "$SCRIPT"
  [ "$status" -eq 2 ]
  CLOSED_ISSUE=1a run "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "labels a sub-issue whose blockers all completed, bug for a Bug type, and tells the parent" {
  fixture issues/5/dependencies/blocking "[$(issue 7 '[]' '{"name":"Bug"}'),$(issue 8 '[{"name":"implementation"}]')]"
  fixture issues/7/parent '{"number":3}'
  fixture issues/7/dependencies/blocked_by "[$(blocker 5 closed '"completed"'),$(blocker 6 closed '"completed"')]"
  no_comments 3
  CLOSED_ISSUE=5 run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'labeled\t7\tbug\tt7\tu7\t')" ]
  grep -qx 'gh issue edit 7 --add-label bug' "$CALLS"
  grep -q 'gh issue comment 3 --body <!-- unblock:labeled:7 -->' "$CALLS"
  grep -q '#5 #6 がすべて完了' "$CALLS"
  ! grep -q 'issues/8/' "$CALLS" || false
}

@test "leaves an issue with no parent alone" {
  fixture issues/5/dependencies/blocking "[$(issue 7 '[]')]"
  fixture issues/7/dependencies/blocked_by "[$(blocker 5 closed '"completed"')]"
  CLOSED_ISSUE=5 run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ! grep -q 'issue edit' "$CALLS" || false
}

@test "keeps waiting while a blocker is open" {
  fixture issues/5/dependencies/blocking "[$(issue 7 '[]')]"
  fixture issues/7/parent '{"number":3}'
  fixture issues/7/dependencies/blocked_by "[$(blocker 5 closed '"completed"'),$(blocker 6 open null)]"
  CLOSED_ISSUE=5 run "$SCRIPT"
  [ "$output" = "$(printf 'waiting\t7\timplementation\tt7\tu7\t#6')" ]
  ! grep -q 'issue edit\|issue comment' "$CALLS" || false
}

@test "a blocker closed as not planned tells the parent without labeling" {
  fixture issues/5/dependencies/blocking "[$(issue 7 '[]')]"
  fixture issues/7/parent '{"number":3}'
  fixture issues/7/dependencies/blocked_by "[$(blocker 5 closed '"not_planned"')]"
  no_comments 3
  CLOSED_ISSUE=5 run "$SCRIPT"
  [ "$output" = "$(printf 'dropped\t7\timplementation\tt7\tu7\t#5')" ]
  ! grep -q 'issue edit' "$CALLS" || false
  grep -q 'gh issue comment 3 --body <!-- unblock:dropped:7 -->' "$CALLS"
}

@test "a manual issue is never labeled; its author is told it is theirs, once" {
  fixture issues/5/dependencies/blocking "[$(issue 9 '[{"name":"manual"}]')]"
  fixture issues/9/parent '{"number":3}'
  fixture issues/9/dependencies/blocked_by "[$(blocker 5 closed '"completed"')]"
  no_comments 9
  CLOSED_ISSUE=5 run "$SCRIPT"
  [ "$output" = "$(printf 'yours\t9\tmanual\tt9\tu9\t')" ]
  ! grep -q 'issue edit' "$CALLS" || false
  grep -q 'gh issue comment 9 --body <!-- unblock:yours -->' "$CALLS"
  grep -q '@me ' "$CALLS"
  : > "$CALLS"
  fixture issues/9/comments '[{"body":"<!-- unblock:yours -->\nold"}]'
  CLOSED_ISSUE=5 run "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q 'issue comment' "$CALLS" || false
}

@test "without an issue scans every open parent and tells the parent of an unlinked sub-issue" {
  fixture "issues?state=open&per_page=100" '[{"number":3,"sub_issues_summary":{"total":2,"completed":0}},{"number":4,"pull_request":{},"sub_issues_summary":{"total":1,"completed":0}},{"number":10,"sub_issues_summary":{"total":1,"completed":1}}]'
  fixture issues/3/sub_issues "[$(issue 7 '[]'),$(issue 8 '[]' null closed)]"
  fixture issues/7/dependencies/blocked_by '[]'
  no_comments 3
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'unlinked\t7\timplementation\tt7\tu7\t')" ]
  grep -q 'gh issue comment 3 --body <!-- unblock:unlinked:7 -->' "$CALLS"
  ! grep -q 'issues/4/\|issues/10/\|issues/8/' "$CALLS" || false
}

@test "PARENTS limits the scan and the summary gets a row per sub-issue" {
  fixture issues/3/sub_issues "[$(issue 7 '[]')]"
  fixture issues/7/dependencies/blocked_by "[$(blocker 6 open null)]"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary"
  PARENTS=3 run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'waiting\t7\timplementation\tt7\tu7\t#6')" ]
  ! grep -q 'issues?state' "$CALLS" || false
  grep -qF '| waiting | [#7 t7](u7) | implementation | #6 |' "$GITHUB_STEP_SUMMARY"
}

@test "a failed list stops the run instead of reading as empty" {
  PARENTS=3 run "$SCRIPT"
  [ "$status" -ne 0 ]
}
