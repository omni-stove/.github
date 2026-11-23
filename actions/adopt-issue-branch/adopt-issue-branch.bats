#!/usr/bin/env bats
# adopt-issue-branch.sh の単体テスト。git と gh はスタブし、呼び出しを記録する。

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$BATS_TEST_TMPDIR"
  CALLS="${ROOT}/calls"
  : > "$CALLS"
  echo 1 > "${ROOT}/remote" # 1 = origin にブランチがある
  echo 0 > "${ROOT}/prs"    # そのブランチから作った PR の数
  echo 2 > "${ROOT}/ahead"  # base より先のコミット数
  SCRIPT="${BATS_TEST_DIRNAME}/adopt-issue-branch.sh"

  mkdir -p "${ROOT}/bin"
  cat > "${ROOT}/bin/git" <<STUB
#!/usr/bin/env bash
echo "git \$*" >> "$CALLS"
case "\$1" in
  ls-remote) [ "\$(cat "${ROOT}/remote")" = 1 ] ;;
  rev-list) cat "${ROOT}/ahead" ;;
esac
STUB
  export GH_CMD="${ROOT}/bin/gh"
  cat > "$GH_CMD" <<STUB
#!/usr/bin/env bash
echo "gh \$*" >> "$CALLS"
case "\$1 \$2" in
  "pr list") cat "${ROOT}/prs" ;;
  "pr create")
    prev=""
    for a in "\$@"; do
      [ "\$prev" = --body ] && printf '%s' "\$a" > "${ROOT}/body"
      prev="\$a"
    done
    echo "https://github.com/o/r/pull/42" ;;
esac
STUB
  chmod +x "${ROOT}/bin/git" "$GH_CMD"
  PATH="${ROOT}/bin:${PATH}"

  export GITHUB_OUTPUT="${ROOT}/output"
  : > "$GITHUB_OUTPUT"
  export BRANCH=agent-fix/issue-7 BASE=main ISSUE=7 TITLE="ボタンが押せない"
}

@test "errors when a required input is missing" {
  TITLE= run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "creates the PR from the existing branch with the issue title and Closes" {
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^gh pr create --base main --head agent-fix/issue-7 --title ボタンが押せない --body ' "$CALLS"
  grep -q '^- Closes #7$' "${ROOT}/body"
  grep -q '^## 目的$' "${ROOT}/body"
  grep -qx 'pr_url=https://github.com/o/r/pull/42' "$GITHUB_OUTPUT"
  grep -qx 'pr_number=42' "$GITHUB_OUTPUT"
}

@test "looks up PRs of every state, not only open ones" {
  run bash "$SCRIPT"
  grep -q '^gh pr list --head agent-fix/issue-7 --state all ' "$CALLS"
}

@test "passes --draft and adds the labels one by one" {
  DRAFT=true LABELS="security App:web" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q -- '--draft$' "$CALLS"
  grep -q '^gh pr edit https://github.com/o/r/pull/42 --add-label security$' "$CALLS"
  grep -q '^gh pr edit https://github.com/o/r/pull/42 --add-label App:web$' "$CALLS"
}

@test "skips with empty outputs when the branch is not on origin" {
  echo 0 > "${ROOT}/remote"
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q 'pr create' "$CALLS" || false
  grep -qx 'pr_url=' "$GITHUB_OUTPUT"
}

@test "skips when a PR from the branch already exists" {
  echo 1 > "${ROOT}/prs"
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"a PR from it already exists"* ]]
  ! grep -q 'pr create' "$CALLS" || false
  grep -qx 'pr_url=' "$GITHUB_OUTPUT"
}

@test "skips when the branch has no commits ahead of the base" {
  echo 0 > "${ROOT}/ahead"
  run --separate-stderr bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"no commits ahead of main"* ]]
  ! grep -q 'pr create' "$CALLS" || false
}
