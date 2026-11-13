#!/usr/bin/env bats
# base-merge.sh の単体テスト。マージの結果を見るため、git はスタブにせず一時リポジトリで走らせる。

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
  git clone -q "${ROOT}/origin" "${ROOT}/work"
  cd "${ROOT}/work"
  git checkout -q feature/x
  export BASE=main REF=feature/x
  SCRIPT="${BATS_TEST_DIRNAME}/base-merge.sh"
}

teardown() {
  rm -rf "$ROOT"
}

# origin の main に commit し、作業リポジトリに取り込む。
base_commit() {
  (cd "${ROOT}/origin" && git checkout -q main && printf "$2" > "$1" && git add -A && git commit -qm base)
  git fetch -q origin
}

output_value() {
  sed -n "s/^$1=//p" "$GITHUB_OUTPUT"
}

@test "start leaves nothing behind when the base merges cleanly" {
  base_commit other.txt 'x\n'
  head="$(git rev-parse HEAD)"
  MODE=start run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'result=clean' "$GITHUB_OUTPUT"
  [ "$(git rev-parse HEAD)" = "$head" ]
  [ -z "$(git status --porcelain)" ]
  ! git rev-parse -q --verify MERGE_HEAD
}

@test "start leaves conflict markers without a merge in progress" {
  base_commit app.txt 'a\nbase\nc\n'
  MODE=start run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'result=conflicted' "$GITHUB_OUTPUT"
  grep -qx 'app.txt' "$GITHUB_OUTPUT"
  [ "$(output_value base-sha)" = "$(git rev-parse origin/main)" ]
  grep -q '^<<<<<<< ' app.txt
  ! git rev-parse -q --verify MERGE_HEAD
}

@test "start does not resolve a conflict in a path claude-code-action overwrites" {
  (cd "${ROOT}/origin" && git checkout -q feature/x && printf 'head\n' > CLAUDE.md && git add -A && git commit -qm h)
  git pull -q origin feature/x
  base_commit CLAUDE.md 'base\n'
  MODE=start run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'result=unresolvable' "$GITHUB_OUTPUT"
  ! git rev-parse -q --verify MERGE_HEAD
  [ -z "$(git status --porcelain)" ]
}

@test "start fails soft when the base is not fetched" {
  BASE=nope MODE=start run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'result=failed' "$GITHUB_OUTPUT"
}

start_conflict() {
  base_commit app.txt 'a\nbase\nc\n'
  MODE=start bash "$SCRIPT" >/dev/null
  export BASE_SHA TREE FILES
  BASE_SHA="$(output_value base-sha)"
  TREE="$(output_value tree)"
  FILES=app.txt
  head="$(git rev-parse HEAD)"
  : > "$GITHUB_OUTPUT"
}

@test "finish commits the resolution as a merge of the head and the base" {
  start_conflict
  printf 'a\nhead+base\nc\n' > app.txt
  MODE=finish run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'result=resolved' "$GITHUB_OUTPUT"
  [ "$(output_value merge-sha)" = "$(git rev-parse HEAD)" ]
  [ "$(git rev-parse HEAD^1)" = "$head" ]
  [ "$(git rev-parse HEAD^2)" = "$BASE_SHA" ]
  [ "$(git log -1 --pretty=%s)" = "Merge main into feature/x" ]
  [ "$(git show HEAD:app.txt)" = "$(printf 'a\nhead+base\nc')" ]
  [ -z "$(git status --porcelain)" ]
}

@test "finish drops edits outside the conflicted files" {
  start_conflict
  printf 'a\nhead+base\nc\n' > app.txt
  printf 'edited\n' > README.md
  printf 'new\n' > stray.txt
  MODE=finish run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'result=resolved' "$GITHUB_OUTPUT"
  [ "$(git show HEAD:README.md)" = doc ]
  ! git cat-file -e HEAD:stray.txt
  [ ! -e stray.txt ]
}

@test "finish refuses when conflict markers remain" {
  start_conflict
  MODE=finish run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'result=unresolved' "$GITHUB_OUTPUT"
  [ "$(git rev-parse HEAD)" = "$head" ]
}

@test "finish accepts deleting a conflicted file" {
  start_conflict
  rm app.txt
  MODE=finish run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'result=resolved' "$GITHUB_OUTPUT"
  ! git cat-file -e HEAD:app.txt
}
