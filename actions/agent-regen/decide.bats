#!/usr/bin/env bats
# decide.sh の単体テスト。git は変更ファイル一覧を返すスタブに差し替える。

setup() {
  ROOT="$(mktemp -d)"
  export GITHUB_OUTPUT="${ROOT}/output"
  : > "$GITHUB_OUTPUT"
  export GIT_CMD="${ROOT}/git"
  cat > "$GIT_CMD" <<STUB
#!/usr/bin/env bash
case "\$1" in
  diff) cat "${ROOT}/tracked" ;;
  ls-files) cat "${ROOT}/untracked" ;;
esac
STUB
  chmod +x "$GIT_CMD"
  : > "${ROOT}/tracked"
  : > "${ROOT}/untracked"
  SCRIPT="${BATS_TEST_DIRNAME}/decide.sh"
}

teardown() {
  rm -rf "$ROOT"
}

@test "false when nothing relevant changed" {
  printf 'src/a.ts\n' > "${ROOT}/tracked"
  STRUCTURED='{"needs_regen":false}' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'needs_regen=false' "$GITHUB_OUTPUT"
}

@test "true when the agent reports needs_regen" {
  STRUCTURED='{"needs_regen":true}' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'needs_regen=true' "$GITHUB_OUTPUT"
  [[ "$output" == *"agent reported needs_regen."* ]]
}

@test "true when a package.json changed even without the report" {
  printf 'apps/web/package.json\n' > "${ROOT}/tracked"
  STRUCTURED='{}' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'needs_regen=true' "$GITHUB_OUTPUT"
  [[ "$output" == *"lockfile input changed: apps/web/package.json"* ]]
}

@test "true when an untracked pnpm-workspace.yaml appeared" {
  printf 'pnpm-workspace.yaml\n' > "${ROOT}/untracked"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'needs_regen=true' "$GITHUB_OUTPUT"
}

@test "false on empty or invalid structured output with no relevant change" {
  STRUCTURED='not json' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'needs_regen=false' "$GITHUB_OUTPUT"
}

@test "true when the CI failure log shows an outdated lockfile" {
  CI_FAILURE='ERR_PNPM_OUTDATED_LOCKFILE  Cannot install with "frozen-lockfile"' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'needs_regen=true' "$GITHUB_OUTPUT"
}
