#!/usr/bin/env bats
# post-fix-result.sh の単体テスト。gh は呼び出しを 1 行ずつ記録するスタブに差し替える。

setup() {
  ROOT="$(mktemp -d)"
  CALLS="${ROOT}/gh-calls"
  : > "$CALLS"
  export GH_CMD="${ROOT}/gh"
  cat > "$GH_CMD" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" | tr '\n' ' ' >> "${CALLS}"
echo >> "${CALLS}"
case "\$*" in
  *"--paginate"*) cat "${ROOT}/existing" 2>/dev/null ;;
  *"/replies"*) [ ! -f "${ROOT}/reply-fail" ] ;;
esac
STUB
  chmod +x "$GH_CMD"
  export PR=7 REPO=o/r
  SCRIPT="${BATS_TEST_DIRNAME}/post-fix-result.sh"
}

teardown() {
  rm -rf "$ROOT"
}

@test "pushed: posts the summary and replies to each thread" {
  STRUCTURED='{"summary":"直した","replies":[{"comment_id":5,"note":"修正した"},{"comment_id":6,"note":"  "},{"comment_id":"x","note":"bad"}]}' \
    RESULT=pushed RUN_URL=https://run run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^pr comment 7 --repo o/r --body 直した' "$CALLS"
  grep -q '実行ログ: https://run' "$CALLS"
  grep -q 'repos/o/r/pulls/7/comments/5/replies -f body=修正した' "$CALLS"
  [ "$(grep -c '/replies' "$CALLS")" -eq 1 ]
}

@test "noop: posts the summary but no replies" {
  STRUCTURED='{"summary":"修正不要","replies":[{"comment_id":5,"note":"x"}]}' RESULT=noop run bash "$SCRIPT"
  grep -q 'body 修正不要' "$CALLS"
  ! grep -q '/replies' "$CALLS"
}

@test "an empty summary falls back to a default text" {
  RESULT= run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'サマリが返らなかった' "$CALLS"
}

@test "an empty summary under a rate limit says so" {
  RATE_LIMITED=true RATE_LIMIT_RESET=0 run bash "$SCRIPT"
  grep -q 'レート制限' "$CALLS"
}

@test "skipped posts nothing" {
  RESULT=skipped run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}

@test "external prefixes the summary" {
  STRUCTURED='{"summary":"main 側の型定義が原因"}' RESULT=external run bash "$SCRIPT"
  grep -q '差分外にあるため.*main 側の型定義が原因' "$CALLS"
}

@test "loop creates the give-up comment once and updates it afterwards" {
  RESULT=loop MAX_CONSECUTIVE=3 run bash "$SCRIPT"
  grep -q 'repos/o/r/issues/7/comments -f body=<!-- agent-fix-giveup -->' "$CALLS"
  ! grep -q '^pr comment' "$CALLS"
  : > "$CALLS"
  echo 42 > "${ROOT}/existing"
  RESULT=loop run bash "$SCRIPT"
  grep -q '^api -X PATCH repos/o/r/issues/comments/42' "$CALLS"
}

@test "conflict upserts the notice and posts the summary" {
  STRUCTURED='{"summary":"直した"}' RESULT=conflict REF=feature/x run bash "$SCRIPT"
  grep -q '<!-- agent-fix-conflict -->.*feature/x' "$CALLS"
  grep -q '^pr comment 7 --repo o/r --body 直した' "$CALLS"
}

@test "a failed reply does not stop the others" {
  : > "${ROOT}/reply-fail"
  STRUCTURED='{"summary":"s","replies":[{"comment_id":5,"note":"a"},{"comment_id":6,"note":"b"}]}' RESULT=pushed run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '/replies' "$CALLS")" -eq 2 ]
  [[ "$output" == *"posted 0 reply/replies (2 failed)."* ]]
}
