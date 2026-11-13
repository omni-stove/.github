#!/usr/bin/env bats
# files.sh の単体テスト。git はエージェントの編集を、gh は PR の変更ファイルを返すスタブに差し替える。

setup() {
  ROOT="$(mktemp -d)"
  export GITHUB_OUTPUT="${ROOT}/output"
  : > "$GITHUB_OUTPUT"
  export RUNNER_TEMP="${ROOT}"
  export GIT_CMD="${ROOT}/git" GH_CMD="${ROOT}/gh"
  cat > "$GIT_CMD" <<STUB
#!/usr/bin/env bash
case "\$1" in
  diff) cat "${ROOT}/tracked" ;;
  ls-files) cat "${ROOT}/untracked" ;;
esac
STUB
  cat > "$GH_CMD" <<STUB
#!/usr/bin/env bash
echo "\$*" > "${ROOT}/gh-args"
cat "${ROOT}/pr-files"
STUB
  chmod +x "$GIT_CMD" "$GH_CMD"
  : > "${ROOT}/tracked"
  : > "${ROOT}/untracked"
  : > "${ROOT}/pr-files"
  SCRIPT="${BATS_TEST_DIRNAME}/files.sh"
}

teardown() {
  rm -rf "$ROOT"
}

@test "lists the agent's edits without a PR" {
  printf 'apps/web/src/a.ts\n' > "${ROOT}/tracked"
  printf 'apps/web/src/b.ts\n' > "${ROOT}/untracked"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx "path=${ROOT}/agent-regen-files.txt" "$GITHUB_OUTPUT"
  [ "$(cat "${ROOT}/agent-regen-files.txt")" = $'apps/web/src/a.ts\napps/web/src/b.ts' ]
  [ ! -e "${ROOT}/gh-args" ]
}

@test "adds the PR's changed files once each" {
  printf 'apps/web/src/a.ts\n' > "${ROOT}/tracked"
  printf 'apps/web/src/a.ts\napps/api/schema.prisma\n' > "${ROOT}/pr-files"
  PR=12 REPO=o/r run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "${ROOT}/agent-regen-files.txt")" = $'apps/web/src/a.ts\napps/api/schema.prisma' ]
  grep -q 'repos/o/r/pulls/12/files' "${ROOT}/gh-args"
}

@test "fails when the PR's files cannot be fetched" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$GH_CMD"
  PR=12 REPO=o/r run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}
