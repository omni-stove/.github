#!/usr/bin/env bats
# push-agent-fix.sh の単体テスト。git は呼び出しを記録し、状態ファイルで結果を切り替えるスタブに差し替える。

setup() {
  ROOT="$(mktemp -d)"
  export GITHUB_OUTPUT="${ROOT}/output"
  : > "$GITHUB_OUTPUT"
  CALLS="${ROOT}/git-calls"
  : > "$CALLS"
  mkdir -p "${ROOT}/gitdir/hooks"
  : > "${ROOT}/gitdir/hooks/pre-push"
  # staged=1 なら差分あり。rebase-fail / push-fail-N はその操作を失敗させる。
  echo 1 > "${ROOT}/staged"
  export GIT_CMD="${ROOT}/git"
  cat > "$GIT_CMD" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${CALLS}"
case "\$1" in
  diff) [ "\$(cat "${ROOT}/staged")" = "0" ] ;;
  rev-parse) echo "${ROOT}/gitdir" ;;
  rebase) [ "\$2" = "--abort" ] || [ ! -f "${ROOT}/rebase-fail" ] ;;
  push)
    n=\$(grep -c '^push' "${CALLS}")
    [ ! -f "${ROOT}/push-fail-\${n}" ]
    ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$GIT_CMD"
  export GH_CMD="${ROOT}/gh"
  cat > "$GH_CMD" <<STUB
#!/usr/bin/env bash
cat "${ROOT}/labels" 2>/dev/null
STUB
  chmod +x "$GH_CMD"
  export REF=feature/x
  SCRIPT="${BATS_TEST_DIRNAME}/push-agent-fix.sh"
}

teardown() {
  rm -rf "$ROOT"
}

@test "commits with the summary's first line and pushes" {
  STRUCTURED='{"summary":"型エラーを直した\n詳細"}' run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'result=pushed' "$GITHUB_OUTPUT"
  grep -qxF 'commit --no-verify -m [agent-fix] 型エラーを直した' "$CALLS"
  grep -qxF 'rebase origin/feature/x' "$CALLS"
  grep -qxF 'push origin HEAD:feature/x' "$CALLS"
}

@test "falls back to a default subject without a summary" {
  STRUCTURED='broken' run bash "$SCRIPT"
  grep -qxF 'commit --no-verify -m [agent-fix] address CI failures and review comments' "$CALLS"
}

@test "noop when nothing is staged" {
  echo 0 > "${ROOT}/staged"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'result=noop' "$GITHUB_OUTPUT"
  ! grep -q '^commit' "$CALLS"
}

@test "skipped without committing when a bypass label is on the PR" {
  printf 'bug\nHotfix\n' > "${ROOT}/labels"
  PR=1 REPO=o/r run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'result=skipped' "$GITHUB_OUTPUT"
  ! grep -q '^add' "$CALLS"
}

@test "conflict aborts the rebase and does not push" {
  : > "${ROOT}/rebase-fail"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'result=conflict' "$GITHUB_OUTPUT"
  grep -qx 'rebase --abort' "$CALLS"
  ! grep -q '^push' "$CALLS"
}

@test "retries after a rejected push" {
  : > "${ROOT}/push-fail-1"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx 'result=pushed' "$GITHUB_OUTPUT"
  [ "$(grep -c '^fetch' "$CALLS")" -eq 2 ]
}

@test "fails after the retry limit" {
  for n in 1 2 3; do : > "${ROOT}/push-fail-${n}"; done
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  grep -qx 'result=failed' "$GITHUB_OUTPUT"
}

@test "restores the token as an extraheader after disabling hooks" {
  PUSH_TOKEN=tok run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -e "${ROOT}/gitdir/hooks/pre-push" ]
  grep -qx 'config --local core.hooksPath /dev/null' "$CALLS"
  expected="$(printf 'x-access-token:tok' | base64)"
  grep -qxF "config --local http.https://github.com/.extraheader AUTHORIZATION: basic ${expected}" "$CALLS"
  [ "$(grep -n 'extraheader' "$CALLS" | cut -d: -f1)" -lt "$(grep -n '^push' "$CALLS" | cut -d: -f1)" ]
}
