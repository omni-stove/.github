#!/usr/bin/env bash
set -euo pipefail

ORG_REPO="${OMNI_STOVE_GITHUB_REPO:-omni-stove/.github}"
REF=""
REVIEW=""
FIX=""
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
  ci.yml で書き直すのは omni-stove/.github を呼ぶジョブ (checks と CI Gate) だけで、lint / test など
  リポジトリのジョブと on: などの冒頭には触らない。

  --review             Code Review (run-review: true) を有効にする
  --fix                lint / test の失敗とレビュー指摘の自動修正 (run-fix: true) を有効にし、skip-autofix / force-autofix ラベルを作る
  --provider <name>    レビューの provider (claude | codex)。既定: claude
  --auto-merge         auto-merge.yml も入れる (既にあれば指定しなくても更新する)
  --issue-worker       issue-worker.yml (Issue にラベルを付けるとエージェントが PR を作る) も入れ、prototype / implementation / security ラベルを作る (既にあれば指定しなくても更新する)
  --ruleset            既定ブランチに "ci / CI Gate" を必須チェックにする ruleset "CI Gate" を作る (同名があれば更新。gh と admin 権限が必要)
  --ref <ref>          omni-stove/.github の参照 (既定: 既存 workflow の参照、無ければ main)
  --force              既存の設定を引き継がず検出結果から書き直す (install.sh 以外が作ったファイルも上書きする)
  --no-labels          ラベルを作らない
  -h, --help           このヘルプ
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--review) REVIEW=true; shift ;;
		--fix) FIX=true; shift ;;
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

# The first match only: ci.yml calls two workflows, and head closing the pipe early would fail the run under pipefail.
existing_ref() { awk -v prefix="    uses: ${ORG_REPO}/.github/workflows/" 'index($0, prefix) == 1 && /@/ { sub(/^[^@]*@/, ""); print; exit }' "$1"; }

# What a generated workflow writes after "key:" in its with: block, as written; fails when the key is absent.
with_value() {
	awk -v key="$2" '
		/^    with:[[:space:]]*$/ { inw = 1; next }
		inw && /^    [^[:space:]]/ { inw = 0 }
		inw && index($0, "      " key ":") == 1 { sub("^      " key ":[[:space:]]*", ""); print; found = 1; exit }
		END { exit found ? 0 : 1 }' "$1"
}

# with: entries of a generated workflow whose keys are not in the space-separated list (and match the regex when one
# is given), e.g. a review-instructions the repo added, with the comment lines above them and multi-line values.
with_extra() {
	awk -v known=" $2 " -v include="${3:-}" '
		/^    with:[[:space:]]*$/ { inw = 1; next }
		inw && /^    [^[:space:]]/ { inw = 0 }
		!inw { next }
		/^      #/ { pending = pending $0 "\n"; next }
		match($0, /^      [A-Za-z0-9_-]+:/) {
			key = substr($0, 7, RLENGTH - 7)
			keep = index(known, " " key " ") == 0 && (include == "" || key ~ include)
			if (keep) printf "%s%s\n", pending, $0
			pending = ""
			next
		}
		/^       / { if (keep) print; next }
		{ pending = "" }' "$1"
}

# The comment lines a generated workflow writes just above "key:" in its with: block.
with_comment() {
	[ -n "$1" ] || return 0
	awk -v key="$2" '
		/^    with:[[:space:]]*$/ { inw = 1; next }
		inw && /^    [^[:space:]]/ { inw = 0 }
		!inw { next }
		/^      #/ { pending = pending $0 "\n"; next }
		index($0, "      " key ":") == 1 { printf "%s", pending; exit }
		{ pending = "" }' "$1"
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

# The with: block from key=value arguments (an empty value drops the key), then the existing file's other keys as
# written (only those matching the regex when one is given), each with the comment lines above it.
with_block() {
	local file="$1" include="$2" keys="" arg
	shift 2
	for arg in "$@"; do
		keys="$keys ${arg%%=*}"
		[ -n "${arg#*=}" ] || continue
		with_comment "$file" "${arg%%=*}"
		printf '      %s: %s\n' "${arg%%=*}" "${arg#*=}"
	done
	[ -z "$file" ] || with_extra "$file" "$keys" "$include"
}

# Splits a workflow into dir/header (up to "jobs:"), dir/order (the job names in order), dir/jobs/<name> (the job's
# lines) and dir/lead/<name> (the comment and blank lines just above the job).
split_jobs() {
	mkdir -p "$2/jobs" "$2/lead"
	: > "$2/header"
	: > "$2/order"
	awk -v dir="$2" '
		!injobs { print > (dir "/header"); if ($0 ~ /^jobs:[[:space:]]*$/) injobs = 1; next }
		/^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
			name = $0
			sub(/^  /, "", name)
			sub(/:.*/, "", name)
			print name >> (dir "/order")
			printf "%s", pending > (dir "/lead/" name)
			pending = ""
			cur = dir "/jobs/" name
			print > cur
			next
		}
		/^[[:space:]]*$/ || /^#/ || /^ #/ || /^  #/ { pending = pending $0 "\n"; next }
		cur != "" { printf "%s%s\n", pending, $0 > cur; pending = "" }
		END { if (cur != "" && pending != "") printf "%s", pending > cur }' "$1"
}

EXISTING_CI="$(existing_ours .github/workflows/ci.yml)"
# ci.yml splits its with: values between the job calling ci.yml (checks) and the one calling ci-gate.yml (CI Gate), so
# they are read per job. A ci.yml of the previous form, one job calling ci.yml that ran lint / test / gate itself, is
# read as LEGACY_CI and moved to the current form.
CI_SPLIT="$(mktemp -d)"
trap 'rm -rf "$CI_SPLIT"' EXIT
CHECKS_JOB=checks
GATE_JOB=ci
CHECKS_SRC=""
GATE_SRC=""
LEGACY_CI=""
if [ -n "$EXISTING_CI" ]; then
	split_jobs "$EXISTING_CI" "$CI_SPLIT"
	while IFS= read -r job; do
		if grep -q "^    uses: ${ORG_REPO}/.github/workflows/ci.yml@" "$CI_SPLIT/jobs/$job"; then
			CHECKS_JOB="$job"
			CHECKS_SRC="$CI_SPLIT/jobs/$job"
		elif grep -q "^    uses: ${ORG_REPO}/.github/workflows/ci-gate.yml@" "$CI_SPLIT/jobs/$job"; then
			GATE_JOB="$job"
			GATE_SRC="$CI_SPLIT/jobs/$job"
		fi
	done < "$CI_SPLIT/order"
	if [ -n "$CHECKS_SRC" ] && [ -z "$GATE_SRC" ]; then
		# The CI Gate job takes over the job name, which the required check "<job> / CI Gate" is named after.
		LEGACY_CI="$CHECKS_SRC"
		GATE_SRC="$CHECKS_SRC"
		GATE_JOB="$CHECKS_JOB"
		CHECKS_JOB=checks
	fi
fi
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
if [ -n "$LEGACY_CI" ]; then
	say update "$EXISTING_CI を checks / lint / test / CI Gate の形に移す。with: と参照 (@$REF) は引き継ぐ (--force で検出し直す)"
elif [ -n "$EXISTING_CI" ]; then
	say update "$EXISTING_CI の checks / CI Gate の with: と参照 (@$REF) を引き継ぎ、他のジョブは触らない (--force で検出し直す)"
fi

[ -n "$REVIEW" ] || REVIEW="$(scalar "$(pick "$CHECKS_SRC" run-review false)")"
[ -n "$FIX" ] || FIX="$(scalar "$(pick "$GATE_SRC" run-fix false)")"
[ -n "$PROVIDER" ] || PROVIDER="$(scalar "$(pick "$CHECKS_SRC" review-provider "")")"
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
NODE_VERSION_VALUE="$(pick "$GATE_SRC" node-version "")"
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

[ -f package.json ] || todo "package.json が無い。ci.yml の lint / test ジョブのコマンドを手で直す"
[ -f pnpm-lock.yaml ] || todo "pnpm-lock.yaml が無い。ci.yml は pnpm 前提 (setup-pnpm-node) なので pnpm に揃えるか workflow を書き換える"

skip_command() { printf "'echo \"skip: no %s script\"'" "$1"; }

# The command a job generated from the previous ci.yml form runs: its <name>-command unless that is the skip
# placeholder, which is detected again so that adding the script and re-running install.sh turns it into the real
# command. A test-command switched off by run-test: false is detected again too.
command_value() {
	local v=""
	if [ "$1" != test ] || [ "$(scalar "$(pick "$LEGACY_CI" run-test true)")" = true ]; then
		v="$(pick "$LEGACY_CI" "$1-command" "")"
	fi
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
TEST_COMMAND="$(command_value test)"

say detect "default-branch=$DEFAULT_BRANCH node=$NODE_VERSION lint=$LINT_COMMAND typecheck=$TYPECHECK_COMMAND test=$TEST_COMMAND"

if [ -n "$LEGACY_CI" ]; then
	for key in test-jobs install-filter run-lint; do
		! with_value "$LEGACY_CI" "$key" >/dev/null || todo "以前の ci.yml の $key は新しい形に無い。lint / test ジョブに手で移す"
	done
fi

ALLOWED_BOTS="$(pick "$CHECKS_SRC" review-allowed-bots "")"
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
FIX_REGEN_COMMAND=""
FIX_PROVIDER=""
if [ "$FIX" = true ]; then
	FIX_PROVIDER="$(pick "$GATE_SRC" fix-provider "\"${PROVIDER}\"")"
	FIX_REGEN_COMMAND="$(pick "$GATE_SRC" regen-command "")"
	if [ -z "$FIX_REGEN_COMMAND" ] && [ -f pnpm-lock.yaml ]; then
		FIX_REGEN_COMMAND="'pnpm install --lockfile-only --no-frozen-lockfile'"
	fi
fi
# The fix job reads the failed jobs' logs.
CI_ACTIONS_PERMISSION=""
[ "$FIX" != true ] || CI_ACTIONS_PERMISSION=$'\n      actions: read'

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

checks_job() {
	cat <<EOF
  ${CHECKS_JOB}:
    uses: ${ORG_REPO}/.github/workflows/ci.yml@${REF}
    permissions:
      contents: read
      pull-requests: write
      issues: write
      id-token: write
    with:
$(with_block "$CHECKS_SRC" '^review-' \
	"run-review=${REVIEW}" \
	"review-provider=\"${PROVIDER}\"" \
	"review-allowed-bots=${ALLOWED_BOTS}")
    secrets: inherit
EOF
}

# The CI Gate job, waiting for the space-separated jobs in $1.
gate_job() {
	cat <<EOF
  ${GATE_JOB}:
    needs: [${1// /, }]
    if: always()
    uses: ${ORG_REPO}/.github/workflows/ci-gate.yml@${REF}
    permissions:
      contents: read
      pull-requests: write
      issues: write
      id-token: write${CI_ACTIONS_PERMISSION}
    with:
$(with_block "$GATE_SRC" '^fix-' \
	"results=\${{ toJSON(needs) }}" \
	"conflicted=\${{ needs.${CHECKS_JOB}.outputs.conflicted }}" \
	"review-comments=\${{ needs.${CHECKS_JOB}.outputs.review-comments }}" \
	"review-result=\${{ needs.${CHECKS_JOB}.outputs.review-result }}" \
	"finalize=$([ "$REVIEW" = true ] || echo false)" \
	"run-fix=$([ "$FIX" = true ] && echo true)" \
	"fix-provider=${FIX_PROVIDER}" \
	"regen-command=${FIX_REGEN_COMMAND}" \
	"node-version=$([ "$FIX" = true ] && echo "$NODE_VERSION_VALUE")")
    secrets: inherit
EOF
}

# The repo's own lint / test jobs, written only when ci.yml is created or moved from the previous form.
repo_jobs() {
	cat <<EOF
  lint:
    needs: ${CHECKS_JOB}
    if: needs.${CHECKS_JOB}.outputs.proceed == 'true'
    runs-on: ubuntu-latest
    timeout-minutes: 15
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v6

      - name: Setup pnpm & Node.js
        uses: ${ORG_REPO}/actions/setup-pnpm-node@${REF}
        with:
          node-version: ${NODE_VERSION_VALUE}

      - name: Lint
        run: ${LINT_COMMAND}

      - name: Type check
        run: ${TYPECHECK_COMMAND}

  test:
    needs: ${CHECKS_JOB}
    if: needs.${CHECKS_JOB}.outputs.proceed == 'true'
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v6

      - name: Setup pnpm & Node.js
        uses: ${ORG_REPO}/actions/setup-pnpm-node@${REF}
        with:
          node-version: ${NODE_VERSION_VALUE}

      - name: Test
        run: ${TEST_COMMAND}
EOF
}

# A job of the repo as written, except that a skip placeholder whose script now exists becomes the real command.
repo_job() {
	local script content placeholder command
	content="$(cat "$1")"
	for script in lint typecheck test; do
		has_script "$script" || continue
		placeholder="run: $(skip_command "$script")"
		command="run: 'pnpm ${script}'"
		content="${content//"$placeholder"/$command}"
	done
	printf '%s\n' "$content"
}

ci_workflow() {
	local job lead needs="" first=true
	if [ -z "$EXISTING_CI" ]; then
		cat <<EOF
name: CI

on:
  push:
    branches: [${DEFAULT_BRANCH}]
  pull_request:

concurrency:
  group: ci-\${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
$(checks_job)

$(repo_jobs)

$(gate_job "${CHECKS_JOB} lint test")
EOF
		return
	fi
	while IFS= read -r job; do
		if [ "$job" = "$GATE_JOB" ] && [ -n "$LEGACY_CI" ]; then
			needs="$needs ${CHECKS_JOB} lint test"
		elif [ "$job" != "$GATE_JOB" ]; then
			needs="$needs $job"
		fi
	done < "$CI_SPLIT/order"
	cat "$CI_SPLIT/header"
	while IFS= read -r job; do
		[ "$first" = true ] || echo
		first=false
		lead="$(sed '/^[[:space:]]*$/d' "$CI_SPLIT/lead/$job")"
		[ -z "$lead" ] || printf '%s\n' "$lead"
		if [ "$job" = "$GATE_JOB" ] && [ -n "$LEGACY_CI" ]; then
			checks_job
			echo
			repo_jobs
			echo
			gate_job "${needs# }"
		elif [ "$job" = "$GATE_JOB" ]; then
			gate_job "${needs# }"
		elif [ "$job" = "$CHECKS_JOB" ]; then
			checks_job
		else
			repo_job "$CI_SPLIT/jobs/$job"
		fi
	done < "$CI_SPLIT/order"
}

CI_CONTENT="$(ci_workflow)"
printf '%s\n' "$CI_CONTENT" | write_file .github/workflows/ci.yml
for script in lint typecheck test; do
	[[ "$CI_CONTENT" != *"run: $(skip_command "$script")"* ]] \
		|| todo "package.json に $script script が無い。追加して install.sh を再実行する (ci.yml の run: $(skip_command "$script") が pnpm $script になる)"
done

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
$(with_block "$EXISTING_HOTFIX" "" 'ci-workflow="ci.yml"')
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
$(with_block "$EXISTING_ISSUE_WORKER" "" \
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
		if [ "$FIX" = true ]; then
			create_label skip-autofix c5def5 "この PR ではレビュー指摘を自動修正しない (lint / test の修正は続ける)"
			create_label force-autofix c5def5 "オプトアウトしていてもこの PR はレビュー指摘を自動修正する"
		fi
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
	if [ "$REVIEW" = true ] || [ "$ISSUE_WORKER" = true ] || [ "$FIX" = true ]; then
		if [ "$PROVIDER" = codex ]; then
			has_secret OPENAI_API_KEY && say secret "OPENAI_API_KEY" || todo "gh secret set OPENAI_API_KEY (organization secret でもよい)"
		else
			{ has_secret CLAUDE_CODE_OAUTH_TOKEN || has_secret ANTHROPIC_API_KEY; } && say secret "CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_API_KEY" \
				|| todo "gh secret set CLAUDE_CODE_OAUTH_TOKEN (または ANTHROPIC_API_KEY。organization secret でもよい)"
		fi
	fi
	if [ "$REVIEW" = true ]; then
		{ has_secret REVIEWER_GH_APP_ID && has_secret REVIEWER_GH_APP_PRIVATE_KEY; } && say secret "REVIEWER_GH_APP_ID / REVIEWER_GH_APP_PRIVATE_KEY" \
			|| todo "reviewer 用 GitHub App の REVIEWER_GH_APP_ID / REVIEWER_GH_APP_PRIVATE_KEY を secrets に置く (無いと bot の PR に approve できない): https://github.com/${ORG_REPO}#reviewer-app"
	fi
	if [ "$ISSUE_WORKER" = true ] || [ "$FIX" = true ]; then
		{ has_secret AGENT_GH_APP_ID && has_secret AGENT_GH_APP_PRIVATE_KEY; } && say secret "AGENT_GH_APP_ID / AGENT_GH_APP_PRIVATE_KEY" \
			|| todo "PR を作り自動修正を push する agent 用 GitHub App (reviewer とは別) の AGENT_GH_APP_ID / AGENT_GH_APP_PRIVATE_KEY を secrets に置く (無いと Issue Worker の PR で CI が起動せず、自動修正も動かない): https://github.com/${ORG_REPO}#agent-app"
	fi
else
	[ "$REVIEW" != true ] || todo "secrets を置く: CLAUDE_CODE_OAUTH_TOKEN (または ANTHROPIC_API_KEY / OPENAI_API_KEY), REVIEWER_GH_APP_ID, REVIEWER_GH_APP_PRIVATE_KEY"
	{ [ "$ISSUE_WORKER" != true ] && [ "$FIX" != true ]; } || todo "secrets を置く: CLAUDE_CODE_OAUTH_TOKEN (または ANTHROPIC_API_KEY / OPENAI_API_KEY), AGENT_GH_APP_ID, AGENT_GH_APP_PRIVATE_KEY"
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
