#!/usr/bin/env bats
# create-issue-pr.sh の単体テスト。git は dirty 判定をスタブし、create-pr.sh は呼び出しを記録する
# スタブに差し替える (実 commit / push / PR 作成はしない)。pr-body-template.sh は実物を使う。

setup() {
  ROOT="$(mktemp -d)"
  CALLS="${ROOT}/calls"
  : > "$CALLS"
  DIRTY="${ROOT}/dirty"
  echo 1 > "$DIRTY"
  SCRIPT="${BATS_TEST_DIRNAME}/create-issue-pr.sh"

  export CREATE_PR_CMD="${ROOT}/create-pr"
  cat > "$CREATE_PR_CMD" <<STUB
#!/usr/bin/env bash
echo "create-pr \$*" >> "$CALLS"
echo "https://github.com/o/r/pull/777"
STUB
  chmod +x "$CREATE_PR_CMD"

  STUB_DIR="${ROOT}/bin"
  mkdir -p "$STUB_DIR"
  cat > "${STUB_DIR}/git" <<STUB
#!/usr/bin/env bash
case "\$1" in
  status) [ "\$(cat "$DIRTY")" = "0" ] || echo " M file" ;;
  rev-parse) echo "\${HEAD_SHA:-abc}" ;;
esac
STUB
  chmod +x "${STUB_DIR}/git"
  PATH="${STUB_DIR}:${PATH}"

  export GH_CMD="${STUB_DIR}/gh"
  cat > "$GH_CMD" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "${ROOT}/gh-calls"
STUB
  chmod +x "$GH_CMD"
  export GITHUB_OUTPUT="${ROOT}/output"
  : > "$GITHUB_OUTPUT"
  export BASE=main
}

teardown() {
  rm -rf "$ROOT"
}

@test "errors when BRANCH or BASE is missing" {
  BASE=main run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  BASE= BRANCH=b run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "skips the PR when the working tree is clean and writes empty outputs" {
  echo 0 > "$DIRTY"
  BRANCH=agent-fix/issue-1 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q 'create-pr' "$CALLS"
  grep -qx 'pr_url=' "$GITHUB_OUTPUT"
  grep -qx 'pr_number=' "$GITHUB_OUTPUT"
}

@test "treats commits the agent made as changes when START_SHA differs" {
  echo 0 > "$DIRTY"
  START_SHA=before HEAD_SHA=after BRANCH=b run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'create-pr b main' "$CALLS"
}

@test "passes branch, base, message, title and the template body to create-pr.sh" {
  STRUCTURED='{"message":"fix: bug","title":"バグを直す","purpose":"本文"}' \
    BRANCH=agent-fix/issue-1 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'create-pr agent-fix/issue-1 main fix: bug バグを直す ## 目的' "$CALLS"
  grep -q '本文' "$CALLS"
  grep -qx 'pr_url=https://github.com/o/r/pull/777' "$GITHUB_OUTPUT"
  grep -qx 'pr_number=777' "$GITHUB_OUTPUT"
}

@test "defaults empty fields" {
  STRUCTURED='{}' BRANCH=b run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'create-pr b main Apply changes from issue Apply changes from issue ## 目的' "$CALLS"
  grep -q '(記載なし)' "$CALLS"
  grep -q '特になし' "$CALLS"
}

@test "defaults to title for message when only title is present" {
  STRUCTURED='{"title":"T"}' BRANCH=b run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'create-pr b main T T ## 目的' "$CALLS"
}

@test "passes labels and draft through" {
  STRUCTURED='{"message":"m","title":"t"}' \
    BRANCH=b LABELS='prototype App:web' DRAFT=true run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q -- '--label prototype --label App:web --draft' "$CALLS"
}

@test "closes the issue only when closes_issue is true" {
  STRUCTURED='{"message":"m","title":"t","purpose":"p","closes_issue":true}' \
    BRANCH=b ISSUE=7 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q -- '- Closes #7' "$CALLS"
  : > "$CALLS"
  STRUCTURED='{"message":"m","title":"t","purpose":"p","closes_issue":false}' \
    BRANCH=b ISSUE=7 run bash "$SCRIPT"
  grep -q -- '- refs #7' "$CALLS"
  ! grep -q 'Closes' "$CALLS"
  : > "$CALLS"
  STRUCTURED='{"message":"m","title":"t","purpose":"p"}' BRANCH=b ISSUE=7 run bash "$SCRIPT"
  grep -q -- '- refs #7' "$CALLS"
}

@test "strips closing keywords the agent wrote so closes_issue alone decides" {
  STRUCTURED='{"message":"Fixes #99","title":"resolves #42","purpose":"Closes #99 と closes: #42 を直す","approach":"fixed #7","verification":"v","review_points":"r","closes_issue":false}' \
    BRANCH=b ISSUE=99 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -qiE '(close[sd]?|fix(e[sd])?|resolve[sd]?):? *#' "$CALLS"
  grep -q -- '- refs #99' "$CALLS"
  grep -q '#99 と #42 を直す' "$CALLS"
}

@test "assembles all four template sections" {
  STRUCTURED='{"message":"m","title":"t","purpose":"落ちるのを直す","approach":"null ガードを追加","verification":"一覧画面で確かめる","review_points":"境界値","closes_issue":true}' \
    BRANCH=b ISSUE=7 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '## 目的' "$CALLS"
  grep -q '落ちるのを直す' "$CALLS"
  grep -q '## 実装方針' "$CALLS"
  grep -q 'null ガードを追加' "$CALLS"
  grep -q '## 確認方法' "$CALLS"
  grep -q '一覧画面で確かめる' "$CALLS"
  grep -q '## 見て欲しいポイント' "$CALLS"
  grep -q '境界値' "$CALLS"
}

@test "comments the no-PR reason and run URL on the issue when clean" {
  echo 0 > "$DIRTY"
  STRUCTURED='{"message":"着手条件を確認できない\n依存 Issue に接続できない","title":"t"}' \
    GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=123 \
    BRANCH=b ISSUE=810 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'issue' "${ROOT}/gh-calls"
  grep -qx 'comment' "${ROOT}/gh-calls"
  grep -qx '810' "${ROOT}/gh-calls"
  grep -qx '> 着手条件を確認できない' "${ROOT}/gh-calls"
  grep -qx '> 依存 Issue に接続できない' "${ROOT}/gh-calls"
  grep -q '実行ログ: https://github.com/o/r/actions/runs/123' "${ROOT}/gh-calls"
}

@test "does not fail when commenting the no-PR reason fails, and does not call gh without ISSUE" {
  echo 0 > "$DIRTY"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$GH_CMD"
  STRUCTURED='{"message":"m","title":"t"}' BRANCH=b ISSUE=811 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  printf '#!/usr/bin/env bash\necho "gh should not be called" >&2\nexit 3\n' > "$GH_CMD"
  STRUCTURED='{"message":"m","title":"t"}' BRANCH=b run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}
