#!/usr/bin/env bats
# fix-context のスクリプトの単体テスト。git / gh は固定の出力を返すスタブに差し替える。

setup() {
  ROOT="$(mktemp -d)"
  export GITHUB_OUTPUT="${ROOT}/output"
  : > "$GITHUB_OUTPUT"
  DIR="${BATS_TEST_DIRNAME}"
  export REPO=o/r PR=7

  export GIT_CMD="${ROOT}/git"
  cat > "$GIT_CMD" <<STUB
#!/usr/bin/env bash
cat "${ROOT}/log"
STUB
  chmod +x "$GIT_CMD"

  # gh は呼び出しの種類ごとに ${ROOT}/<種類> の中身を返す。ファイルが無ければ失敗する。
  export GH_CMD="${ROOT}/gh"
  cat > "$GH_CMD" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${ROOT}/gh-calls"
reply() { [ -f "${ROOT}/\$1" ] || { echo "no \$1" >&2; exit 1; }; cat "${ROOT}/\$1"; }
case "\$*" in
  *"--help"*) exit 0 ;;
  *"/runs/"*"/jobs"*) reply jobs ;;
  *"/jobs/"*"/logs"*) reply "joblog-\$(printf '%s' "\$*" | grep -oE 'jobs/[0-9]+' | cut -d/ -f2)" ;;
  "pr view"*) reply description ;;
  "issue view"*) printf 'EXCLUDE=%s\n' "\${EXCLUDE_LOGIN:-}" >> "${ROOT}/gh-calls"; reply comments ;;
  "api graphql"*) reply threads ;;
esac
STUB
  chmod +x "$GH_CMD"
}

teardown() {
  rm -rf "$ROOT"
}

# GITHUB_OUTPUT の key<<DELIM ... DELIM を取り出す。
output_value() {
  awk -v key="$1" '
    index($0, key "<<") == 1 { delim = substr($0, length(key) + 3); on = 1; next }
    on && $0 == delim { exit }
    on { print }' "$GITHUB_OUTPUT"
}

@test "guard: skip=false below the limit, counting only leading fix commits" {
  printf '[agent-fix] a\n[agent-fix] b\nfeat: c\n' > "${ROOT}/log"
  run bash "${DIR}/guard-fix-loop.sh"
  [ "$status" -eq 0 ]
  grep -qx 'skip=false' "$GITHUB_OUTPUT"
  grep -qx 'count=2' "$GITHUB_OUTPUT"
}

@test "guard: skip=true at the limit" {
  printf '[agent-fix] a\n[agent-fix] b\n[agent-fix] c\n' > "${ROOT}/log"
  run bash "${DIR}/guard-fix-loop.sh"
  grep -qx 'skip=true' "$GITHUB_OUTPUT"
}

@test "guard: a human commit on top resets the count" {
  printf 'fix: by hand\n[agent-fix] a\n[agent-fix] b\n' > "${ROOT}/log"
  run bash "${DIR}/guard-fix-loop.sh"
  grep -qx 'count=0' "$GITHUB_OUTPUT"
}

@test "ci failure: extracts the failing block with context and lists the jobs" {
  printf '{"jobs":[{"name":"ci / Lint","id":11,"status":"completed","conclusion":"failure"},{"name":"ci / Test","id":12,"status":"completed","conclusion":"success"}]}' \
    | jq -c '.jobs[]' > "${ROOT}/jobs"
  {
    for i in $(seq 1 30); do echo "noise $i"; done
    echo "src/a.ts(3,1): error TS2322: Type 'string' is not assignable to type 'number'."
    echo "detail after"
    for i in $(seq 1 30); do echo "tail $i"; done
  } > "${ROOT}/joblog-11"
  RUN_ID=99 run bash "${DIR}/fetch-ci-failure.sh"
  [ "$status" -eq 0 ]
  grep -qx 'has_failure_context=true' "$GITHUB_OUTPUT"
  body="$(output_value body)"
  [[ "$body" == *"- [failure] ci / Lint"* ]]
  [[ "$body" == *"- [success] ci / Test"* ]]
  [[ "$body" == *"## 失敗ジョブ: ci / Lint (job 11)"* ]]
  [[ "$body" == *"error TS2322"* ]]
  [[ "$body" == *"detail after"* ]]
  [[ "$body" == *"noise 25"* ]]
  [[ "$body" != *"noise 1"$'\n'* ]]
  [[ "$body" != *"tail 30"* ]]
}

@test "ci failure: a log fetch error is reported, not mistaken for no errors" {
  printf '{"name":"ci / Lint","id":11,"status":"completed","conclusion":"failure"}\n' > "${ROOT}/jobs"
  RUN_ID=99 run bash "${DIR}/fetch-ci-failure.sh"
  [ "$status" -eq 0 ]
  grep -qx 'has_failure_context=false' "$GITHUB_OUTPUT"
  [[ "$(output_value body)" == *"(ログ取得に失敗: no joblog-11"* ]]
}

@test "ci failure: no failed jobs says so" {
  printf '{"name":"ci / Lint","id":11,"status":"completed","conclusion":"success"}\n' > "${ROOT}/jobs"
  RUN_ID=99 run bash "${DIR}/fetch-ci-failure.sh"
  grep -qx 'has_failure_context=false' "$GITHUB_OUTPUT"
  [[ "$(output_value body)" == *"見つかりませんでした"* ]]
}

@test "ci failure: the body is capped at MAX_BYTES with a note" {
  printf '{"name":"ci / Lint","id":11,"status":"completed","conclusion":"failure"}\n' > "${ROOT}/jobs"
  for i in $(seq 1 200); do echo "FAIL test $i"; done > "${ROOT}/joblog-11"
  MAX_BYTES=500 RUN_ID=99 run bash "${DIR}/fetch-ci-failure.sh"
  [[ "$(output_value body)" == *"(CI failure log truncated: exceeded 500 bytes)"* ]]
}

@test "pr context: wraps the description and comments and excludes the bot" {
  printf '# Title\n\nBody' > "${ROOT}/description"
  printf '### @alice (t)\nkeep this\n' > "${ROOT}/comments"
  BOT_LOGIN=agent-app run bash "${DIR}/fetch-pr-context.sh"
  [ "$status" -eq 0 ]
  body="$(output_value body)"
  [[ "$body" == *"<pr-description>"$'\n'"# Title"* ]]
  [[ "$body" == *"<pr-comments>"$'\n'"### @alice (t)"* ]]
  grep -qx 'EXCLUDE=agent-app' "${ROOT}/gh-calls"
}

@test "pr context: empty body when nothing can be fetched" {
  run bash "${DIR}/fetch-pr-context.sh"
  [ "$status" -eq 0 ]
  [ -z "$(output_value body)" ]
}

@test "review comments: wraps the comments and sets has_comments" {
  printf '### @reviewer a.ts:3 [comment_id=5]\nfix this\n' > "${ROOT}/threads"
  run bash "${DIR}/fetch-review-comments.sh"
  [ "$status" -eq 0 ]
  grep -qx 'has_comments=true' "$GITHUB_OUTPUT"
  [[ "$(output_value body)" == *"<review-comments>"$'\n'"### @reviewer a.ts:3 [comment_id=5]"* ]]
}

@test "review comments: opt-out skips the fetch and leaves the body empty" {
  printf 'x\n' > "${ROOT}/threads"
  FIX_REVIEW_COMMENTS=false run bash "${DIR}/fetch-review-comments.sh"
  grep -qx 'has_comments=false' "$GITHUB_OUTPUT"
  [ -z "$(output_value body)" ]
  ! grep -q graphql "${ROOT}/gh-calls" 2>/dev/null
}

@test "review comments: no threads gives has_comments=false" {
  : > "${ROOT}/threads"
  run bash "${DIR}/fetch-review-comments.sh"
  grep -qx 'has_comments=false' "$GITHUB_OUTPUT"
}

@test "ci failure: an unreadable job list degrades to no context with a warning" {
  RUN_ID=99 run bash "${DIR}/fetch-ci-failure.sh"
  [ "$status" -eq 0 ]
  grep -qx 'has_failure_context=false' "$GITHUB_OUTPUT"
  [[ "$output" == *"actions: read"* ]]
}
