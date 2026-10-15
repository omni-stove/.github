#!/usr/bin/env bash
set -euo pipefail

ORG_REPO="${OMNI_STOVE_GITHUB_REPO:-omni-stove/.github}"
REF=""
REVIEW=""
PROVIDER=""
AUTO_MERGE=false
ISSUE_WORKER=false
FORCE=false
RULESET=false
LABELS=true

usage() {
	cat <<'USAGE'
usage: install.sh [options]

  初回は workflow を作り、2 回目以降は install.sh が作った workflow を最新の形に更新する。
  更新では with: の値と uses: の参照を既存から引き継ぎ、オプションで指定したものだけ変える。

  --review             Code Review (run-review: true) を有効にする
  --provider <name>    レビューの provider (claude | codex)。既定: claude
  --auto-merge         auto-merge.yml も入れる (既にあれば指定しなくても更新する)
  --issue-worker       issue-worker.yml (Issue にラベルを付けるとエージェントが PR を作る) も入れる (既にあれば指定しなくても更新する)
  --ruleset            既定ブランチに "ci / CI Gate" を必須チェックにする ruleset を作る (gh が必要)
  --ref <ref>          omni-stove/.github の参照 (既定: 既存 workflow の参照、無ければ main)
  --force              既存の設定を引き継がず検出結果から書き直す (install.sh 以外が作ったファイルも上書きする)
  --no-labels          hotfix / revert ラベルを作らない
  -h, --help           このヘルプ
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--review) REVIEW=true; shift ;;
		--provider) PROVIDER="${2:?--provider には claude か codex を指定する}"; shift 2 ;;
		--auto-merge) AUTO_MERGE=true; shift ;;
		--issue-worker) ISSUE_WORKER=true; shift ;;
		--ruleset) RULESET=true; shift ;;
		--ref) REF="${2:?--ref には参照を指定する}"; shift 2 ;;
		--force) FORCE=true; shift ;;
		--no-labels) LABELS=false; shift ;;
		-h | --help) usage; exit 0 ;;
		*) echo "install: unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

check_provider() {
	case "$1" in
		claude | codex) ;;
		*) echo "install: --provider は claude か codex (got: $1)" >&2; exit 2 ;;
	esac
}
[ -z "$PROVIDER" ] || check_provider "$PROVIDER"

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

is_ours() { grep -q "^    uses: ${ORG_REPO}/.github/workflows/" "$1" 2>/dev/null; }

# The path when the file exists and install.sh generated it, so its settings carry over; nothing otherwise.
existing_ours() {
	if [ "$FORCE" != true ] && [ -e "$1" ] && is_ours "$1"; then echo "$1"; fi
}

existing_ref() { sed -n -E "s#^    uses: ${ORG_REPO}/.github/workflows/[^@]+@(.+)\$#\1#p" "$1" | head -n1; }

# What a generated workflow writes after "key:" in its with: block, as written; fails when the key is absent.
with_value() {
	awk -v key="$2" '
		/^    with:[[:space:]]*$/ { inw = 1; next }
		inw && /^    [^[:space:]]/ { inw = 0 }
		inw && index($0, "      " key ":") == 1 { sub("^      " key ":[[:space:]]*", ""); print; found = 1; exit }
		END { exit found ? 0 : 1 }' "$1"
}

# with: lines of a generated workflow whose keys are not in the space-separated list, e.g. an install-filter the repo added.
with_extra() {
	awk -v known=" $2 " '
		/^    with:[[:space:]]*$/ { inw = 1; next }
		inw && /^    [^[:space:]]/ { inw = 0 }
		inw && match($0, /^      [A-Za-z0-9_-]+:/) { if (index(known, " " substr($0, 7, RLENGTH - 7) " ") == 0) print }' "$1"
}

# The value to write for a with: key: the existing file's, else the default.
pick() {
	local v=""
	[ -z "$1" ] || v="$(with_value "$1" "$2" || true)"
	printf '%s' "${v:-$3}"
}

# The bare value of a with: entry, without quotes or a trailing comment.
scalar() {
	local s="${1%%#*}"
	s="${s%"${s##*[![:space:]]}"}"
	s="${s#[\"\']}"
	s="${s%[\"\']}"
	printf '%s' "$s"
}

# The with: block from key=value arguments (an empty value drops the key), then the existing file's other keys as written.
with_block() {
	local file="$1" keys="" arg
	shift
	for arg in "$@"; do
		keys="$keys ${arg%%=*}"
		[ -z "${arg#*=}" ] || printf '      %s: %s\n' "${arg%%=*}" "${arg#*=}"
	done
	[ -z "$file" ] || with_extra "$file" "$keys"
}

EXISTING_CI="$(existing_ours .github/workflows/ci.yml)"
EXISTING_HOTFIX="$(existing_ours .github/workflows/hotfix-revert-approve.yml)"
EXISTING_AUTO_MERGE="$(existing_ours .github/workflows/auto-merge.yml)"
EXISTING_ISSUE_WORKER="$(existing_ours .github/workflows/issue-worker.yml)"
[ ! -e .github/workflows/auto-merge.yml ] || AUTO_MERGE=true
[ ! -e .github/workflows/issue-worker.yml ] || ISSUE_WORKER=true

if [ -z "$REF" ]; then
	for f in "$EXISTING_CI" "$EXISTING_HOTFIX" "$EXISTING_AUTO_MERGE" "$EXISTING_ISSUE_WORKER"; do
		[ -n "$f" ] || continue
		REF="$(existing_ref "$f")"
		[ -z "$REF" ] || break
	done
fi
REF="${REF:-main}"
[ -z "$EXISTING_CI" ] || say update "$EXISTING_CI の with: と参照 (@$REF) を引き継ぐ (--force で検出し直す)"

[ -n "$REVIEW" ] || REVIEW="$(scalar "$(pick "$EXISTING_CI" run-review false)")"
[ -n "$PROVIDER" ] || PROVIDER="$(scalar "$(pick "$EXISTING_CI" review-provider "")")"
[ -n "$PROVIDER" ] || PROVIDER="$(scalar "$(pick "$EXISTING_ISSUE_WORKER" provider claude)")"
check_provider "$PROVIDER"

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
NODE_VERSION_VALUE="$(pick "$EXISTING_CI" node-version "")"
[ -n "$NODE_VERSION_VALUE" ] || NODE_VERSION_VALUE="\"$(node_version)\""
NODE_VERSION="$(scalar "$NODE_VERSION_VALUE")"

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

skip_command() { printf "'echo \"skip: no %s script\"'" "$1"; }

# The existing command carries over unless it is the skip placeholder, which is detected again so that
# adding the script and re-running install.sh turns it into the real command.
command_value() {
	local v
	v="$(pick "$EXISTING_CI" "$1-command" "")"
	if [ -n "$v" ] && [ "$v" != "$(skip_command "$1")" ]; then
		printf '%s' "$v"
	elif has_script "$1"; then
		printf "'pnpm %s'" "$1"
	else
		skip_command "$1"
	fi
}
LINT_COMMAND="$(command_value lint)"
TYPECHECK_COMMAND="$(command_value typecheck)"
TEST_COMMAND="$(pick "$EXISTING_CI" test-command "'pnpm test'")"
RUN_TEST="$(scalar "$(pick "$EXISTING_CI" run-test false)")"
if [ "$RUN_TEST" != true ]; then
	has_script test && RUN_TEST=true || RUN_TEST=false
fi
[ "$LINT_COMMAND" != "$(skip_command lint)" ] || todo "package.json に lint script が無い。追加して install.sh を再実行する (ci.yml の lint-command が pnpm lint になる)"
[ "$TYPECHECK_COMMAND" != "$(skip_command typecheck)" ] || todo "package.json に typecheck script が無い。追加して install.sh を再実行する (ci.yml の typecheck-command が pnpm typecheck になる)"
[ "$RUN_TEST" = true ] || todo "package.json に test script が無い。追加して install.sh を再実行する (ci.yml の run-test が true になる)"

say detect "default-branch=$DEFAULT_BRANCH node=$NODE_VERSION lint=$LINT_COMMAND typecheck=$TYPECHECK_COMMAND test=$TEST_COMMAND run-test=$RUN_TEST"

ALLOWED_BOTS="$(pick "$EXISTING_CI" review-allowed-bots "")"
if [ -z "$ALLOWED_BOTS" ] && [ "$VISIBILITY" = "PUBLIC" ]; then
	ALLOWED_BOTS='""  # 公開リポジトリでは外部 App の PR でもレビューが起動してしまうため'
fi

WORKER_ALLOWED_BOTS="$(pick "$EXISTING_ISSUE_WORKER" allowed-bots "")"
if [ -z "$WORKER_ALLOWED_BOTS" ] && [ "$VISIBILITY" = "PUBLIC" ]; then
	WORKER_ALLOWED_BOTS='""  # 公開リポジトリでは外部 App が付けたラベルでも起動してしまうため'
fi
# The agent edits without installing, so a pnpm repo regenerates its lockfile before the PR is opened.
REGEN_COMMAND="$(pick "$EXISTING_ISSUE_WORKER" regen-command "")"
if [ -z "$REGEN_COMMAND" ] && [ -f pnpm-lock.yaml ]; then
	REGEN_COMMAND="'pnpm install --lockfile-only --no-frozen-lockfile'"
fi

write_file() {
	local path="$1" content verb=created
	content="$(cat)"
	if [ -e "$path" ]; then
		if [ "$FORCE" = true ]; then
			verb=overwritten
		elif is_ours "$path"; then
			[ "$content" != "$(cat "$path")" ] || { say unchanged "$path"; return 0; }
			verb=updated
		else
			say kept "$path (install.sh が作ったものではない。--force で上書き)"
			return 0
		fi
	fi
	mkdir -p "$(dirname "$path")"
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
$(with_block "$EXISTING_CI" \
	"node-version=${NODE_VERSION_VALUE}" \
	"lint-command=${LINT_COMMAND}" \
	"typecheck-command=${TYPECHECK_COMMAND}" \
	"test-command=${TEST_COMMAND}" \
	"run-test=${RUN_TEST}" \
	"run-review=${REVIEW}" \
	"review-provider=\"${PROVIDER}\"" \
	"review-allowed-bots=${ALLOWED_BOTS}")
    secrets: inherit
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
$(with_block "$EXISTING_HOTFIX" 'ci-workflow="ci.yml"')
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

if [ "$ISSUE_WORKER" = true ]; then
	write_file .github/workflows/issue-worker.yml <<EOF
name: Issue Worker

on:
  issues:
    types: [labeled]

jobs:
  work:
    uses: ${ORG_REPO}/.github/workflows/issue-worker.yml@${REF}
    permissions:
      contents: write
      pull-requests: write
      issues: write
      id-token: write
    with:
$(with_block "$EXISTING_ISSUE_WORKER" \
	"provider=\"${PROVIDER}\"" \
	"regen-command=${REGEN_COMMAND}" \
	"allowed-bots=${WORKER_ALLOWED_BOTS}")
    secrets: inherit
EOF
fi

create_label() {
	gh label create "$1" --color "$2" --description "$3" --force >/dev/null 2>&1 && say label "$1" || say warning "ラベル $1 を作れなかった"
}

if [ "$LABELS" = true ]; then
	if [ "$GH_OK" = true ]; then
		create_label hotfix b60205 "緊急避難口: CI を止めて approve する"
		create_label revert 5319e7 "緊急避難口: CI を止めて approve する"
		if [ "$ISSUE_WORKER" = true ]; then
			create_label prototype fbca04 "Issue Worker: モックで良い試作を draft PR にする"
			create_label implementation 0e8a16 "Issue Worker: 本実装の PR を作る"
			create_label security e11d21 "Issue Worker: 指摘箇所だけ直す修正 PR を作る"
		fi
	else
		todo "gh auth login してから: gh label create hotfix --color b60205 && gh label create revert --color 5319e7"
		[ "$ISSUE_WORKER" != true ] || todo "gh auth login してから: gh label create prototype --color fbca04 && gh label create implementation --color 0e8a16 && gh label create security --color e11d21"
	fi
fi

if [ "$GH_OK" = true ]; then
	owner="${REPO%%/*}"
	secrets="$( { gh secret list --json name -q '.[].name' 2>/dev/null; gh secret list --org "$owner" --json name -q '.[].name' 2>/dev/null; } | sort -u || true)"
	has_secret() { printf '%s\n' "$secrets" | grep -qx "$1"; }
	if [ "$REVIEW" = true ] || [ "$ISSUE_WORKER" = true ]; then
		if [ "$PROVIDER" = codex ]; then
			has_secret OPENAI_API_KEY && say secret "OPENAI_API_KEY" || todo "gh secret set OPENAI_API_KEY (organization secret でもよい)"
		else
			{ has_secret CLAUDE_CODE_OAUTH_TOKEN || has_secret ANTHROPIC_API_KEY; } && say secret "CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY" \
				|| todo "gh secret set CLAUDE_CODE_OAUTH_TOKEN (または ANTHROPIC_API_KEY。organization secret でもよい)"
		fi
	fi
	if [ "$REVIEW" = true ]; then
		{ has_secret REVIEWER_GH_APP_ID && has_secret REVIEWER_GH_APP_PRIVATE_KEY; } && say secret "REVIEWER_GH_APP_ID / REVIEWER_GH_APP_PRIVATE_KEY" \
			|| todo "reviewer 用 GitHub App の REVIEWER_GH_APP_ID / REVIEWER_GH_APP_PRIVATE_KEY を secrets に置く (無いと bot の PR に approve できない): https://github.com/${ORG_REPO}#github-app-の設定-ci-gate-用"
	fi
	if [ "$ISSUE_WORKER" = true ]; then
		{ has_secret AGENT_GH_APP_ID && has_secret AGENT_GH_APP_PRIVATE_KEY; } && say secret "AGENT_GH_APP_ID / AGENT_GH_APP_PRIVATE_KEY" \
			|| todo "PR を作る agent 用 GitHub App (reviewer とは別) の AGENT_GH_APP_ID / AGENT_GH_APP_PRIVATE_KEY を secrets に置く (無いと Issue Worker の PR で CI が起動しない): https://github.com/${ORG_REPO}#pr-を作る-agent-用の-app"
	fi
else
	[ "$REVIEW" != true ] || todo "secrets を置く: CLAUDE_CODE_OAUTH_TOKEN (または ANTHROPIC_API_KEY / OPENAI_API_KEY), REVIEWER_GH_APP_ID, REVIEWER_GH_APP_PRIVATE_KEY"
	[ "$ISSUE_WORKER" != true ] || todo "secrets を置く: CLAUDE_CODE_OAUTH_TOKEN (または ANTHROPIC_API_KEY / OPENAI_API_KEY), AGENT_GH_APP_ID, AGENT_GH_APP_PRIVATE_KEY"
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

for t in "${todos[@]}"; do say todo "$t"; done
