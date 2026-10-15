#!/usr/bin/env bats
SCRIPT="${BATS_TEST_DIRNAME}/install.sh"

setup() {
  DIR="$(mktemp -d)"
  mkdir -p "$DIR/bin" "$DIR/repo"
  export PATH="$DIR/bin:$PATH"
  export GH_LOG="$DIR/gh.log"
  : > "$GH_LOG"
  cat > "$DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in
  "auth status"*) exit "${GH_AUTH:-0}" ;;
  *"repo view --json nameWithOwner"*) [ -n "${GH_NO_REMOTE:-}" ] && exit 1; echo "omni-stove/demo" ;;
  *"repo view --json visibility"*) echo "${GH_VISIBILITY:-PRIVATE}" ;;
  *"repo view --json defaultBranchRef"*) echo "${GH_DEFAULT_BRANCH:-main}" ;;
  *"secret list --org"*) printf '%s\n' ${GH_ORG_SECRETS:-} ;;
  *"secret list"*) printf '%s\n' ${GH_REPO_SECRETS:-} ;;
  *"label create"*) exit "${GH_LABEL_STATUS:-0}" ;;
  *"--method POST"*|*"--method PUT"*) cat > "$GH_LOG.body"; exit "${GH_API_STATUS:-0}" ;;
  *"rulesets --jq"*) printf '%s\n' "${GH_RULESET_ID:-}" ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$DIR/bin/gh"
  cd "$DIR/repo"
  git init -q .
  printf '{"name":"demo","scripts":{"lint":"biome check .","test":"vitest run"}}\n' > package.json
  : > pnpm-lock.yaml
}

teardown() {
  rm -rf "$DIR"
}

@test "fails outside a git repository" {
  cd "$DIR"
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"git リポジトリの中で実行"* ]]
}

@test "unknown option prints usage and exits 2" {
  run bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option: --bogus"* ]]
  [[ "$output" == *"usage:"* ]]
}

@test "detects lint and test from package.json and skips the missing typecheck with a todo" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"created	.github/workflows/ci.yml"* ]]
  [[ "$output" == *"created	.github/workflows/hotfix-revert-approve.yml"* ]]
  [ ! -e .github/workflows/auto-merge.yml ]
  grep -qx "    uses: omni-stove/.github/.github/workflows/ci.yml@main" .github/workflows/ci.yml
  grep -qx "      node-version: \"24\"" .github/workflows/ci.yml
  grep -qx "      lint-command: 'pnpm lint'" .github/workflows/ci.yml
  grep -qx "      typecheck-command: 'echo \"skip: no typecheck script\"'" .github/workflows/ci.yml
  grep -qx "      test-command: 'pnpm test'" .github/workflows/ci.yml
  grep -qx "      run-test: true" .github/workflows/ci.yml
  grep -qx "      run-review: false" .github/workflows/ci.yml
  grep -qxF "    branches: [main]" .github/workflows/ci.yml
  ! grep -q "review-allowed-bots" .github/workflows/ci.yml
  [[ "$output" == *"todo	package.json に typecheck script が無い"* ]]
  [[ "$output" != *"lint script が無い"* ]]
  grep -qx "    uses: omni-stove/.github/.github/workflows/hotfix-revert-approve.yml@main" .github/workflows/hotfix-revert-approve.yml
}

@test "reads the node version from mise.toml" {
  printf '[tools]\npnpm = "10"\nnode = "22.11.0"\n' > mise.toml
  echo "v20" > .node-version
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx "      node-version: \"22\"" .github/workflows/ci.yml
}

@test "reads the node version from a mise table value" {
  printf '[tools]\nnode = { version = "23", postinstall = "corepack enable" }\n' > mise.toml
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx "      node-version: \"23\"" .github/workflows/ci.yml
}

@test "falls back to .node-version when mise.toml pins no node, and to 24 when nothing does" {
  printf '[tools]\npnpm = "10"\n' > mise.toml
  echo "v20.1.0" > .node-version
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx "      node-version: \"20\"" .github/workflows/ci.yml
  rm .node-version
  run bash "$SCRIPT" --force
  grep -qx "      node-version: \"24\"" .github/workflows/ci.yml
}

@test "sets run-test false without a test script and takes the default branch from gh" {
  printf '{"scripts":{"lint":"x","typecheck":"y"}}\n' > package.json
  GH_DEFAULT_BRANCH=develop run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx "      run-test: false" .github/workflows/ci.yml
  grep -qx "      typecheck-command: 'pnpm typecheck'" .github/workflows/ci.yml
  grep -qxF "    branches: [develop]" .github/workflows/ci.yml
  [[ "$output" == *"todo	package.json に test script が無い"* ]]
}

@test "reports missing package.json and pnpm-lock.yaml as todos" {
  rm package.json pnpm-lock.yaml
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"todo	package.json が無い"* ]]
  [[ "$output" == *"todo	pnpm-lock.yaml が無い"* ]]
}

@test "keeps files it did not generate unless --force" {
  mkdir -p .github/workflows
  echo mine > .github/workflows/ci.yml
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept	.github/workflows/ci.yml (install.sh が作ったものではない"* ]]
  [ "$(cat .github/workflows/ci.yml)" = "mine" ]
  run bash "$SCRIPT" --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"overwritten	.github/workflows/ci.yml"* ]]
  grep -q "uses: omni-stove" .github/workflows/ci.yml
}

@test "a second run reports generated workflows as unchanged" {
  bash "$SCRIPT" --ref v1 >/dev/null
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"update	.github/workflows/ci.yml の with: と参照 (@v1) を引き継ぐ"* ]]
  [[ "$output" == *"unchanged	.github/workflows/ci.yml"* ]]
  [[ "$output" == *"unchanged	.github/workflows/hotfix-revert-approve.yml"* ]]
  grep -qx "    uses: omni-stove/.github/.github/workflows/ci.yml@v1" .github/workflows/ci.yml
}

@test "updates a generated workflow to the current template, keeping edited with: values and extra keys" {
  bash "$SCRIPT" --ref v1 >/dev/null
  sed -i.bak \
    -e "s|lint-command: 'pnpm lint'|lint-command: 'pnpm lint:ci'|" \
    -e 's|node-version: "24"|node-version: "22"  # CI だけ古い|' \
    -e '/id-token: write/d' \
    -e 's|^    with:$|    with:\n      install-filter: "web"|' \
    .github/workflows/ci.yml
  rm .github/workflows/ci.yml.bak
  echo "x" > .node-version
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated	.github/workflows/ci.yml"* ]]
  grep -qx "      id-token: write" .github/workflows/ci.yml
  grep -qx "      lint-command: 'pnpm lint:ci'" .github/workflows/ci.yml
  grep -qx '      node-version: "22"  # CI だけ古い' .github/workflows/ci.yml
  grep -qx '      install-filter: "web"' .github/workflows/ci.yml
  grep -qx "    uses: omni-stove/.github/.github/workflows/ci.yml@v1" .github/workflows/ci.yml
  [[ "$output" == *"detect	default-branch=main node=22"* ]]
  ! grep -q '^$' <(sed -n '/with:/,/secrets: inherit/p' .github/workflows/ci.yml)
}

@test "options given on an update override the carried-over values" {
  bash "$SCRIPT" --ref v1 >/dev/null
  run bash "$SCRIPT" --review --provider codex --ref v2
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated	.github/workflows/ci.yml"* ]]
  [[ "$output" == *"updated	.github/workflows/hotfix-revert-approve.yml"* ]]
  grep -qx "      run-review: true" .github/workflows/ci.yml
  grep -qx "      review-provider: \"codex\"" .github/workflows/ci.yml
  grep -qx "    uses: omni-stove/.github/.github/workflows/ci.yml@v2" .github/workflows/ci.yml
  grep -qx "    uses: omni-stove/.github/.github/workflows/hotfix-revert-approve.yml@v2" .github/workflows/hotfix-revert-approve.yml
  [[ "$output" == *"todo	gh secret set OPENAI_API_KEY"* ]]
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unchanged	.github/workflows/ci.yml"* ]]
  grep -qx "      run-review: true" .github/workflows/ci.yml
  grep -qx "      review-provider: \"codex\"" .github/workflows/ci.yml
  [[ "$output" == *"todo	gh secret set OPENAI_API_KEY"* ]]
}

@test "an existing auto-merge.yml is updated without --auto-merge" {
  bash "$SCRIPT" --auto-merge >/dev/null
  run bash "$SCRIPT" --ref v2
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated	.github/workflows/auto-merge.yml"* ]]
  grep -qx "    uses: omni-stove/.github/.github/workflows/auto-merge.yml@v2" .github/workflows/auto-merge.yml
}

@test "re-detects the skip placeholders so an added script replaces them on update" {
  bash "$SCRIPT" >/dev/null
  grep -qx "      typecheck-command: 'echo \"skip: no typecheck script\"'" .github/workflows/ci.yml
  printf '{"scripts":{"lint":"x","typecheck":"y","test":"z"}}\n' > package.json
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated	.github/workflows/ci.yml"* ]]
  grep -qx "      typecheck-command: 'pnpm typecheck'" .github/workflows/ci.yml
  [[ "$output" != *"typecheck script が無い"* ]]
}

@test "run-test false is detected again once a test script exists" {
  printf '{"scripts":{"lint":"x","typecheck":"y"}}\n' > package.json
  bash "$SCRIPT" >/dev/null
  grep -qx "      run-test: false" .github/workflows/ci.yml
  printf '{"scripts":{"lint":"x","typecheck":"y","test":"z"}}\n' > package.json
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx "      run-test: true" .github/workflows/ci.yml
  [[ "$output" != *"test script が無い"* ]]
}

@test "--force drops the carried-over values and rewrites from detection" {
  bash "$SCRIPT" --review --ref v1 >/dev/null
  sed -i.bak "s|lint-command: 'pnpm lint'|lint-command: 'pnpm lint:ci'|" .github/workflows/ci.yml
  run bash "$SCRIPT" --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"overwritten	.github/workflows/ci.yml"* ]]
  [[ "$output" != *"update	"* ]]
  grep -qx "      lint-command: 'pnpm lint'" .github/workflows/ci.yml
  grep -qx "      run-review: false" .github/workflows/ci.yml
  grep -qx "    uses: omni-stove/.github/.github/workflows/ci.yml@main" .github/workflows/ci.yml
}

@test "applies --review --provider --ref --auto-merge and disallows bots on a public repo" {
  GH_VISIBILITY=PUBLIC run bash "$SCRIPT" --review --provider codex --ref v1 --auto-merge
  [ "$status" -eq 0 ]
  grep -qx "    uses: omni-stove/.github/.github/workflows/ci.yml@v1" .github/workflows/ci.yml
  grep -qx "      run-review: true" .github/workflows/ci.yml
  grep -qx "      review-provider: \"codex\"" .github/workflows/ci.yml
  grep -q '^      review-allowed-bots: ""' .github/workflows/ci.yml
  grep -qx "    secrets: inherit" .github/workflows/ci.yml
  ! grep -q '^$' <(sed -n '/review-provider/,/secrets: inherit/p' .github/workflows/ci.yml)
  [[ "$output" == *"created	.github/workflows/auto-merge.yml"* ]]
  grep -qx "    uses: omni-stove/.github/.github/workflows/auto-merge.yml@v1" .github/workflows/auto-merge.yml
  [[ "$output" == *"todo	gh secret set OPENAI_API_KEY"* ]]
  [[ "$output" == *"REVIEWER_GH_APP_ID / REVIEWER_GH_APP_PRIVATE_KEY を secrets に置く"* ]]
}

@test "rejects a provider other than claude or codex" {
  run bash "$SCRIPT" --provider gemini
  [ "$status" -eq 2 ]
  [[ "$output" == *"--provider は claude か codex"* ]]
}

@test "reports present secrets including organization secrets and emits no secret todo" {
  GH_REPO_SECRETS="REVIEWER_GH_APP_ID REVIEWER_GH_APP_PRIVATE_KEY" GH_ORG_SECRETS="CLAUDE_CODE_OAUTH_TOKEN" run bash "$SCRIPT" --review
  [ "$status" -eq 0 ]
  [[ "$output" == *"secret	CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY"* ]]
  [[ "$output" == *"secret	REVIEWER_GH_APP_ID / REVIEWER_GH_APP_PRIVATE_KEY"* ]]
  [[ "$output" != *"todo	gh secret set"* ]]
  grep -q "secret list --org omni-stove" "$GH_LOG"
}

@test "creates labels with gh and skips them with --no-labels" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"label	hotfix"* ]]
  [[ "$output" == *"label	revert"* ]]
  grep -q "label create hotfix --color b60205" "$GH_LOG"
  grep -q "label create revert --color 5319e7" "$GH_LOG"
  : > "$GH_LOG"
  run bash "$SCRIPT" --no-labels
  [ "$status" -eq 0 ]
  ! grep -q "label create" "$GH_LOG"
}

@test "without gh login writes workflows and turns labels, ruleset and secrets into todos" {
  GH_AUTH=1 run bash "$SCRIPT" --review --ruleset
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh	not available"* ]]
  [[ "$output" == *"created	.github/workflows/ci.yml"* ]]
  [[ "$output" == *"todo	gh auth login してから: gh label create hotfix"* ]]
  [[ "$output" == *"warning	--ruleset は gh が必要"* ]]
  [[ "$output" == *"todo	ruleset / branch protection の必須チェックに \"ci / CI Gate\""* ]]
  [[ "$output" == *"todo	secrets を置く: CLAUDE_CODE_OAUTH_TOKEN"* ]]
  ! grep -q "label create" "$GH_LOG"
}

@test "--ruleset creates the ruleset with POST when none exists" {
  run bash "$SCRIPT" --ruleset
  [ "$status" -eq 0 ]
  [[ "$output" == *"ruleset	created \"CI Gate\""* ]]
  [[ "$output" != *"todo	ruleset"* ]]
  grep -q "api repos/omni-stove/demo/rulesets --method POST --input -" "$GH_LOG"
  grep -q '"context": "ci / CI Gate"' "$GH_LOG.body"
  grep -q '"include": \["~DEFAULT_BRANCH"\]' "$GH_LOG.body"
}

@test "--ruleset updates an existing ruleset with PUT" {
  GH_RULESET_ID=42 run bash "$SCRIPT" --ruleset
  [ "$status" -eq 0 ]
  [[ "$output" == *"ruleset	updated \"CI Gate\" (#42)"* ]]
  grep -q "api repos/omni-stove/demo/rulesets/42 --method PUT --input -" "$GH_LOG"
}

@test "--ruleset degrades to a warning and todo when the API call fails" {
  GH_API_STATUS=1 run bash "$SCRIPT" --ruleset
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning	ruleset を作れなかった"* ]]
  [[ "$output" == *"todo	ruleset / branch protection"* ]]
}

@test "always ends with the required-check todo and never dictates a commit" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"todo	ruleset / branch protection の必須チェックに \"ci / CI Gate\" だけを登録する"* ]]
  [[ "$output" != *"git commit"* ]]
}

@test "--issue-worker writes issue-worker.yml with the provider and the pnpm regen command, creates its labels and asks for the agent App" {
  run bash "$SCRIPT" --issue-worker --provider codex --ref v1
  [ "$status" -eq 0 ]
  [[ "$output" == *"created	.github/workflows/issue-worker.yml"* ]]
  grep -qx "    uses: omni-stove/.github/.github/workflows/issue-worker.yml@v1" .github/workflows/issue-worker.yml
  grep -qxF "    types: [labeled]" .github/workflows/issue-worker.yml
  grep -qx "      provider: \"codex\"" .github/workflows/issue-worker.yml
  grep -qx "      regen-command: 'pnpm install --lockfile-only --no-frozen-lockfile'" .github/workflows/issue-worker.yml
  ! grep -q "allowed-bots" .github/workflows/issue-worker.yml
  grep -qx "    secrets: inherit" .github/workflows/issue-worker.yml
  ! grep -q '^$' <(sed -n '/with:/,/secrets: inherit/p' .github/workflows/issue-worker.yml)
  [[ "$output" == *"label	prototype"* ]]
  [[ "$output" == *"label	implementation"* ]]
  [[ "$output" == *"label	security"* ]]
  grep -q "label create prototype --color fbca04" "$GH_LOG"
  grep -q "label create implementation --color 0e8a16" "$GH_LOG"
  grep -q "label create security --color e11d21" "$GH_LOG"
  [[ "$output" == *"todo	gh secret set OPENAI_API_KEY"* ]]
  [[ "$output" == *"todo	PR を作る agent 用 GitHub App (reviewer とは別) の AGENT_GH_APP_ID / AGENT_GH_APP_PRIVATE_KEY"* ]]
  [[ "$output" != *"REVIEWER_GH_APP_ID"* ]]
}

@test "--issue-worker leaves regen-command out without pnpm-lock.yaml and disallows bots on a public repo" {
  rm pnpm-lock.yaml
  GH_VISIBILITY=PUBLIC run bash "$SCRIPT" --issue-worker
  [ "$status" -eq 0 ]
  ! grep -q "regen-command" .github/workflows/issue-worker.yml
  grep -q '^      allowed-bots: ""' .github/workflows/issue-worker.yml
  grep -qx "      provider: \"claude\"" .github/workflows/issue-worker.yml
}

@test "without --issue-worker no worker labels or secrets are touched" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -e .github/workflows/issue-worker.yml ]
  ! grep -q "label create prototype" "$GH_LOG"
  [[ "$output" != *"AGENT_GH_APP_ID"* ]]
}

@test "an existing issue-worker.yml is updated without --issue-worker, keeping edited with: values" {
  bash "$SCRIPT" --issue-worker >/dev/null
  sed -i.bak \
    -e "s|regen-command: 'pnpm install --lockfile-only --no-frozen-lockfile'|regen-command: 'pnpm install --lockfile-only --no-frozen-lockfile \&\& pnpm generate'|" \
    -e 's|^    with:$|    with:\n      instructions: "apps/web の規約に従う"|' \
    .github/workflows/issue-worker.yml
  rm .github/workflows/issue-worker.yml.bak
  GH_REPO_SECRETS="AGENT_GH_APP_ID AGENT_GH_APP_PRIVATE_KEY CLAUDE_CODE_OAUTH_TOKEN" run bash "$SCRIPT" --ref v2
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated	.github/workflows/issue-worker.yml"* ]]
  grep -qx "    uses: omni-stove/.github/.github/workflows/issue-worker.yml@v2" .github/workflows/issue-worker.yml
  grep -qx "      regen-command: 'pnpm install --lockfile-only --no-frozen-lockfile && pnpm generate'" .github/workflows/issue-worker.yml
  grep -qx '      instructions: "apps/web の規約に従う"' .github/workflows/issue-worker.yml
  [[ "$output" == *"secret	AGENT_GH_APP_ID / AGENT_GH_APP_PRIVATE_KEY"* ]]
  [[ "$output" != *"todo	PR を作る agent 用"* ]]
  run bash "$SCRIPT"
  [[ "$output" == *"unchanged	.github/workflows/issue-worker.yml"* ]]
}

@test "the provider carries over from issue-worker.yml when ci.yml has none" {
  bash "$SCRIPT" --issue-worker --provider codex >/dev/null
  rm .github/workflows/ci.yml
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx "      provider: \"codex\"" .github/workflows/issue-worker.yml
  grep -qx "      review-provider: \"codex\"" .github/workflows/ci.yml
}

@test "without gh login --issue-worker turns its labels and secrets into todos" {
  GH_AUTH=1 run bash "$SCRIPT" --issue-worker
  [ "$status" -eq 0 ]
  [[ "$output" == *"created	.github/workflows/issue-worker.yml"* ]]
  [[ "$output" == *"todo	gh auth login してから: gh label create prototype"* ]]
  [[ "$output" == *"todo	secrets を置く: CLAUDE_CODE_OAUTH_TOKEN (または ANTHROPIC_API_KEY / OPENAI_API_KEY), AGENT_GH_APP_ID"* ]]
}

@test "--fix turns on run-fix with actions read, the pnpm regen command, its labels and the agent App" {
  run bash "$SCRIPT" --fix --provider codex
  [ "$status" -eq 0 ]
  grep -qx "      run-fix: true" .github/workflows/ci.yml
  grep -qx "      fix-provider: \"codex\"" .github/workflows/ci.yml
  grep -qx "      regen-command: 'pnpm install --lockfile-only --no-frozen-lockfile'" .github/workflows/ci.yml
  grep -qx "      actions: read" .github/workflows/ci.yml
  grep -q "label create skip-autofix" "$GH_LOG"
  grep -q "label create force-autofix" "$GH_LOG"
  [[ "$output" == *"AGENT_GH_APP_ID"* ]]
  [[ "$output" == *"OPENAI_API_KEY"* ]]
}

@test "run-fix carries over on an update and stays off without --fix" {
  bash "$SCRIPT" >/dev/null
  ! grep -q "run-fix" .github/workflows/ci.yml
  ! grep -q "actions: read" .github/workflows/ci.yml
  ! grep -q "label create skip-autofix" "$GH_LOG"
  bash "$SCRIPT" --fix >/dev/null
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx "      run-fix: true" .github/workflows/ci.yml
  grep -qx "      actions: read" .github/workflows/ci.yml
}
