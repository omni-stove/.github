#!/usr/bin/env bats
# resolve-issue.sh の単体テスト。gh は固定の Issue JSON を返すスタブに差し替える。

setup() {
  ROOT="$(mktemp -d)"
  export GITHUB_OUTPUT="${ROOT}/output"
  : > "$GITHUB_OUTPUT"
  export GH_CMD="${ROOT}/gh"
  cat > "$GH_CMD" <<STUB
#!/usr/bin/env bash
cat "${ROOT}/issue.json"
STUB
  chmod +x "$GH_CMD"
  issue '["bug"]'
  export SCOPE_LABEL_PREFIX="App:" SCOPE_DIR="apps"
  SCRIPT="${BATS_TEST_DIRNAME}/resolve-issue.sh"
}

teardown() {
  rm -rf "$ROOT"
}

issue() {
  jq -n --argjson labels "$1" --arg state "${2:-OPEN}" --arg body "${3:-ボタンを押すと落ちる。}" \
    '{number: 12, title: "一覧画面が落ちる", body: $body, url: "https://github.com/o/r/issues/12", state: $state,
      labels: ($labels | map({name: .}))}' > "${ROOT}/issue.json"
}

out() {
  awk -v key="$1" '
    $0 ~ "^" key "<<" { d = substr($0, length(key) + 3); inb = 1; next }
    inb && $0 == d { exit }
    inb { print; next }
    index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }' "$GITHUB_OUTPUT"
}

@test "requires ISSUE_NUMBER and LABEL" {
  LABEL=bug run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  ISSUE_NUMBER=12 run bash "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "bug resolves to fix with the issue's title, body and url" {
  ISSUE_NUMBER=12 LABEL=bug run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out mode)" = fix ]
  [ "$(out number)" = 12 ]
  [ "$(out title)" = "一覧画面が落ちる" ]
  [ "$(out body)" = "ボタンを押すと落ちる。" ]
  [ "$(out url)" = "https://github.com/o/r/issues/12" ]
  [ "$(out branch)" = "agent-fix/issue-12" ]
  [ "$(out draft)" = false ]
  [ -z "$(out pr_labels)" ]
  [ -z "$(out scope_dir)" ]
  [[ "$(out task)" == *'Fix the bug in issue #12 "一覧画面が落ちる"'* ]]
  [[ "$(out task)" == *"ボタンを押すと落ちる。"* ]]
  [[ "$(out task)" != *"Scope edits"* ]]
}

@test "prototype resolves to a draft PR with the prototype label" {
  issue '["prototype"]'
  ISSUE_NUMBER=12 LABEL=prototype run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out mode)" = proto ]
  [ "$(out branch)" = "agent-proto/issue-12" ]
  [ "$(out draft)" = true ]
  [ "$(out pr_labels)" = prototype ]
  [[ "$(out task)" == *"Build a prototype"* ]]
}

@test "security resolves to security-fix with the security label" {
  issue '["security"]'
  ISSUE_NUMBER=12 LABEL=security run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out mode)" = security-fix ]
  [ "$(out branch)" = "agent-security-fix/issue-12" ]
  [ "$(out pr_labels)" = security ]
  [[ "$(out task)" == *"Fix only the vulnerabilities"* ]]
}

@test "implementation resolves to implement" {
  issue '["implementation"]'
  ISSUE_NUMBER=12 LABEL=implementation run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out mode)" = implement ]
  [ "$(out branch)" = "agent-implement/issue-12" ]
  [[ "$(out task)" == *"production quality"* ]]
}

@test "skips a label that starts no worker without reading the issue" {
  rm "$GH_CMD"
  ISSUE_NUMBER=12 LABEL=App:web run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(out mode)" ]
  [[ "$(out skip_reason)" == *"does not start a worker"* ]]
}

@test "skips a label added by a user outside ALLOWED_USERS without reading the issue" {
  rm "$GH_CMD"
  ISSUE_NUMBER=12 LABEL=bug SENDER=mallory ALLOWED_USERS="alice, bob" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(out mode)" ]
  [[ "$(out skip_reason)" == *"'mallory', who is not in allowed-users"* ]]
}

@test "skips when ALLOWED_USERS is set and the sender is unknown" {
  ISSUE_NUMBER=12 LABEL=bug ALLOWED_USERS=alice run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(out mode)" ]
}

@test "runs for a user in ALLOWED_USERS, ignoring case and spaces" {
  ISSUE_NUMBER=12 LABEL=bug SENDER=Bob ALLOWED_USERS="alice, bob" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out mode)" = fix ]
}

@test "runs for anyone when ALLOWED_USERS is empty" {
  ISSUE_NUMBER=12 LABEL=bug SENDER=mallory ALLOWED_USERS="" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out mode)" = fix ]
}

@test "skips a closed issue" {
  issue '["bug"]' CLOSED
  ISSUE_NUMBER=12 LABEL=bug run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(out mode)" ]
  [[ "$(out skip_reason)" == *"is CLOSED"* ]]
}

@test "skips implementation when the issue also carries prototype" {
  issue '["implementation","prototype"]'
  ISSUE_NUMBER=12 LABEL=implementation run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(out mode)" ]
  [[ "$(out skip_reason)" == *"prototype"* ]]
}

@test "takes the edit scope from the App: label and appends it to the task" {
  issue '["bug","App:web"]'
  ISSUE_NUMBER=12 LABEL=bug run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out scope_dir)" = "apps/web" ]
  [ "$(out scope_label)" = "App:web" ]
  [[ "$(out task)" == *'Scope edits to `apps/web`.'* ]]
}

@test "uses the label value alone as the scope when SCOPE_DIR is empty" {
  issue '["bug","App:packages/core"]'
  ISSUE_NUMBER=12 LABEL=bug SCOPE_DIR="" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out scope_dir)" = "packages/core" ]
}

@test "ignores scope labels when the prefix is empty" {
  issue '["bug","App:web"]'
  ISSUE_NUMBER=12 LABEL=bug SCOPE_LABEL_PREFIX="" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$(out scope_dir)" ]
  [ -z "$(out scope_label)" ]
}

@test "keeps a multi-line body intact in the output" {
  issue '["bug"]' OPEN $'1 行目\n\n3 行目 `code`'
  ISSUE_NUMBER=12 LABEL=bug run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(out body)" = $'1 行目\n\n3 行目 `code`' ]
  [[ "$(out task)" == *$'<issue_body>\n1 行目\n\n3 行目 `code`\n</issue_body>'* ]]
}
