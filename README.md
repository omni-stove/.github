# .github

omni-stove の共通 GitHub Actions (reusable workflow と composite action)。

各 workflow / action の挙動・入力・出力・secrets は、その yml とヘッダーコメントが正。
この README には、導入と GitHub 側の設定 (App / secrets / ラベル / ruleset) だけを書く。

## 導入

利用側リポジトリのルートで 1 行。CI Gate の呼び出し workflow (`ci.yml` / `hotfix-revert-approve.yml`) を書き、
ラベルを作り、secrets の有無を確認して、残りの手作業を `todo` として並べる。オプションは `--help` に出る。

```sh
curl -fsSL https://raw.githubusercontent.com/omni-stove/.github/main/install.sh | bash -s -- --review --ruleset
# private のときは gh 経由
gh api repos/omni-stove/.github/contents/install.sh -H 'Accept: application/vnd.github.raw' | bash -s -- --review --ruleset
```

共通側が持つのは CI Gate の仕組み (前処理・Code Review・集約・approve・自動修正) だけで、lint / test / build は
利用側の `ci.yml` に自分のジョブとして書く。reusable workflow はジョブを入力として受け取れないため。
install.sh が書く `ci.yml` は `checks` (共通 `ci.yml`) → `lint` / `test` (利用側のジョブ) → `ci` (共通 `ci-gate.yml`、
必須チェック `ci / CI Gate`) の形になる。

検出するもの: `mise.toml` (`node = "..."`) → Node.js バージョン、`package.json` の `lint` / `typecheck` / `test` script →
`lint` / `test` ジョブのコマンド (無ければ `echo "skip: ..."` にして `todo` を出す)、`origin/HEAD` または gh → 既定ブランチ、
リポジトリの公開/非公開 → 公開なら `review-allowed-bots: ""` / `allowed-bots: ""`。

2 回目以降は同じコマンドで更新になる。install.sh が作った workflow は最新のテンプレート (permissions や新しい input) に
書き直され、`with:` の値 (手で直した値や追加した input も、その上のコメントごと) と `uses:` の参照は既存のものを引き継ぐ。
`ci.yml` で書き直すのは共通側を呼ぶ `checks` と CI Gate のジョブだけで、`on:` などの冒頭と利用側のジョブには触らない
(足したジョブは CI Gate の `needs` に入る)。以前の形 (共通 `ci.yml` を呼ぶジョブ 1 つ) は、その `with:` のコマンドで
`lint` / `test` ジョブを作って今の形に移す。オプションで指定したものだけが上書きされ、`echo "skip: ..."` は検出し直す
(script を追加して再実行すれば本物のコマンドになる)。中身が同じなら `unchanged`、install.sh 以外が作ったファイルは `kept` で触らない。

依存は bash と git だけ。gh でログインしていればラベル / secrets 確認 / ruleset まで行い、無ければ `todo` に落とす。

### LLM に入れさせる

LLM (Claude Code 等) に導入させるときは install.sh ではなく skill.sh を実行させる。出力に判断材料と次にすることが全て出る。

```sh
gh api repos/omni-stove/.github/contents/skill.sh -H 'Accept: application/vnd.github.raw' | bash
```

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

`issue-worker.yml` など agent が PR を作る workflow と、`ci-gate.yml` の `run-fix` (自動修正) の push で
`github.token` の代わりに使う。App token で作った PR や push では `pull_request` イベントで CI が起動する
(`github.token` では起動しない)。

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
| `CLAUDE_CODE_OAUTH_TOKEN` または `ANTHROPIC_API_KEY` | `ci.yml` (`run-review`) / `ci-gate.yml` (`run-fix`) / `issue-worker.yml` / `claude-code.yml` の provider `claude` | Claude Code の認証 |
| `OPENAI_API_KEY` | 同上の provider `codex` | Codex の認証 |
| `REVIEWER_GH_APP_ID` / `REVIEWER_GH_APP_PRIVATE_KEY` | `ci.yml` / `ci-gate.yml` / `hotfix-revert-approve.yml` | reviewer App の App ID / PEM。無ければ `github.token` で投稿する |
| `AGENT_GH_APP_ID` / `AGENT_GH_APP_PRIVATE_KEY` | `issue-worker.yml` / `ci-gate.yml` (`run-fix`) / `auto-merge.yml` | agent App の App ID / PEM。issue-worker は無ければ `github.token` で PR を作る。自動修正は無ければ起動しない。auto-merge は無ければ `github.token` でマージし、closing keyword で Issue が閉じない |
| `CLOUDFLARE_API_TOKEN` | `deploy-cloudflare-worker.yml` | Cloudflare の API token |

### ラベルと必須チェック

install.sh が作る。手で作るときは次のとおり。

| ラベル | 使う workflow |
| --- | --- |
| `hotfix` / `revert` | `ci.yml` / `hotfix-revert-approve.yml` |
| `bug` / `security` / `prototype` / `implementation` | `issue-worker.yml` |
| `skip-autofix` / `force-autofix` | `ci-gate.yml` (`run-fix`) |

レビュー指摘の自動修正を自分の PR で止めたい人は、既定ブランチの `.github/autofix-opt-out.yml` に GitHub の
ユーザー名を書く (`users: [octocat, hubot]`)。lint / test の失敗の修正は止まらない。PR 1 件だけ止めるなら
`skip-autofix`、載っている人がその PR だけ任せるなら `force-autofix` を付ける。

ruleset / branch protection の必須チェックには `ci / CI Gate` (`ci` は呼び出し側の job 名) だけを登録する。
Lint / Test / Review の個別ジョブは登録しない (スキップ時に pending のまま残るため)。

## 開発

```sh
make setup   # mise のツールと skill-kit を入れる
make lint    # shellcheck + actionlint
make test    # bats (install.bats / skill.bats と actions/*/*.bats)
```
