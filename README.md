# .github

Organization-wide GitHub Actions for omni-stove.

## 利用側リポジトリへの導入 (一撃)

利用側リポジトリのルートで 1 行。CI Gate の呼び出し workflow (`ci.yml` / `hotfix-revert-approve.yml`) を書き、
`hotfix` / `revert` ラベルを作り、secrets の有無を確認して、残りの手作業を `todo` として並べる。

```sh
curl -fsSL https://raw.githubusercontent.com/omni-stove/.github/main/install.sh | bash -s -- --review --ruleset
# private のときは gh 経由
gh api repos/omni-stove/.github/contents/install.sh -H 'Accept: application/vnd.github.raw' | bash -s -- --review --ruleset
```

| option | 説明 |
| --- | --- |
| `--review` | Code Review (`run-review: true`) を有効にする |
| `--provider claude\|codex` | レビューの provider (既定: claude) |
| `--auto-merge` | `auto-merge.yml` も入れる |
| `--ruleset` | 既定ブランチに `ci / CI Gate` を必須チェックにする ruleset "CI Gate" を作る (同名があれば更新。admin 権限が要る) |
| `--ref <ref>` | `omni-stove/.github` の参照 (既定: `main`) |
| `--force` | 既存の workflow ファイルを上書きする |
| `--no-labels` | ラベルを作らない |

検出するもの: `mise.toml` (`node = "..."`) → Node.js バージョン、`package.json` の `lint` / `typecheck` / `test` script →
各コマンド (無ければ `echo "skip: ..."` または `run-test: false` にして `todo` を出す)、`origin/HEAD` または gh → 既定ブランチ、
リポジトリの公開/非公開 → 公開なら `review-allowed-bots: ""`。

依存は bash と git だけ。gh でログインしていればラベル / secrets 確認 / ruleset まで行い、無ければ `todo` に落とす。
テストは `bats install.bats`。

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

### `github-app-token`

GitHub App の installation access token を生成する。token に加えて、レビュー提出や dismiss の
対象を絞るための `bot-login` (`<app-slug>[bot]`) も返す。

```yaml
- uses: omni-stove/.github/actions/github-app-token@main
  id: app
  with:
    app-id: ${{ secrets.REVIEWER_GH_APP_ID }}
    private-key: ${{ secrets.REVIEWER_GH_APP_PRIVATE_KEY }}
# steps.app.outputs.token / app-slug / bot-login
```

### `check-pr-conflict`

PR がベースブランチとコンフリクトしているか (`mergeable_state == 'dirty'`) を判定する。
`opened` では判定をスキップして必ず `conflicted=false` を返す。

```yaml
- uses: omni-stove/.github/actions/check-pr-conflict@main
  id: conflict
  with:
    pr-number: ${{ github.event.pull_request.number }}
# steps.conflict.outputs.conflicted == 'true' なら後続ジョブをスキップする
```

### `ci-gate`

複数ジョブの結果を集約して 1 つの必須チェックにする。`failure` / `cancelled` が 1 つでもあれば
失敗、`skipped` は失敗ではない。`hotfix` / `revert` ラベル、`revert-` ブランチは素通しで success。

```yaml
ci-gate:
  name: CI Gate
  needs: [lint, test, e2e]
  if: always()
  runs-on: ubuntu-latest
  steps:
    - uses: omni-stove/.github/actions/ci-gate@main
      with:
        results: ${{ toJSON(needs) }}      # または 1 行 1 件の "name=result"
        bypass-labels: "hotfix,revert"     # default
        bypass-branch-prefixes: "revert-"  # default
```

### `agent-run`

コーディングエージェント (Claude Code / OpenAI Codex) を共通インターフェースで実行する。
`provider` を切り替えるだけで、prompt / json-schema / allowed-tools / permission-profile は
どちらでも同じ意味で動く。スクリプトは全て bash + jq (Node.js 不要)。

```yaml
- uses: omni-stove/.github/actions/agent-run@main
  id: agent
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}            # provider=claude (または CLAUDE_CODE_OAUTH_TOKEN)
    CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
    OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}                  # provider=codex
    AGENT_GITHUB_TOKEN: ${{ github.token }}
  with:
    provider: claude            # claude | codex
    tier: high                  # max | high | medium | low (provider ごとの最新世代に解決)
    model: ""                   # 指定すると tier より優先
    effort: ""                  # low | medium | high | xhigh | max
    permission-profile: ""      # read-only | workspace-write | danger-full-access (空なら allowed-tools から推定)
    allowed-tools: "Read,Grep,Bash(git diff:*)"
    disallowed-tools: "WebFetch,WebSearch"
    system-prompt: "Always output in Japanese."
    json-schema: '{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"]}'
    prompt: "..."
# steps.agent.outputs.structured-output / text-output / provider / model / execution-file
```

| 入力 | 説明 |
| --- | --- |
| `provider` | `claude` (既定) か `codex` |
| `tier` / `model` / `effort` | tier は max→fable/astra、high→opus/sol、medium→sonnet/terra、low→haiku/luna に解決。model 指定時はそのまま渡す |
| `allowed-tools` / `disallowed-tools` / `settings` | Claude 形式 (`Tool` / `Bash(pattern)`)。Codex では PreToolUse hook (`tool-policy-hook.sh`) と config に変換する。Codex に変換できない settings はエラー |
| `permission-profile` | `read-only` では書き込み系ツールと安全でない Bash を両 provider で拒否する。Claude は `Bash(pattern)` を固定の読み取りコマンド (`git --no-optional-locks status` 等) に限る |
| `json-schema` | 構造化出力を強制し、両 provider の出力を `validate-json-schema.jq` で検証する。違反なら失敗 |
| `extra-claude-args` / `extra-codex-args` | provider 固有の追加引数。他方の provider では警告して無視 |
| `rate-limit-retry-max-wait-seconds` | Claude が GitHub API のレート制限で落ちたら解除まで待って 1 回再実行する |

テストは `actions/agent-run/*.bats` (`bats actions/agent-run`)。

### `fetch-review-diff` / `post-review-comments` / `finalize-review`

`ci.yml` の Code Review が使う部品。自前のレビューワークフローを組むときにも使える。

| action | 役割 |
| --- | --- |
| `fetch-review-diff` | PR の diff と文脈 (説明 / 参照 Issue / コミット / コメント / レビュースレッド) を取得し、ドキュメント・自動生成物・lockfile 等を除外して出力する。プロンプト上限を超える分は作業ツリーに書き出す |
| `post-review-comments` | 構造化出力 `{"comments":[{path,line,body}]}` をインラインコメント付き review として投稿する。重複除外、422 時のファイル単位 → 通常コメントへのフォールバック付き |
| `finalize-review` | lint / test の結果と指摘件数から approve / request-changes を提出する。自分の古い CHANGES_REQUESTED は提出前に dismiss する |

## Reusable Workflows

### `ci.yml`

Lint / Test / Code Review を並列実行し、全結果を **"CI Gate"** という単一の必須チェックに集約する。

```
changes ─┬─ lint ───┬─ CI Gate   (必須チェック)
         ├─ test ───┤
         └─ review ─┴─ finalize  (approve / request-changes。run-review のときだけ)
```

```yaml
on:
  pull_request:

concurrency:
  group: ci-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
  ci:
    uses: omni-stove/.github/.github/workflows/ci.yml@main
    permissions:
      contents: read
      pull-requests: write
      issues: write
      id-token: write
    with:
      lint-command: "pnpm lint"
      typecheck-command: "pnpm typecheck"
      test-command: "pnpm test"
      run-review: true               # default: false
    secrets: inherit
```

| input | default | 説明 |
| --- | --- | --- |
| `node-version` | `"24"` | |
| `lint-command` | `"pnpm lint"` | |
| `typecheck-command` | `"pnpm typecheck"` | |
| `test-command` | `"pnpm test"` | `test-jobs` を指定しないときの単一 test コマンド |
| `test-jobs` | `""` | test ジョブの定義 (JSON 配列)。下記「test をアプリごとに差し替える」参照 |
| `run-test` | `true` | |
| `gate` | `true` | `false` で CI Gate と finalize をこの workflow では走らせない (呼び出し側の `ci-gate.yml` に任せる) |
| `run-review` | `false` | Claude Code によるコードレビューと approve / request-changes の提出を行う |
| `review-provider` | `"claude"` | レビューを実行するエージェント (`claude` / `codex`)。`agent-run` で切り替える |
| `review-tier` | `"high"` | モデルの tier (max / high / medium / low) |
| `review-model` | `""` | モデルを直接指定する (空なら tier から解決) |
| `review-effort` | `""` | 推論 effort |
| `review-max-turns` | `"80"` | `--max-turns` |
| `review-allowed-bots` | `"*"` | bot が作った PR でもレビューを走らせる bot 名 (カンマ区切り)。公開リポジトリでは外部 App が起動できてしまうため、bot 名を列挙するか `""` にする |
| `review-instructions` | `""` | レビュー指示に追記する文 (リポジトリ固有の観点や弱点) |
| `review-exclude-patterns` | `""` | レビュー対象から追加で除外する glob (改行区切り) |

| secret | 必須 | 説明 |
| --- | --- | --- |
| `CLAUDE_CODE_OAUTH_TOKEN` または `ANTHROPIC_API_KEY` | `review-provider: claude` のとき | Claude Code の認証 |
| `OPENAI_API_KEY` | `review-provider: codex` のとき | Codex の認証 |
| `REVIEWER_GH_APP_ID` / `REVIEWER_GH_APP_PRIVATE_KEY` | 推奨 | レビューを投稿・approve する GitHub App。無ければ `github.token` を使う (下記参照) |

`ci.yml` の outputs: `conflicted` / `review-comments` / `review-result` (`gate: false` のとき `ci-gate.yml` に渡す)。

挙動:

- **CI Gate** は `always()` で必ず走り、lint / test / review のどれかが `failure` / `cancelled` なら失敗する。
  `skipped` (`run-test: false` 等) は失敗ではない。ruleset の必須チェックには `ci / CI Gate` だけを登録する。
- **コンフリクト PR** は lint / test / review を走らせない。解消で `synchronize` が飛び、CI が再実行される。
- **緊急避難口**: `hotfix` / `revert` ラベル、または `revert-` ブランチの PR は lint / test / review をスキップし、
  CI Gate は素通しで success になる。request-changes によるマージブロックは `hotfix-revert-approve.yml` が外す。
- **Code Review** は `agent-run` (Claude Code / Codex) が指摘を構造化出力で返し、インラインコメントとして投稿する。コメントの
  投稿に失敗した run は CI Gate を通過しない。マージコミット (Update Branch) と、除外後にレビュー対象が
  残らない PR ではレビューをスキップする。
- **finalize** は lint / test に failure があれば指摘 0 件でも request-changes、無ければ指摘件数で決める
  (1 件以上で request-changes、0 件で approve)。レビューが failure / cancelled で完了していないときも
  request-changes に倒す。提出前に自分の古い CHANGES_REQUESTED を dismiss するので、常に最新の判定だけが残る。

#### test をアプリごとに差し替える

**複数の test ジョブを並列に走らせる** (`test-jobs`)。pnpm + Node.js のセットアップは共通で、
コマンド・前処理・作業ディレクトリ・runner をジョブごとに変えられる。どれか 1 つでも落ちれば
test ジョブは failure になり CI Gate が止める。

```yaml
    with:
      test-jobs: |
        [
          { "name": "unit", "command": "pnpm test" },
          { "name": "e2e",  "command": "pnpm e2e",
            "setup": "pnpm exec playwright install --with-deps chromium",
            "timeoutMinutes": 45 },
          { "name": "worker", "command": "pnpm test",
            "workingDirectory": "apps/worker", "installFilter": "worker" }
        ]
```

| key | 必須 | 説明 |
| --- | --- | --- |
| `name` | ✓ | ジョブ名 (`Test (<name>)` として表示) |
| `command` | ✓ | test コマンド |
| `setup` | | test の前に実行するコマンド (ブラウザのインストール等) |
| `workingDirectory` | | `setup` / `command` の作業ディレクトリ (既定: `.`) |
| `runsOn` | | runner (既定: `ubuntu-latest`) |
| `nodeVersion` | | Node.js のバージョン (既定: `node-version` 入力) |
| `installFilter` | | `pnpm install --filter` の値 |
| `timeoutMinutes` | | ジョブのタイムアウト (既定: 30) |

**test ジョブを呼び出し側で自前に書く** (`run-test: false` + `gate: false` + `ci-gate.yml`)。
services / container / 独自の runner など `test-jobs` で表現できないときはこちら。
Lint / Review は `ci.yml` に任せ、test ジョブは自由に書き、全ジョブの結果を `ci-gate.yml` に渡して
CI Gate と finalize を呼び出し側に置く。必須チェックは `gate / CI Gate` になる。

```yaml
jobs:
  ci:
    uses: omni-stove/.github/.github/workflows/ci.yml@main
    permissions:
      contents: read
      pull-requests: write
      issues: write
      id-token: write
    with:
      run-test: false
      gate: false
      run-review: true
    secrets: inherit

  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:17
        env: { POSTGRES_PASSWORD: postgres }
        ports: ["5432:5432"]
    steps:
      - uses: actions/checkout@v6
      - uses: omni-stove/.github/actions/setup-pnpm-node@main
      - run: pnpm test

  gate:
    needs: [ci, test]
    if: always()
    uses: omni-stove/.github/.github/workflows/ci-gate.yml@main
    permissions:
      contents: read
      pull-requests: write
    with:
      results: ${{ toJSON(needs) }}
      conflicted: ${{ needs.ci.outputs.conflicted }}
      review-comments: ${{ needs.ci.outputs.review-comments }}
      review-result: ${{ needs.ci.outputs.review-result }}
    secrets: inherit
```

### `ci-gate.yml`

`ci.yml` (`gate: false`) と呼び出し側の test ジョブの結果をまとめて CI Gate と finalize にする。
使い方は上の「test ジョブを呼び出し側で自前に書く」を参照。

| input | default | 説明 |
| --- | --- | --- |
| `results` | (必須) | 呼び出し側の `toJSON(needs)` |
| `conflicted` | `"false"` | `ci.yml` の `outputs.conflicted` |
| `review-comments` | `""` | `ci.yml` の `outputs.review-comments` |
| `review-result` | `""` | `ci.yml` の `outputs.review-result` |
| `finalize` | `true` | approve / request-changes を提出するか (`ci.yml` を `run-review` で呼んでいるときだけ) |

### `hotfix-revert-approve.yml`

緊急避難口。PR に `hotfix` / `revert` ラベルが付いたら実行中の CI run をキャンセルし、reviewer App で
approve を出して CI の request-changes によるマージブロックを外す。`revert-` ブランチの PR は
ラベルがなくても `opened` / `reopened` で同じ処理を行う。

```yaml
on:
  pull_request:
    types: [labeled, opened, reopened]

jobs:
  approve:
    uses: omni-stove/.github/.github/workflows/hotfix-revert-approve.yml@main
    permissions:
      contents: read
      actions: write
      pull-requests: write
    with:
      ci-workflow: "ci.yml"   # default。キャンセル対象の workflow ファイル名
    secrets: inherit
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

### `claude-code.yml`

コーディングエージェントに prompt を渡して実行する (`agent-run` 経由。provider は切り替え可)。
main への直接 push は deny している。

```yaml
jobs:
  run:
    uses: omni-stove/.github/.github/workflows/claude-code.yml@main
    with:
      prompt: "..."
      provider: claude          # claude | codex
      tier: high
      allowed-tools: "Edit,Write,Read,Bash"
    secrets: inherit            # CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY / OPENAI_API_KEY
```

## GitHub App の設定 (CI Gate 用)

Code Review の approve / request-changes は、PR 作成者とは別の identity で提出する必要がある
(GitHub は自分の PR への approve を拒否する)。`github.token` (`github-actions[bot]`) で出すと、
`github-actions[bot]` が作った PR (Claude Code が Issue から起こす PR など) に approve できず、
`labeled` 等のイベントも他の workflow を起動しない。そのため reviewer 専用の GitHub App を 1 つ作る。

### 1. App を作る

Organization の Settings → Developer settings → GitHub Apps → New GitHub App

| 項目 | 値 |
| --- | --- |
| GitHub App name | `omni-stove-reviewer` (任意。bot login は `omni-stove-reviewer[bot]` になる) |
| Homepage URL | `https://github.com/omni-stove/.github` |
| Webhook | Active のチェックを外す |
| Repository permissions | **Pull requests: Read and write** (review の提出・dismiss、インラインコメント) <br> **Issues: Read and write** (インライン化できなかった指摘のフォールバックコメント) <br> **Contents: Read-only** <br> **Metadata: Read-only** (自動) |
| Where can this App be installed? | Only on this account |

作成後、**Generate a private key** で PEM をダウンロードし、App ID を控える。

### 2. Organization にインストールする

App の Install App → omni-stove → All repositories (または CI Gate を使うリポジトリだけ)。

### 3. Secrets を登録する

Organization の Settings → Secrets and variables → Actions → New organization secret

| secret | 値 |
| --- | --- |
| `REVIEWER_GH_APP_ID` | App ID |
| `REVIEWER_GH_APP_PRIVATE_KEY` | ダウンロードした PEM の中身 |
| `CLAUDE_CODE_OAUTH_TOKEN` または `ANTHROPIC_API_KEY` | Claude Code の認証 |

呼び出し側は `secrets: inherit` で渡す。リポジトリ単位で secrets を置いてもよい。

### 4. ラベルと必須チェック

- 各リポジトリに `hotfix` / `revert` ラベルを作る (緊急避難口。無ければ機能しないだけで害はない)。
- ruleset / branch protection の必須チェックに `ci / CI Gate` (`ci` は呼び出し側の job 名) を登録する。
  Lint / Test / Review の個別ジョブは登録しない (スキップ時に pending のまま残るため)。

### (任意) PR を作る agent 用の App

Claude Code などが PR を作るワークフローで `github.token` の代わりに App token を使うと、
作成した PR の `pull_request` イベントで CI が起動する (`github.token` で作った PR では起動しない)。
その場合も reviewer App とは**別の** App にする (同じ App だと自分の PR に approve できない)。
`actions/github-app-token` で token を作り、`actions/checkout` の `token` や `gh` の `GH_TOKEN` に渡す。
