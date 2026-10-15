#!/usr/bin/env bats
SCRIPT="${BATS_TEST_DIRNAME}/skill.sh"

setup() {
  DIR="$(mktemp -d)"
  mkdir -p "$DIR/bin" "$DIR/repo" "$DIR/src/omni-stove-.github-abc/.github"
  cp "$BATS_TEST_DIRNAME/README.md" "$DIR/src/omni-stove-.github-abc/"
  cp -R "$BATS_TEST_DIRNAME/actions" "$DIR/src/omni-stove-.github-abc/actions"
  cp -R "$BATS_TEST_DIRNAME/.github/workflows" "$DIR/src/omni-stove-.github-abc/.github/workflows"
  export PATH="$DIR/bin:$PATH"
  export TMPDIR="$DIR"
  export GH_LOG="$DIR/gh.log" TARBALL_SRC="$DIR/src"
  : > "$GH_LOG"
  cat > "$DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in
  "auth status"*) exit "${GH_AUTH:-0}" ;;
  *"repo view --json nameWithOwner"*) [ -n "${GH_NO_REMOTE:-}" ] && exit 1; echo "omni-stove/demo" ;;
  *"repo view --json visibility"*) echo "${GH_VISIBILITY:-PRIVATE}" ;;
  *"repo view --json defaultBranchRef"*) echo "${GH_DEFAULT_BRANCH:-main}" ;;
  *"label list"*) printf '%s\n' ${GH_LABELS:-} ;;
  *"secret list --org"*) printf '%s\n' ${GH_ORG_SECRETS:-} ;;
  *"secret list"*) printf '%s\n' ${GH_REPO_SECRETS:-} ;;
  *"/rulesets/"*) echo "${GH_RULESET_CHECKS:-}" ;;
  *"/rulesets --jq"*) [ -z "${GH_RULESET:-}" ] || printf '7\t%s\n' "$GH_RULESET" ;;
  *"/protection"*) [ -n "${GH_PROTECTION:-}" ] && echo "$GH_PROTECTION" || { echo '{"message":"Branch not protected"}'; exit 1; } ;;
  *"/tarball/"*) [ -n "${GH_TARBALL_FAIL:-}" ] && exit 1; tar -czf - -C "$TARBALL_SRC" omni-stove-.github-abc ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$DIR/bin/gh"
  cd "$DIR/repo"
  git init -q .
  printf '{"name":"demo","packageManager":"pnpm@10.0.0","scripts":{"lint":"biome check .","test":"vitest run"},"workspaces":["apps/*"]}\n' > package.json
  : > pnpm-lock.yaml
}

teardown() {
  rm -rf "$DIR"
}

@test "fails outside a git repository" {
  cd "$DIR"
  run bash "$SCRIPT" --from "$BATS_TEST_DIRNAME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"git リポジトリの中で実行"* ]]
}

@test "unknown option and a missing --from directory exit 2" {
  run bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option: --bogus"* ]]
  [[ "$output" == *"usage:"* ]]
  run bash "$SCRIPT" --from "$DIR/nope"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--from のディレクトリが無い"* ]]
}

@test "prints the repo's facts: toolchain, scripts, tasks, markers, workflows and the ref they pin" {
  printf '[tools]\nnode = "22.11.0"\npnpm = "10"\n[tasks.build]\ndescription = "Build it"\nrun = "x"\n' > mise.toml
  mkdir -p .mise apps/web .github/workflows
  printf '[lint]\ndescription = "Lint it"\nrun = "x"\n[test]\nrun = "y"\n' > .mise/tasks.toml
  echo '{}' > apps/web/package.json
  : > Dockerfile
  printf 'jobs:\n  ci:\n    uses: omni-stove/.github/.github/workflows/ci.yml@v2\n    steps:\n      - uses: actions/checkout@v4\n      - uses: actions/checkout@v4\n' > .github/workflows/ci.yml
  run bash "$SCRIPT" --from "$BATS_TEST_DIRNAME"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nrepo\tomni-stove/demo (PRIVATE)\n'* ]]
  [[ "$output" == *$'\ndefault-branch\tmain\n'* ]]
  [[ "$output" == *$'\nref\tv2\n'* ]]
  [[ "$output" == *$'\npackage-manager\tpnpm-lock.yaml pnpm@10.0.0\n'* ]]
  [[ "$output" == *$'\nscript\tlint\tbiome check .\n'* ]]
  [[ "$output" == *$'\nworkspaces\tapps/*\n'* ]]
  [[ "$output" == *$'\npackages\tapps/web\n'* ]]
  [[ "$output" == *$'\nnode\t22\n'* ]]
  [[ "$output" == *$'\ntools\tnode = "22.11.0" pnpm = "10"\n'* ]]
  [[ "$output" == *$'\ntask\tbuild\tBuild it\n'* ]]
  [[ "$output" == *$'\ntask\tlint\tLint it\n'* ]]
  [[ "$output" == *$'\ntask\ttest\n'* ]]
  [[ "$output" == *$'\nmarkers\tDockerfile .mise/tasks.toml\n'* ]]
  [[ "$output" == *$'\nworkflow\t.github/workflows/ci.yml: omni-stove/.github/.github/workflows/ci.yml@v2 actions/checkout@v4\n'* ]]
  [[ "$output" == *$'\ncatalog\t'"$BATS_TEST_DIRNAME"' ('* ]]
  [[ "$output" == *"--ref v2 --review --ruleset"* ]]
}

@test "reports labels, secrets and rulesets through gh, with a create command per missing label" {
  GH_LABELS="bug hotfix" GH_REPO_SECRETS="ANTHROPIC_API_KEY" GH_ORG_SECRETS="REVIEWER_GH_APP_ID REVIEWER_GH_APP_PRIVATE_KEY" \
    GH_RULESET="CI Gate" GH_RULESET_CHECKS="ci / CI Gate" GH_PROTECTION="" \
    run bash "$SCRIPT" --from "$BATS_TEST_DIRNAME"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nlabels\tbug hotfix\n'* ]]
  [[ "$output" != *"gh label create hotfix"* ]]
  [[ "$output" == *$'\nlabel-create\tgh label create revert --color 5319e7 --description "'* ]]
  [[ "$output" == *"gh label create security --color e11d21"* ]]
  [[ "$output" == *$'\nsecrets\tANTHROPIC_API_KEY REVIEWER_GH_APP_ID REVIEWER_GH_APP_PRIVATE_KEY\n'* ]]
  [[ "$output" == *$'\nsecrets-missing\tOPENAI_API_KEY AGENT_GH_APP_ID AGENT_GH_APP_PRIVATE_KEY CLOUDFLARE_API_TOKEN\n'* ]]
  [[ "$output" == *$'\nruleset\tCI Gate: required checks: ci / CI Gate\n'* ]]
  [[ "$output" != *"branch-protection"* ]]
  [[ "$output" != *"Branch not protected"* ]]
}

@test "without gh it still prints the facts it can, and the curl form of install.sh" {
  GH_AUTH=1 run bash "$SCRIPT" --from "$BATS_TEST_DIRNAME"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nrepo\tgh で見えない'* ]]
  [[ "$output" != *"secrets-missing"* ]]
  [[ "$output" != *"label-create"* ]]
  [[ "$output" == *"curl -fsSL https://raw.githubusercontent.com/omni-stove/.github/main/install.sh | bash -s -- --ref main --review --ruleset"* ]]
}

@test "prints the README and each action's and reusable workflow's interface, without their bodies" {
  run bash "$SCRIPT" --from "$BATS_TEST_DIRNAME"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\n==> README omni-stove/.github\n# .github\n'* ]]
  [[ "$output" == *$'\n==> action setup-pnpm-node\nuses\tomni-stove/.github/actions/setup-pnpm-node@main\nname: Setup pnpm & Node.js\n'* ]]
  [[ "$output" == *$'  install-filter:\n    description: pnpm --filter value (empty = all packages)\n    default: ""\n\n==> workflow auto-merge.yml\n'* ]]
  [[ "$output" == *$'\n==> action agent-run\nuses\tomni-stove/.github/actions/agent-run@main\n'* ]]
  [[ "$output" == *$'\n==> workflow ci.yml\nuses\tomni-stove/.github/.github/workflows/ci.yml@main\nname: CI\n'* ]]
  [[ "$output" == *"workflow_call:"* ]]
  [[ "$output" != *"pnpm/action-setup"* ]]
  [[ "$output" != *"Resolve test jobs"* ]]
  [[ "$output" == *$'\n==> next\n'* ]]
}

@test "fetches the catalog as a tarball through gh and keeps it on disk" {
  run bash "$SCRIPT" --ref v3
  [ "$status" -eq 0 ]
  grep -q "api repos/omni-stove/.github/tarball/v3" "$GH_LOG"
  dir="$(printf '%s\n' "$output" | sed -n 's/^catalog\t\(.*\) (.*/\1/p')"
  [ -f "$dir/README.md" ]
  [ -f "$dir/actions/ci-gate/action.yml" ]
  [[ "$output" == *$'\nuses\tomni-stove/.github/actions/ci-gate@v3\n'* ]]
}

@test "fails when the catalog cannot be fetched" {
  GH_TARBALL_FAIL=1 run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"omni-stove/.github@main を取得できなかった"* ]]
}
