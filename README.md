# .github

Organization-wide GitHub Actions for omni-stove.

## Composite Actions

### `setup-pnpm-node`

Sets up pnpm + Node.js with caching.

```yaml
- uses: omni-stove/.github/actions/setup-pnpm-node@main
  with:
    node-version: "24"          # default: "24"
    frozen-lockfile: "true"     # default: "true"
    install-filter: ""          # default: "" (all packages)
```

## Reusable Workflows

### `ci.yml`

Lint, typecheck, and test.

```yaml
jobs:
  ci:
    uses: omni-stove/.github/.github/workflows/ci.yml@main
    with:
      lint-command: "pnpm lint"
      typecheck-command: "pnpm typecheck"
      test-command: "pnpm test"
```

### `deploy-cloudflare-worker.yml`

Deploy a Cloudflare Worker.

```yaml
jobs:
  deploy:
    uses: omni-stove/.github/.github/workflows/deploy-cloudflare-worker.yml@main
    with:
      app-name: my-app
      working-directory: apps/my-app
    secrets:
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

### `auto-merge.yml`

Auto-merge approved PRs.

```yaml
jobs:
  auto-merge:
    uses: omni-stove/.github/.github/workflows/auto-merge.yml@main
    secrets: inherit
```

### `coderabbit-bot-review.yml`

Trigger CodeRabbit review on bot PRs.

```yaml
jobs:
  trigger-review:
    uses: omni-stove/.github/.github/workflows/coderabbit-bot-review.yml@main
    secrets: inherit
```
