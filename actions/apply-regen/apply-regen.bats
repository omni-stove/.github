#!/usr/bin/env bats
# apply-regen.sh の単体テスト。一時リポジトリで本物の git を使う。

setup() {
  ROOT="$(mktemp -d)"
  export GITHUB_OUTPUT="${ROOT}/output"
  : > "$GITHUB_OUTPUT"
  export PATCH_DIR="${ROOT}/patches"
  export COMMIT_PREFIX='[regen]'
  SCRIPT="${BATS_TEST_DIRNAME}/apply-regen.sh"
  mkdir -p "${ROOT}/repo" "$PATCH_DIR/regen-lint" "$PATCH_DIR/regen-unity" "$PATCH_DIR/regen-test"
  cd "${ROOT}/repo"
  git init -q .
  git config user.name test
  git config user.email test@example.com
  printf 'lock: 1\n' > pnpm-lock.yaml
  git add -A
  git commit -qm 'feat: something'
  export HEAD_SHA="$(git rev-parse HEAD)"
  # lint は lockfile を、unity は .meta を足し、test は差分なし (空の patch)。
  printf 'lock: 2\n' > pnpm-lock.yaml
  git diff --binary > "$PATCH_DIR/regen-lint/regen.patch"
  git checkout -q -- pnpm-lock.yaml
  printf 'guid: b\n' > a.png.meta
  git add -N a.png.meta
  git diff --binary > "$PATCH_DIR/regen-unity/regen.patch"
  git rm -q --cached a.png.meta
  rm a.png.meta
  : > "$PATCH_DIR/regen-test/regen.patch"
}

teardown() {
  rm -rf "$ROOT"
}

@test "applies every non-empty patch" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'result=applied' "$GITHUB_OUTPUT"
  [ "$(cat pnpm-lock.yaml)" = 'lock: 2' ]
  [ "$(cat a.png.meta)" = 'guid: b' ]
  [[ "$output" != *"regen-test"* ]]
}

@test "stops with loop when the head is already a regeneration commit" {
  git commit -q --allow-empty -m '[regen] lockfile / 生成物を作り直す'
  HEAD_SHA="$(git rev-parse HEAD)" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'result=loop' "$GITHUB_OUTPUT"
  [ "$(cat pnpm-lock.yaml)" = 'lock: 1' ]
}

@test "stops with conflict when a patch does not apply" {
  cp "$PATCH_DIR/regen-lint/regen.patch" "$PATCH_DIR/regen-test/regen.patch"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'result=conflict' "$GITHUB_OUTPUT"
  [[ "$output" == *"regen-test/regen.patch does not apply"* ]]
}
