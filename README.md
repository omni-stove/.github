# .github

Organization-wide GitHub Actions for omni-stove.

## Composite Actions

### `setup-pnpm-node`

Sets up pnpm + Node.js with caching.

```yaml
- uses: omni-stove/.github/actions/setup-pnpm-node@v1
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
    uses: omni-stove/.github/.github/workflows/ci.yml@v1
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
    uses: omni-stove/.github/.github/workflows/deploy-cloudflare-worker.yml@v1
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
    uses: omni-stove/.github/.github/workflows/auto-merge.yml@v1
    secrets: inherit
```

### `coderabbit-bot-review.yml`

Trigger CodeRabbit review on bot PRs.

```yaml
jobs:
  trigger-review:
    uses: omni-stove/.github/.github/workflows/coderabbit-bot-review.yml@v1
    secrets: inherit
```
