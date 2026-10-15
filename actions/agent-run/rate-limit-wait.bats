#!/usr/bin/env bats
# rate-limit-wait.sh のテスト。gh / sleep / 現在時刻は差し替える。
SCRIPT="${BATS_TEST_DIRNAME}/rate-limit-wait.sh"

setup() {
  DIR="$(mktemp -d)"
  export GITHUB_OUTPUT="$DIR/github-output"
  : > "$GITHUB_OUTPUT"
  export SLEPT_FILE="$DIR/slept"
  printf '#!/usr/bin/env bash\necho "$1" > "%s"\n' "$SLEPT_FILE" > "$DIR/sleep"
  chmod +x "$DIR/sleep"
  export SLEEP_CMD="$DIR/sleep"
  export NOW_CMD="echo 1000"
  export MAX_WAIT_SECONDS=900
}

teardown() {
  rm -rf "$DIR"
}

# $1=gh api rate_limit --jq が返す 1 行
stub_rate_limit() {
  printf '#!/usr/bin/env bash\necho %q\n' "$1" > "$DIR/gh"
  chmod +x "$DIR/gh"
  export GH_CMD="$DIR/gh"
}

# 残量があればレート制限ではないとして再実行しない
@test "does not retry when the rate limit is not exhausted" {
  stub_rate_limit "4000 1500 3000 1500"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'rate_limited=false' "$GITHUB_OUTPUT"
  grep -qx 'retry=false' "$GITHUB_OUTPUT"
  [ ! -f "$SLEPT_FILE" ]
}

# core が枯渇し上限内に解除されるなら解除まで待って再実行する
@test "waits for the core reset and retries when it comes within the limit" {
  stub_rate_limit "0 1300 3000 1500"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'rate_limited=true' "$GITHUB_OUTPUT"
  grep -qx 'retry=true' "$GITHUB_OUTPUT"
  grep -qx 'reset=1300' "$GITHUB_OUTPUT"
  [ "$(cat "$SLEPT_FILE")" = "310" ]
}

# core と graphql が両方枯渇していれば遅い方の解除まで待つ
@test "waits for the later reset when both core and graphql are exhausted" {
  stub_rate_limit "0 1300 5 1600"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'reset=1600' "$GITHUB_OUTPUT"
  [ "$(cat "$SLEPT_FILE")" = "610" ]
}

# 解除が上限より先なら待たずに再実行しない
@test "does not wait or retry when the reset is beyond the limit" {
  stub_rate_limit "0 5000 3000 1500"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'rate_limited=true' "$GITHUB_OUTPUT"
  grep -qx 'retry=false' "$GITHUB_OUTPUT"
  grep -qx 'reset=5000' "$GITHUB_OUTPUT"
  [ ! -f "$SLEPT_FILE" ]
}

# 残量を取得できなければ判定せず再実行しない
@test "does not retry when the rate limit cannot be fetched" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$DIR/gh"
  chmod +x "$DIR/gh"
  export GH_CMD="$DIR/gh"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'rate_limited=false' "$GITHUB_OUTPUT"
  grep -qx 'retry=false' "$GITHUB_OUTPUT"
}

# 待ち時間の上限が 0 なら再実行しない
@test "does not retry when retry is disabled" {
  stub_rate_limit "0 900 3000 1500"
  MAX_WAIT_SECONDS=0 run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'rate_limited=true' "$GITHUB_OUTPUT"
  grep -qx 'retry=false' "$GITHUB_OUTPUT"
  [ ! -f "$SLEPT_FILE" ]
}
