#!/usr/bin/env bats
# rate-limit-snapshot.sh のテスト。gh は差し替える。
SCRIPT="${BATS_TEST_DIRNAME}/rate-limit-snapshot.sh"

setup() {
  DIR="$(mktemp -d)"
  export GITHUB_OUTPUT="$DIR/github-output"
  export GITHUB_STEP_SUMMARY="$DIR/summary"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
}

teardown() {
  rm -rf "$DIR"
}

stub_rate_limit() {
  printf '#!/usr/bin/env bash\necho %q\n' "$1" > "$DIR/gh"
  chmod +x "$DIR/gh"
  export GH_CMD="$DIR/gh"
}

# before は残量を snapshot に出す
@test "before writes the remaining counts to snapshot" {
  stub_rate_limit "4000 1500 3000 1600"
  PHASE=before run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'snapshot=4000 1500 3000 1600' "$GITHUB_OUTPUT"
  [ ! -s "$GITHUB_STEP_SUMMARY" ]
}

# after は同じリセット窓なら消費量を summary に出す
@test "after reports usage to the summary within the same reset window" {
  stub_rate_limit "3900 1500 2950 1600"
  PHASE=after BEFORE="4000 1500 3000 1600" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"core 100 / graphql 50"* ]]
  grep -q '| core | 100 | 3900 |' "$GITHUB_STEP_SUMMARY"
  grep -q '| graphql | 50 | 2950 |' "$GITHUB_STEP_SUMMARY"
}

# after はリセットをまたいだ bucket の消費量を出さない
@test "after does not report usage for a bucket that was reset" {
  stub_rate_limit "4900 5100 2950 1600"
  PHASE=after BEFORE="4000 1500 3000 1600" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '| core | n/a (reset) | 4900 |' "$GITHUB_STEP_SUMMARY"
}

# 残量を取得できなくても失敗しない
@test "does not fail when the rate limit cannot be fetched" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$DIR/gh"
  chmod +x "$DIR/gh"
  export GH_CMD="$DIR/gh"
  PHASE=after BEFORE="4000 1500 3000 1600" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'snapshot=' "$GITHUB_OUTPUT"
}
