#!/usr/bin/env bats
# check-conflict-resolution.sh の単体テスト。マージの中身を見るため git は一時リポジトリで走らせ、gh だけスタブにする。

setup() {
  ROOT="$(mktemp -d)"
  export GITHUB_OUTPUT="${ROOT}/output"
  : > "$GITHUB_OUTPUT"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q -b main "${ROOT}/origin"
  cd "${ROOT}/origin"
  git config user.name t
  git config user.email t@example.com
  printf 'a\nb\nc\n' > app.txt
  printf 'doc\n' > README.md
  git add -A
  git commit -qm init
  git checkout -qb feature/x
  printf 'a\nhead\nc\n' > app.txt
  git commit -qam head
  git checkout -q main
  printf 'a\nbase\nc\n' > app.txt
  printf 'new\n' > other.txt
  git add -A
  git commit -qm base
  git clone -q "${ROOT}/origin" "${ROOT}/work"
  cd "${ROOT}/work"
  git config user.name t
  git config user.email t@example.com
  git checkout -q feature/x
  BEFORE="$(git rev-parse HEAD)"
  export BEFORE BASE=main REPO=o/r

  export CHECKS="${ROOT}/checks.json"
  echo '{"check_runs":[{"name":"ci / CI Gate","conclusion":"success"}]}' > "$CHECKS"
  mkdir -p "${ROOT}/bin"
  cat > "${ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = api ] || exit 1
jq -r "$4" "$CHECKS"
EOF
  chmod +x "${ROOT}/bin/gh"
  export GH_CMD="${ROOT}/bin/gh"
  SCRIPT="${BATS_TEST_DIRNAME}/check-conflict-resolution.sh"
}

teardown() {
  rm -rf "$ROOT"
}

# origin/main をマージし、app.txt を $1 で解消してコミットする。
resolve() {
  git merge -q origin/main >/dev/null 2>&1 || true
  printf "$1" > app.txt
  git add -A
  git commit -qm merge
  export HEAD_SHA="$(git rev-parse HEAD)"
}

@test "a merge that only resolves the conflicts skips CI" {
  resolve 'a\nhead\nbase\nc\n'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'only=true' "$GITHUB_OUTPUT"
}

@test "a merge that also changes a path that did not conflict runs CI" {
  git merge -q origin/main >/dev/null 2>&1 || true
  printf 'a\nhead\nbase\nc\n' > app.txt
  printf 'doc\nmore\n' > README.md
  git add -A
  git commit -qm merge
  HEAD_SHA="$(git rev-parse HEAD)" run bash "$SCRIPT"
  grep -qx 'only=false' "$GITHUB_OUTPUT"
  [[ "$output" == *"README.md"* ]]
}

@test "conflict markers left in a resolved path run CI" {
  git merge -q origin/main >/dev/null 2>&1 || true
  git add -A
  git commit -qm merge
  HEAD_SHA="$(git rev-parse HEAD)" run bash "$SCRIPT"
  grep -qx 'only=false' "$GITHUB_OUTPUT"
  [[ "$output" == *"markers"* ]]
}

@test "a clean merge of the base runs CI" {
  (cd "${ROOT}/origin" && git checkout -q main && git reset -q --hard HEAD~1 \
    && printf 'new\n' > other.txt && git add -A && git commit -qm base)
  git fetch -q -f origin main:refs/remotes/origin/main
  git merge -q --no-edit origin/main
  HEAD_SHA="$(git rev-parse HEAD)" run bash "$SCRIPT"
  grep -qx 'only=false' "$GITHUB_OUTPUT"
  [[ "$output" == *"merges cleanly"* ]]
}

@test "a commit on top of the resolution runs CI" {
  resolve 'a\nhead\nbase\nc\n'
  printf 'x\n' > extra.txt
  git add -A
  git commit -qm extra
  HEAD_SHA="$(git rev-parse HEAD)" run bash "$SCRIPT"
  grep -qx 'only=false' "$GITHUB_OUTPUT"
  [[ "$output" == *"two-parent"* ]]
}

@test "a merge whose first parent is not the previous head runs CI" {
  resolve 'a\nhead\nbase\nc\n'
  BEFORE="$(git rev-parse origin/main)" run bash "$SCRIPT"
  grep -qx 'only=false' "$GITHUB_OUTPUT"
  [[ "$output" == *"first parent"* ]]
}

@test "a merge of a branch that is not on the base runs CI" {
  git checkout -qb other main~1
  printf 'a\nother\nc\n' > app.txt
  git commit -qam other
  git checkout -q feature/x
  git merge -q other >/dev/null 2>&1 || true
  printf 'a\nhead\nother\nc\n' > app.txt
  git add -A
  git commit -qm merge
  HEAD_SHA="$(git rev-parse HEAD)" run bash "$SCRIPT"
  grep -qx 'only=false' "$GITHUB_OUTPUT"
  [[ "$output" == *"second parent"* ]]
}

@test "a previous head whose CI Gate failed runs CI" {
  resolve 'a\nhead\nbase\nc\n'
  echo '{"check_runs":[{"name":"ci / CI Gate","conclusion":"failure"}]}' > "$CHECKS"
  run bash "$SCRIPT"
  grep -qx 'only=false' "$GITHUB_OUTPUT"
  [[ "$output" == *"is failure"* ]]
}

@test "a previous head whose CI Gate is still running runs CI" {
  resolve 'a\nhead\nbase\nc\n'
  echo '{"check_runs":[{"name":"ci / CI Gate","conclusion":null}]}' > "$CHECKS"
  run bash "$SCRIPT"
  grep -qx 'only=false' "$GITHUB_OUTPUT"
  [[ "$output" == *"is pending"* ]]
}

@test "a previous head without CI Gate runs CI" {
  resolve 'a\nhead\nbase\nc\n'
  echo '{"check_runs":[{"name":"lint","conclusion":"success"}]}' > "$CHECKS"
  run bash "$SCRIPT"
  grep -qx 'only=false' "$GITHUB_OUTPUT"
  [[ "$output" == *"has no CI Gate"* ]]
}

@test "a failure to read the checks runs CI" {
  resolve 'a\nhead\nbase\nc\n'
  GH_CMD=false run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'only=false' "$GITHUB_OUTPUT"
}

@test "a push without a previous head runs CI" {
  resolve 'a\nhead\nbase\nc\n'
  BEFORE=0000000000000000000000000000000000000000 run bash "$SCRIPT"
  grep -qx 'only=false' "$GITHUB_OUTPUT"
}
