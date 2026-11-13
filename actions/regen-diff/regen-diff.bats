#!/usr/bin/env bats
# regen-diff.sh の単体テスト。一時リポジトリで本物の git を使い、出した patch が元のコミットに当たるかまで確かめる。

setup() {
  ROOT="$(mktemp -d)"
  export GITHUB_OUTPUT="${ROOT}/output"
  : > "$GITHUB_OUTPUT"
  export OUT="${ROOT}/out/regen.patch"
  SCRIPT="${BATS_TEST_DIRNAME}/regen-diff.sh"
  mkdir -p "${ROOT}/repo/Assets" "${ROOT}/repo/src"
  cd "${ROOT}/repo"
  git init -q .
  git config user.name test
  git config user.email test@example.com
  printf 'lock: 1\n' > pnpm-lock.yaml
  printf 'guid: a\n' > Assets/old.png.meta
  printf 'code\n' > src/a.ts
  printf 'ignored/\n' > .gitignore
  git add -A
  git commit -qm init
}

teardown() {
  rm -rf "$ROOT"
}

@test "writes an empty patch when nothing in the pathspec changed" {
  printf 'edited\n' > src/a.ts
  PATHSPEC='pnpm-lock.yaml' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
  [ ! -s "$OUT" ]
  grep -qx 'changed=false' "$GITHUB_OUTPUT"
}

@test "captures modified, new and deleted files only inside the pathspec, and the patch applies to HEAD" {
  printf 'lock: 2\n' > pnpm-lock.yaml
  printf 'guid: b\n' > Assets/new.png.meta
  rm Assets/old.png.meta
  printf 'edited\n' > src/a.ts
  PATHSPEC=$'pnpm-lock.yaml\n\n  *.meta  \n' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'changed=true' "$GITHUB_OUTPUT"
  grep -q 'Assets/new.png.meta' "$OUT"
  grep -q 'Assets/old.png.meta' "$OUT"
  grep -q 'pnpm-lock.yaml' "$OUT"
  ! grep -q 'src/a.ts' "$OUT"
  git stash -qu
  git apply --binary "$OUT"
  [ "$(cat pnpm-lock.yaml)" = 'lock: 2' ]
  [ "$(cat Assets/new.png.meta)" = 'guid: b' ]
  [ ! -e Assets/old.png.meta ]
  [ "$(cat src/a.ts)" = 'code' ]
}

@test "leaves the job's index untouched" {
  printf 'guid: b\n' > Assets/new.png.meta
  PATHSPEC='*.meta' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(git diff --cached --name-only)" ]
  [ "$(git status --porcelain -- Assets/new.png.meta)" = '?? Assets/new.png.meta' ]
}

@test "skips gitignored files and a pathspec that matches nothing" {
  mkdir -p ignored
  printf 'x\n' > ignored/b.meta
  PATHSPEC=$'*.meta\nprisma/generated' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -s "$OUT" ]
  grep -qx 'changed=false' "$GITHUB_OUTPUT"
}

@test "fails on an empty pathspec" {
  PATHSPEC=$'\n  \n' run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"pathspec が空"* ]]
}
