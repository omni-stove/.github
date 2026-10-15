#!/usr/bin/env bats
# create-pr.sh のテスト。bare リポジトリを origin にした実 git で commit / push / マージを検証し、
# gh だけ呼び出しを記録するスタブに差し替える。

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(mktemp -d)"
  SCRIPT="${BATS_TEST_DIRNAME}/create-pr.sh"
  export GH_LOG="${ROOT}/gh.log"
  : > "$GH_LOG"
  mkdir -p "${ROOT}/bin"
  cat > "${ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in
  "pr list"*) printf '%s\n' "${GH_OPEN_PR_URL:-}" ;;
  "pr create"*) echo "https://github.com/o/r/pull/5" ;;
  "pr edit"*) exit "${GH_EDIT_STATUS:-0}" ;;
esac
STUB
  chmod +x "${ROOT}/bin/gh"
  export PATH="${ROOT}/bin:${PATH}"
  export GIT_CONFIG_GLOBAL="${ROOT}/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1

  git init -q --bare -b main "${ROOT}/origin.git"
  git clone -q "${ROOT}/origin.git" "${ROOT}/seed" 2>/dev/null
  (cd "${ROOT}/seed" && git -c user.name=seed -c user.email=seed@example.com commit -q --allow-empty -m init && git push -q origin HEAD:main)
  git clone -q "${ROOT}/origin.git" "${ROOT}/work"
  cd "${ROOT}/work"
}

teardown() {
  rm -rf "$ROOT"
}

@test "needs five arguments and rejects unknown options" {
  run bash "$SCRIPT" b main m t
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" b main m t body --bogus
  [ "$status" -eq 2 ]
}

@test "commits the working tree on a new branch, pushes it and opens the PR" {
  echo change > file.txt
  run --separate-stderr bash "$SCRIPT" agent-fix/issue-1 main "fix: it" "Title" "Body"
  [ "$status" -eq 0 ]
  [ "${output##*$'\n'}" = "https://github.com/o/r/pull/5" ]
  [ "$(git branch --show-current)" = "agent-fix/issue-1" ]
  [ "$(git log -1 --format=%s)" = "fix: it" ]
  [ "$(git log -1 --format='%an <%ae>')" = "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>" ]
  [ "$(git -C "${ROOT}/origin.git" log -1 --format=%s agent-fix/issue-1)" = "fix: it" ]
  grep -q "pr create --base main --head agent-fix/issue-1 --title Title --body Body" "$GH_LOG"
  ! grep -q -- "--draft" "$GH_LOG"
}

@test "uses GIT_USER_NAME / GIT_USER_EMAIL and keeps an existing identity" {
  echo change > file.txt
  GIT_USER_NAME="my-app[bot]" GIT_USER_EMAIL="my-app[bot]@users.noreply.github.com" run bash "$SCRIPT" b main m t body
  [ "$status" -eq 0 ]
  [ "$(git log -1 --format='%an <%ae>')" = "my-app[bot] <my-app[bot]@users.noreply.github.com>" ]
  git config user.name local
  git config user.email local@example.com
  echo more > file.txt
  GIT_USER_NAME=other run bash "$SCRIPT" b main m2 t body
  [ "$status" -eq 0 ]
  [ "$(git log -1 --format=%an)" = local ]
}

@test "passes --draft and adds labels one by one after creating the PR" {
  echo change > file.txt
  run bash "$SCRIPT" b main m t body --label prototype --draft --label App:web
  [ "$status" -eq 0 ]
  grep -q "pr create --base main --head b --title t --body body --draft" "$GH_LOG"
  grep -q "pr edit https://github.com/o/r/pull/5 --add-label prototype" "$GH_LOG"
  grep -q "pr edit https://github.com/o/r/pull/5 --add-label App:web" "$GH_LOG"
}

@test "a missing label only warns" {
  echo change > file.txt
  GH_EDIT_STATUS=1 run --separate-stderr bash "$SCRIPT" b main m t body --label nope
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"::warning::label 'nope' could not be added"* ]]
  [ "${output##*$'\n'}" = "https://github.com/o/r/pull/5" ]
}

@test "pushes onto an existing open PR instead of creating another" {
  echo change > file.txt
  GH_OPEN_PR_URL="https://github.com/o/r/pull/3" run --separate-stderr bash "$SCRIPT" b main m t body --label x
  [ "$status" -eq 0 ]
  [ "${output##*$'\n'}" = "https://github.com/o/r/pull/3" ]
  ! grep -q "pr create" "$GH_LOG"
  grep -q "pr edit https://github.com/o/r/pull/3 --add-label x" "$GH_LOG"
}

@test "merges a remote branch that is ahead before pushing again" {
  (cd "${ROOT}/seed" && git checkout -q -b b && echo earlier > other.txt && git add -A \
    && git -c user.name=seed -c user.email=seed@example.com commit -q -m earlier && git push -q origin b)
  echo change > file.txt
  run bash "$SCRIPT" b main "later" t body
  [ "$status" -eq 0 ]
  [[ "$output" == *"push rejected (remote ahead)"* ]]
  [ -f other.txt ]
  git -C "${ROOT}/origin.git" log --format=%s b | grep -qx later
  git -C "${ROOT}/origin.git" log --format=%s b | grep -qx earlier
}

@test "exits 3 on a merge conflict with the remote branch" {
  (cd "${ROOT}/seed" && git checkout -q -b b && echo theirs > file.txt && git add -A \
    && git -c user.name=seed -c user.email=seed@example.com commit -q -m theirs && git push -q origin b)
  echo mine > file.txt
  run bash "$SCRIPT" b main mine t body
  [ "$status" -eq 3 ]
  [[ "$output" == *"merge conflict"* ]]
  ! grep -q "pr create" "$GH_LOG"
}

@test "fails on a push rejected for another reason" {
  echo change > file.txt
  git remote set-url origin "${ROOT}/nowhere.git"
  run bash "$SCRIPT" b main m t body
  [ "$status" -eq 1 ]
  ! grep -q "pr create" "$GH_LOG"
}
