#!/usr/bin/env bash
set -euo pipefail

ORG_REPO="${OMNI_STOVE_GITHUB_REPO:-omni-stove/.github}"
REF="main"
REVIEW=false
PROVIDER="claude"
AUTO_MERGE=false
FORCE=false
RULESET=false
LABELS=true

usage() {
	cat <<'USAGE'
usage: install.sh [options]

  --review             Code Review (run-review: true) を有効にする
  --provider <name>    レビューの provider (claude | codex)。既定: claude
  --auto-merge         auto-merge.yml も入れる
  --ruleset            既定ブランチに "ci / CI Gate" を必須チェックにする ruleset を作る (gh が必要)
  --ref <ref>          omni-stove/.github の参照 (既定: main)
  --force              既存の workflow ファイルを上書きする
  --no-labels          hotfix / revert ラベルを作らない
  -h, --help           このヘルプ
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--review) REVIEW=true; shift ;;
		--provider) PROVIDER="${2:?--provider には claude か codex を指定する}"; shift 2 ;;
		--auto-merge) AUTO_MERGE=true; shift ;;
		--ruleset) RULESET=true; shift ;;
		--ref) REF="${2:?--ref には参照を指定する}"; shift 2 ;;
		--force) FORCE=true; shift ;;
		--no-labels) LABELS=false; shift ;;
		-h | --help) usage; exit 0 ;;
		*) echo "install: unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

case "$PROVIDER" in
	claude | codex) ;;
	*) echo "install: --provider は claude か codex (got: $PROVIDER)" >&2; exit 2 ;;
esac

say() { printf '%s\t%s\n' "$1" "$2"; }
todos=()
todo() { todos+=("$1"); }

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "install: git リポジトリの中で実行してください" >&2; exit 1; }
cd "$root"

GH_OK=false
REPO=""
VISIBILITY=""
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
	if REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" && [ -n "$REPO" ]; then
		GH_OK=true
		VISIBILITY="$(gh repo view --json visibility -q .visibility 2>/dev/null || true)"
	fi
fi
[ "$GH_OK" = true ] && say gh "$REPO ($VISIBILITY)" || say gh "not available (ラベル / secrets 確認 / ruleset はスキップ)"

DEFAULT_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
if [ -z "$DEFAULT_BRANCH" ] && [ "$GH_OK" = true ]; then
	DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
fi
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

node_version() {
	local v=""
	for f in mise.toml .mise.toml .mise/config.toml; do
		[ -f "$f" ] || continue
		v="$(sed -n -E 's/^[[:space:]]*node[[:space:]]*=[[:space:]]*(\{[^}]*version[[:space:]]*=[[:space:]]*)?"v?([0-9]+)[^"]*".*/\2/p' "$f" | head -n1)"
		[ -n "$v" ] && { echo "$v"; return; }
	done
	for f in .node-version .nvmrc; do
		[ -f "$f" ] || continue
		v="$(head -n1 "$f" | tr -d '[:space:]' | sed 's/^v//' | cut -d. -f1)"
		[[ "$v" =~ ^[0-9]+$ ]] && { echo "$v"; return; }
	done
	echo 24
}
NODE_VERSION="$(node_version)"

has_script() {
	[ -f package.json ] || return 1
	if command -v jq >/dev/null 2>&1; then
		jq -e --arg n "$1" '.scripts[$n] != null' package.json >/dev/null 2>&1
	else
		grep -Eq "^[[:space:]]*\"$1\"[[:space:]]*:" package.json
	fi
}

[ -f package.json ] || todo "package.json が無い。ci.yml の lint-command / typecheck-command / test-command を手で直す"
[ -f pnpm-lock.yaml ] || todo "pnpm-lock.yaml が無い。ci.yml は pnpm 前提 (setup-pnpm-node) なので pnpm に揃えるか workflow を書き換える"

LINT_COMMAND="pnpm lint"
TYPECHECK_COMMAND="pnpm typecheck"
TEST_COMMAND="pnpm test"
RUN_TEST=true
if ! has_script lint; then
	LINT_COMMAND='echo "skip: no lint script"'
	todo "package.json に lint script が無い。追加して ci.yml の lint-command を pnpm lint に戻す"
fi
if ! has_script typecheck; then
	TYPECHECK_COMMAND='echo "skip: no typecheck script"'
	todo "package.json に typecheck script が無い。追加して ci.yml の typecheck-command を pnpm typecheck に戻す"
fi
if ! has_script test; then
	RUN_TEST=false
	todo "package.json に test script が無い。追加して ci.yml の run-test を true に戻す"
fi

say detect "default-branch=$DEFAULT_BRANCH node=$NODE_VERSION lint='$LINT_COMMAND' typecheck='$TYPECHECK_COMMAND' test='$TEST_COMMAND' run-test=$RUN_TEST"

WITH_EXTRA=""
if [ "$VISIBILITY" = "PUBLIC" ]; then
	WITH_EXTRA='      review-allowed-bots: ""  # 公開リポジトリでは外部 App の PR でもレビューが起動してしまうため'$'\n'
fi

write_file() {
	local path="$1" content
	content="$(cat)"
	if [ -e "$path" ] && [ "$FORCE" != true ]; then
		say kept "$path (--force で上書き)"
		return 0
	fi
	mkdir -p "$(dirname "$path")"
	local verb=created
	[ -e "$path" ] && verb=overwritten
	printf '%s\n' "$content" > "$path"
	say "$verb" "$path"
}

write_file .github/workflows/ci.yml <<EOF
name: CI

on:
  push:
    branches: [${DEFAULT_BRANCH}]
  pull_request:

concurrency:
  group: ci-\${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
  ci:
    uses: ${ORG_REPO}/.github/workflows/ci.yml@${REF}
    permissions:
      contents: read
      pull-requests: write
      issues: write
      id-token: write
    with:
      node-version: "${NODE_VERSION}"
      lint-command: '${LINT_COMMAND}'
      typecheck-command: '${TYPECHECK_COMMAND}'
      test-command: '${TEST_COMMAND}'
      run-test: ${RUN_TEST}
      run-review: ${REVIEW}
      review-provider: "${PROVIDER}"
${WITH_EXTRA}    secrets: inherit
EOF

write_file .github/workflows/hotfix-revert-approve.yml <<EOF
name: Hotfix/Revert Approve

on:
  pull_request:
    types: [labeled, opened, reopened]

jobs:
  approve:
    uses: ${ORG_REPO}/.github/workflows/hotfix-revert-approve.yml@${REF}
    permissions:
      contents: read
      actions: write
      pull-requests: write
    with:
      ci-workflow: "ci.yml"
    secrets: inherit
EOF

if [ "$AUTO_MERGE" = true ]; then
	write_file .github/workflows/auto-merge.yml <<EOF
name: Auto Merge

on:
  pull_request_review:
    types: [submitted]

jobs:
  auto-merge:
    uses: ${ORG_REPO}/.github/workflows/auto-merge.yml@${REF}
    permissions:
      contents: write
      pull-requests: write
    secrets: inherit
EOF
fi

if [ "$LABELS" = true ]; then
	if [ "$GH_OK" = true ]; then
		gh label create hotfix --color b60205 --description "緊急避難口: CI を止めて approve する" --force >/dev/null 2>&1 && say label hotfix || say warning "ラベル hotfix を作れなかった"
		gh label create revert --color 5319e7 --description "緊急避難口: CI を止めて approve する" --force >/dev/null 2>&1 && say label revert || say warning "ラベル revert を作れなかった"
	else
		todo "gh auth login してから: gh label create hotfix --color b60205 && gh label create revert --color 5319e7"
	fi
fi

if [ "$GH_OK" = true ]; then
	owner="${REPO%%/*}"
	secrets="$( { gh secret list --json name -q '.[].name' 2>/dev/null; gh secret list --org "$owner" --json name -q '.[].name' 2>/dev/null; } | sort -u || true)"
	has_secret() { printf '%s\n' "$secrets" | grep -qx "$1"; }
	if [ "$REVIEW" = true ]; then
		if [ "$PROVIDER" = codex ]; then
			has_secret OPENAI_API_KEY && say secret "OPENAI_API_KEY" || todo "gh secret set OPENAI_API_KEY (organization secret でもよい)"
		else
			{ has_secret CLAUDE_CODE_OAUTH_TOKEN || has_secret ANTHROPIC_API_KEY; } && say secret "CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY" \
				|| todo "gh secret set CLAUDE_CODE_OAUTH_TOKEN (または ANTHROPIC_API_KEY。organization secret でもよい)"
		fi
		{ has_secret REVIEWER_GH_APP_ID && has_secret REVIEWER_GH_APP_PRIVATE_KEY; } && say secret "REVIEWER_GH_APP_ID / REVIEWER_GH_APP_PRIVATE_KEY" \
			|| todo "reviewer 用 GitHub App の REVIEWER_GH_APP_ID / REVIEWER_GH_APP_PRIVATE_KEY を secrets に置く (無いと bot の PR に approve できない): https://github.com/${ORG_REPO}#github-app-の設定-ci-gate-用"
	fi
elif [ "$REVIEW" = true ]; then
	todo "secrets を置く: CLAUDE_CODE_OAUTH_TOKEN (または ANTHROPIC_API_KEY / OPENAI_API_KEY), REVIEWER_GH_APP_ID, REVIEWER_GH_APP_PRIVATE_KEY"
fi

ruleset_done=false
if [ "$RULESET" = true ]; then
	if [ "$GH_OK" = true ]; then
		body="$(cat <<JSON
{
  "name": "CI Gate",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": [ { "context": "ci / CI Gate" } ] } }
  ]
}
JSON
)"
		existing="$(gh api "repos/$REPO/rulesets" --jq '.[] | select(.name == "CI Gate") | .id' 2>/dev/null | head -n1 || true)"
		if [ -n "$existing" ]; then
			if printf '%s' "$body" | gh api "repos/$REPO/rulesets/$existing" --method PUT --input - >/dev/null 2>&1; then
				say ruleset "updated \"CI Gate\" (#$existing): $DEFAULT_BRANCH に ci / CI Gate を必須"
				ruleset_done=true
			else
				say warning "ruleset #$existing を更新できなかった (admin 権限が要る)"
			fi
		else
			if printf '%s' "$body" | gh api "repos/$REPO/rulesets" --method POST --input - >/dev/null 2>&1; then
				say ruleset "created \"CI Gate\": $DEFAULT_BRANCH に ci / CI Gate を必須"
				ruleset_done=true
			else
				say warning "ruleset を作れなかった (admin 権限が要る)"
			fi
		fi
	else
		say warning "--ruleset は gh が必要"
	fi
fi
[ "$ruleset_done" = true ] || todo "ruleset / branch protection の必須チェックに \"ci / CI Gate\" だけを登録する (--ruleset で自動化できる)"

todo "git add .github/workflows && git commit -m 'ci: ${ORG_REPO} の CI Gate を導入'"
for t in "${todos[@]}"; do say todo "$t"; done
