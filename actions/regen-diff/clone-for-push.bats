#!/usr/bin/env bats
# clone-for-push.sh の単体テスト。ローカルの bare リポジトリを取り込み元にする。

setup() {
  ROOT="$(mktemp -d)"
  SCRIPT="${BATS_TEST_DIRNAME}/clone-for-push.sh"
  git init -q "${ROOT}/src"
  cd "${ROOT}/src"
  git config user.name test
  git config user.email test@example.com
  printf 'lock: 1\n' > pnpm-lock.yaml
  git add -A
  git commit -qm first
  FIRST="$(git rev-parse HEAD)"
  printf 'lock: 2\n' > pnpm-lock.yaml
  git commit -qam second
  git clone -q --bare "${ROOT}/src" "${ROOT}/remote.git"
  git -C "${ROOT}/remote.git" config uploadpack.allowFilter true
  git -C "${ROOT}/remote.git" config uploadpack.allowAnySHA1InWant true
  export REMOTE_URL="file://${ROOT}/remote.git"
  export PUSH_TOKEN=secret
  export DIR="${ROOT}/push"
}

teardown() {
  rm -rf "$ROOT"
}

@test "checks out the commit with its history and the token for github.com" {
  SHA="$FIRST" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(git -C "$DIR" rev-parse HEAD)" = "$FIRST" ]
  [ "$(cat "$DIR/pnpm-lock.yaml")" = 'lock: 1' ]
  [ -z "$(git -C "$DIR" status --porcelain)" ]
  git -C "$DIR" config --get http.https://github.com/.extraheader | grep -q '^AUTHORIZATION: basic '
}

@test "later fetches of a branch bring its history" {
  SHA="$FIRST" bash "$SCRIPT" >/dev/null
  git -C "$DIR" fetch -q origin HEAD
  git -C "$DIR" merge-base --is-ancestor "$FIRST" FETCH_HEAD
}
