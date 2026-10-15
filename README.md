# .github

omni-stove の共通 GitHub Actions (reusable workflow と composite action)。

各 workflow / action の入力・出力・secrets とその既定値は、その yml の `inputs` / `outputs` / `secrets` が正。
この README には、導入の手順と、yml を読むだけでは分からない横断的な挙動を書く。

## 導入

利用側リポジトリのルートで 1 行。CI Gate の呼び出し workflow (`ci.yml` / `hotfix-revert-approve.yml`) を書き、
ラベルを作り、secrets の有無を確認して、残りの手作業を `todo` として並べる。オプションは `--help` に出る。

```sh
curl -fsSL https://raw.githubusercontent.com/omni-stove/.github/main/install.sh | bash -s -- --review --ruleset
# private のときは gh 経由
gh api repos/omni-stove/.github/contents/install.sh -H 'Accept: application/vnd.github.raw' | bash -s -- --review --ruleset
```

検出するもの: `mise.toml` (`node = "..."`) → Node.js バージョン、`package.json` の `lint` / `typecheck` / `test` script →
各コマンド (無ければ `echo "skip: ..."` または `run-test: false` にして `todo` を出す)、`origin/HEAD` または gh → 既定ブランチ、
リポジトリの公開/非公開 → 公開なら `review-allowed-bots: ""` / `allowed-bots: ""`。

2 回目以降は同じコマンドで更新になる。install.sh が作った workflow は最新のテンプレート (permissions や新しい input) に
書き直され、`with:` の値 (手で直したコマンドや追加した input も) と `uses:` の参照は既存のものを引き継ぐ。
オプションで指定したものだけが上書きされ、`echo "skip: ..."` / `run-test: false` は検出し直す
(script を追加して再実行すれば本物のコマンドになる)。中身が同じなら `unchanged`、install.sh 以外が作ったファイルは `kept` で触らない。

依存は bash と git だけ。gh でログインしていればラベル / secrets 確認 / ruleset まで行い、無ければ `todo` に落とす。

## GitHub App と secrets

Code Review の approve / request-changes は、PR 作成者とは別の identity で提出する必要がある
(GitHub は自分の PR への approve を拒否する)。`github.token` (`github-actions[bot]`) で出すと、
`github-actions[bot]` が作った PR に approve できず、`labeled` 等のイベントも他の workflow を起動しない。
そのため **reviewer App** (レビューを提出する) と **agent App** (PR を作る) の 2 つを作る。
同じ App にすると自分の PR に approve できない。

### reviewer App

Organization の Settings → Developer settings → GitHub Apps → New GitHub App

| 項目 | 値 |
| --- | --- |
| GitHub App name | `omni-stove-reviewer` (任意。bot login は `omni-stove-reviewer[bot]` になる) |
| Homepage URL | `https://github.com/omni-stove/.github` |
| Webhook | Active のチェックを外す |
| Repository permissions | **Pull requests: Read and write** (review の提出・dismiss、インラインコメント) <br> **Issues: Read and write** (インライン化できなかった指摘のフォールバックコメント) <br> **Contents: Read-only** <br> **Metadata: Read-only** (自動) |
| Where can this App be installed? | Only on this account |

作成後、App の設定画面 (`https://github.com/organizations/<org>/settings/apps/<app-name>`) で次を取る。

- **App ID**: General に表示される。
- **PEM**: Credentials → Key pairs → **New key** でダウンロードされる (Key pairs の URL は `.../settings/apps/<app-name>/key_pairs`)。

App の Install App → omni-stove → All repositories (または使うリポジトリだけ) でインストールする。

### agent App

`issue-worker.yml` など agent が PR を作る workflow で `github.token` の代わりに使う。App token で作った PR では
`pull_request` イベントで CI が起動する (`github.token` で作った PR では起動しない)。

| 項目 | 値 |
| --- | --- |
| GitHub App name | `omni-stove-agent` (任意。コミットと PR の author が `<name>[bot]` になる) |
| Webhook | Active のチェックを外す |
| Repository permissions | **Contents: Read and write** (ブランチへの push) <br> **Pull requests: Read and write** (PR 作成・ラベル) <br> **Issues: Read and write** (Issue の読み取り・コメント) <br> **Metadata: Read-only** (自動) |

App ID と PEM の取り方とインストールは reviewer App と同じ。自前の workflow では `actions/github-app-token` で token を作り、
`actions/checkout` の `token` や `gh` の `GH_TOKEN` に渡す。

### secrets

Organization の Settings → Secrets and variables → Actions → New organization secret (リポジトリ単位でもよい)。
呼び出し側は `secrets: inherit` で渡す。

| secret | 使う workflow | 値 |
| --- | --- | --- |
| `CLAUDE_CODE_OAUTH_TOKEN` または `ANTHROPIC_API_KEY` | `ci.yml` (`run-review`) / `issue-worker.yml` / `claude-code.yml` の provider `claude` | Claude Code の認証 |
| `OPENAI_API_KEY` | 同上の provider `codex` | Codex の認証 |
| `REVIEWER_GH_APP_ID` / `REVIEWER_GH_APP_PRIVATE_KEY` | `ci.yml` / `ci-gate.yml` / `hotfix-revert-approve.yml` | reviewer App の App ID / PEM。無ければ `github.token` で投稿する |
| `AGENT_GH_APP_ID` / `AGENT_GH_APP_PRIVATE_KEY` | `issue-worker.yml` | agent App の App ID / PEM。無ければ `github.token` で PR を作る |
| `CLOUDFLARE_API_TOKEN` | `deploy-cloudflare-worker.yml` | Cloudflare の API token |

### ラベルと必須チェック

install.sh が作る。手で作るときは次のとおり。

| ラベル | 役割 |
| --- | --- |
| `hotfix` / `revert` | 緊急避難口。PR に付けると lint / test / review をスキップして CI Gate を素通しにし、`hotfix-revert-approve.yml` が approve を出す。`revert-` ブランチの PR はラベル無しで同じ扱い |
| `bug` / `security` / `prototype` / `implementation` | Issue に付けると `issue-worker.yml` が起動する (下記) |

ruleset / branch protection の必須チェックには `ci / CI Gate` (`ci` は呼び出し側の job 名) だけを登録する。
Lint / Test / Review の個別ジョブは登録しない (スキップ時に pending のまま残るため)。

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
  push:
    branches: [main]
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
      run-review: true
    secrets: inherit
```

- **CI Gate** は `always()` で必ず走り、lint / test / review のどれかが `failure` / `cancelled` なら失敗する。
  `skipped` (`run-test: false` 等) は失敗ではない。
- **コンフリクト PR** は lint / test / review を走らせない。解消で `synchronize` が飛び、CI が再実行される。
- **Code Review** は `agent-run` (Claude Code / Codex) が指摘を構造化出力で返し、インラインコメントとして投稿する。
  コメントの投稿に失敗した run は CI Gate を通過しない。マージコミット (Update Branch) と、除外後にレビュー対象が
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
    secrets: inherit
```

### `issue-worker.yml`

Issue にラベルを付けるとコーディングエージェントが着手し、編集を PR にする。エージェントは編集と
PR 文面 (構造化出力) だけを担当し、ブランチ・ラベル・draft・commit / push / PR 作成は step が決定論で行う。

| ラベル | 動き | ブランチ |
| --- | --- | --- |
| `bug` | 修正 PR。直すものが無ければコードを変えず理由を Issue にコメントする | `agent-fix/issue-<n>` |
| `security` | 指摘された `path:line` だけを直す修正 PR (`security` ラベル付き)。lint の抑制やキャストでの隠蔽、依存の version bump はしない | `agent-security-fix/issue-<n>` |
| `prototype` | モックで良い試作の draft PR (`prototype` ラベル付き) | `agent-proto/issue-<n>` |
| `implementation` | 本実装 (実 DB / API、エラーハンドリング、テスト込み) の PR。`prototype` ラベルも付いた Issue では走らない | `agent-implement/issue-<n>` |

`App:<name>` ラベルが付いていれば編集を `apps/<name>` に絞り、PR にも同じラベルを引き継ぐ。

```yaml
on:
  issues:
    types: [labeled]

jobs:
  work:
    uses: omni-stove/.github/.github/workflows/issue-worker.yml@main
    permissions:
      contents: write
      pull-requests: write
      issues: write
      id-token: write
    with:
      provider: "claude"
      regen-command: 'pnpm install --lockfile-only --no-frozen-lockfile'
    secrets: inherit
```

- **発火は `labeled` だけ**。ラベル付きで作成された Issue にも `labeled` は飛ぶので取りこぼさない。
  ラベルを付けられるのは triage 権限以上なので、Issue を書けるだけの人は起動できない (Issue 本文はプロンプトに入る)。
- **同じ Issue の再実行** (ラベルを外して付け直す) は同じブランチに push し、open PR があればそれを更新する。
- **変更なし**で終わったら PR を作らず、エージェントの理由と実行ログの URL を Issue にコメントする。
- **Closes / refs** は構造化出力の `closes_issue` だけで決める。エージェントの文面にある close 系キーワードは外す。
- **エージェントは依存を install しない**。`package.json` 等を変えたときは `regen-command` で lockfile / 生成物を作り直す。
  空なら作り直さず、不整合は CI が落として知らせる。
- **起票は `gh issue create --label bug`** のようにラベル付きで作ればよい。大きなタスクは `remote-issue` skill
  (skill-kit) で `bug` / `prototype` / `implementation` の Issue 群に分割して投げる。

### `claude-code.yml`

コーディングエージェントに prompt を渡して実行する (`agent-run` 経由。provider は切り替え可)。
main への直接 push は deny している。

```yaml
jobs:
  run:
    uses: omni-stove/.github/.github/workflows/claude-code.yml@main
    with:
      prompt: "..."
      provider: claude
      tier: high
      allowed-tools: "Edit,Write,Read,Bash"
    secrets: inherit
```

### `auto-merge.yml`

approve された PR を自動でマージする。`prototype` ラベル付きの PR は既定で対象外。

```yaml
on:
  pull_request_review:
    types: [submitted]

jobs:
  auto-merge:
    uses: omni-stove/.github/.github/workflows/auto-merge.yml@main
    permissions:
      contents: write
      pull-requests: write
    secrets: inherit
```

### `deploy-cloudflare-worker.yml`

Cloudflare Worker をデプロイする。

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

## Composite Actions

### `setup-pnpm-node`

pnpm + Node.js をキャッシュ付きでセットアップし、依存を install する。

```yaml
- uses: omni-stove/.github/actions/setup-pnpm-node@main
  with:
    node-version: "24"
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

```yaml
- uses: omni-stove/.github/actions/check-pr-conflict@main
  id: conflict
  with:
    pr-number: ${{ github.event.pull_request.number }}
# steps.conflict.outputs.conflicted == 'true' なら後続ジョブをスキップする
```

### `ci-gate`

複数ジョブの結果を集約して 1 つの必須チェックにする。

```yaml
ci-gate:
  name: CI Gate
  needs: [lint, test, e2e]
  if: always()
  runs-on: ubuntu-latest
  steps:
    - uses: omni-stove/.github/actions/ci-gate@main
      with:
        results: ${{ toJSON(needs) }}
```

### `agent-run`

コーディングエージェント (Claude Code / OpenAI Codex) を共通インターフェースで実行する。
`provider` を切り替えるだけで、prompt / json-schema / allowed-tools / permission-profile は
どちらでも同じ意味で動く。認証は `with` ではなく `env` で受ける。

```yaml
- uses: omni-stove/.github/actions/agent-run@main
  id: agent
  env:
    ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
    CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
    OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
    AGENT_GITHUB_TOKEN: ${{ github.token }}
  with:
    provider: claude
    tier: high
    allowed-tools: "Read,Grep,Bash(git diff:*)"
    system-prompt: "Always output in Japanese."
    json-schema: '{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"]}'
    prompt: "..."
# steps.agent.outputs.structured-output / text-output / provider / model / execution-file
```

### `resolve-issue` / `create-issue-pr` / `agent-regen`

`issue-worker.yml` が使う部品。Issue 起点の自前ワークフローを組むときにも使える。
`resolve-issue` がラベルからモード・ブランチ・タスク文を決め、`agent-regen` が lockfile / 生成物を作り直し、
`create-issue-pr` が作業ツリーの編集を 1 コミットにまとめて push し、構造化出力から PR を作る。

```yaml
- uses: omni-stove/.github/actions/create-issue-pr@main
  with:
    structured: ${{ steps.agent.outputs.structured-output }}
    branch: agent-fix/issue-${{ github.event.issue.number }}
    issue-number: ${{ github.event.issue.number }}
    labels: "prototype App:web"
    start-sha: ${{ steps.start.outputs.sha }}
    github-token: ${{ steps.app.outputs.token }}
# steps.pr.outputs.pr-url / pr-number
```

### `fetch-review-diff` / `post-review-comments` / `finalize-review`

`ci.yml` の Code Review が使う部品。自前のレビューワークフローを組むときにも使える。
`fetch-review-diff` が PR の diff と文脈を取得し、`post-review-comments` が構造化出力をインラインコメント付き
review として投稿し、`finalize-review` が lint / test の結果と指摘件数から approve / request-changes を提出する。

## 開発

```sh
make setup   # mise のツールと skill-kit を入れる
make lint    # shellcheck + actionlint
make test    # bats (install.bats と actions/*/*.bats)
```
