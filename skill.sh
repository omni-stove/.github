#!/usr/bin/env bash
set -euo pipefail

ORG_REPO="${OMNI_STOVE_GITHUB_REPO:-omni-stove/.github}"
REF=""
FROM=""

usage() {
	cat <<'USAGE'
usage: skill.sh [options]

  LLM が利用側リポジトリで実行する。この repo の事実 (ツールチェーン・scripts・tasks・既存 workflow・
  ラベル・secrets・ruleset) と、omni-stove/.github の README・composite action・reusable workflow の
  インターフェースを並べ、最後にこの repo に合う workflow を書くための判断を出す。ファイルは書かない。

  --ref <ref>     omni-stove/.github の参照 (既定: 既存 workflow の参照、無ければ main)
  --from <dir>    omni-stove/.github を GitHub から取らず、このディレクトリの checkout を読む
  -h, --help      このヘルプ
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--ref) REF="${2:?--ref には参照を指定する}"; shift 2 ;;
		--from) FROM="${2:?--from にはディレクトリを指定する}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) echo "skill: unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done
[ -z "$FROM" ] || FROM="$(cd "$FROM" 2>/dev/null && pwd)" || { echo "skill: --from のディレクトリが無い" >&2; exit 2; }

say() { printf '%s\t%s\n' "$1" "$2"; }
section() { printf '\n==> %s\n' "$1"; }
join_lines() { tr '\n' ' ' | sed 's/^ *//; s/ *$//'; }

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "skill: git リポジトリの中で実行してください" >&2; exit 1; }
cd "$root"

GH_AUTH=false
GH_REPO=""
VISIBILITY=""
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
	GH_AUTH=true
	if GH_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" && [ -n "$GH_REPO" ]; then
		VISIBILITY="$(gh repo view --json visibility -q .visibility 2>/dev/null || true)"
	fi
fi

DEFAULT_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
if [ -z "$DEFAULT_BRANCH" ] && [ -n "$GH_REPO" ]; then
	DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
fi
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

if [ -z "$REF" ]; then
	REF="$(grep -rhoE "${ORG_REPO}/[^@[:space:]]+@[^[:space:]\"']+" .github/workflows 2>/dev/null | sed 's/.*@//' | head -n1 || true)"
fi
REF="${REF:-main}"

# The catalog stays on disk after the run so the reader can open any file whose interface is printed below.
if [ -n "$FROM" ]; then
	CATALOG="$FROM"
else
	CATALOG="$(mktemp -d "${TMPDIR:-/tmp}/omni-stove-github.XXXXXX" | sed 's#//*#/#g')"
	fetch_tarball() {
		if [ "$GH_AUTH" = true ]; then
			gh api "repos/${ORG_REPO}/tarball/${REF}"
		else
			curl -fsSL "https://api.github.com/repos/${ORG_REPO}/tarball/${REF}"
		fi
	}
	if ! fetch_tarball 2>/dev/null | tar -xzf - --strip-components=1 -C "$CATALOG" 2>/dev/null || [ ! -e "$CATALOG/README.md" ]; then
		echo "skill: ${ORG_REPO}@${REF} を取得できなかった (gh auth login するか、手元の checkout を --from <dir> で渡す)" >&2
		exit 1
	fi
fi

section "repo"
if [ -n "$GH_REPO" ]; then
	say repo "$GH_REPO ($VISIBILITY)"
else
	say repo "gh で見えない (ラベル / secrets / ruleset の状態は出せない)"
fi
say default-branch "$DEFAULT_BRANCH"
say ref "$REF"

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
	echo "24 (既定。mise.toml / .node-version に無い)"
}

if [ -f package.json ]; then
	pm=""
	for f in pnpm-lock.yaml package-lock.json yarn.lock bun.lock bun.lockb; do
		[ -f "$f" ] && pm="$pm $f"
	done
	if command -v jq >/dev/null 2>&1; then
		pm="$pm $(jq -r '.packageManager // empty' package.json)"
		say package-manager "$(printf '%s' "$pm" | join_lines | grep . || echo '(none)')"
		jq -r '.scripts // {} | to_entries[] | "script\t\(.key)\t\(.value)"' package.json
		ws="$(jq -r '.workspaces // [] | if type == "object" then .packages else . end | .[]' package.json | join_lines)"
	else
		say package-manager "$(printf '%s' "$pm" | join_lines | grep . || echo '(none)')"
		say scripts "jq が無い。package.json の scripts を直接読む"
		ws=""
	fi
	[ ! -f pnpm-workspace.yaml ] || ws="$ws $(sed -n -E 's/^[[:space:]]*-[[:space:]]*["'"'"']?([^"'"'"'#]+).*/\1/p' pnpm-workspace.yaml | join_lines)"
	[ -z "$(printf '%s' "$ws" | tr -d ' ')" ] || say workspaces "$(printf '%s' "$ws" | join_lines)"
	pkgs="$(find . -mindepth 2 -maxdepth 4 -name package.json -not -path '*/node_modules/*' 2>/dev/null | sed 's#^\./##; s#/package.json$##' | sort | join_lines)"
	[ -z "$pkgs" ] || say packages "$pkgs"
	say node "$(node_version)"
fi

for f in mise.toml .mise.toml .mise/config.toml; do
	[ -f "$f" ] || continue
	tools="$(awk '/^\[tools\]/ { t = 1; next } /^\[/ { t = 0 } t && NF && $1 !~ /^#/' "$f" | join_lines)"
	[ -z "$tools" ] || say tools "$tools"
	break
done

# Tasks of mise: every table in the task files, and only [tasks.<name>] tables in mise.toml.
list_tasks() {
	awk -v pre="$2" '
		/^\[[^]]+\]/ {
			s = substr($0, 2, length($0) - 2); name = ""
			if (s ~ /^task_config|^task_templates/) next
			if (pre == "" || index(s, pre) == 1) { name = substr(s, length(pre) + 1); names[++n] = name }
			next
		}
		name != "" && /^description[[:space:]]*=/ {
			sub(/^description[[:space:]]*=[[:space:]]*"?/, ""); sub(/"[[:space:]]*$/, ""); desc[name] = $0
		}
		END { for (i = 1; i <= n; i++) print "task\t" names[i] (desc[names[i]] != "" ? "\t" desc[names[i]] : "") }' "$1"
}
for f in mise.toml .mise.toml .mise/config.toml; do
	[ -f "$f" ] || continue
	list_tasks "$f" "tasks."
	break
done
for f in .mise/tasks.toml .mise/tasks/*.toml; do
	[ -f "$f" ] || continue
	list_tasks "$f" ""
done
if [ -f Makefile ]; then
	targets="$(grep -oE '^[A-Za-z][A-Za-z0-9_-]*:' Makefile | tr -d ':' | sort -u | join_lines)"
	[ -z "$targets" ] || say make-targets "$targets"
fi

markers=""
for f in Dockerfile compose.yaml compose.yml docker-compose.yml docker-compose.yaml \
	wrangler.toml wrangler.json wrangler.jsonc turbo.json nx.json lerna.json pnpm-workspace.yaml \
	biome.json biome.jsonc eslint.config.js eslint.config.mjs eslint.config.ts .eslintrc.json .eslintrc.cjs .prettierrc \
	tsconfig.json vitest.config.ts vitest.config.mts vitest.workspace.ts jest.config.js jest.config.ts \
	playwright.config.ts cypress.config.ts prisma/schema.prisma drizzle.config.ts supabase/config.toml \
	go.mod Cargo.toml pyproject.toml requirements.txt uv.lock Gemfile Package.swift deno.json deno.jsonc \
	.node-version .nvmrc .mise/tasks.toml Makefile .github/CODEOWNERS CODEOWNERS .github/dependabot.yml renovate.json .github/renovate.json \
	AGENTS.md CLAUDE.md; do
	[ -e "$f" ] && markers="$markers $f"
done
[ -z "$markers" ] || say markers "$(printf '%s' "$markers" | join_lines)"

found=false
for f in .github/workflows/*.yml .github/workflows/*.yaml; do
	[ -e "$f" ] || continue
	found=true
	say workflow "$f: $(grep -hE '^[[:space:]]*(-[[:space:]]*)?uses:' "$f" | sed -E 's/^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*//' | awk '!seen[$0]++' | join_lines || true)"
done
[ "$found" = true ] || say workflow "(none)"

if [ -n "$GH_REPO" ]; then
	labels="$(gh label list --limit 200 --json name -q '.[].name' 2>/dev/null || true)"
	say labels "$(printf '%s\n' "$labels" | join_lines | grep . || echo '(none)')"
	while IFS='|' read -r name color desc; do
		printf '%s\n' "$labels" | grep -qx "$name" || say label-create "gh label create $name --color $color --description \"$desc\" --force"
	done <<'LABELS'
hotfix|b60205|緊急避難口: CI を止めて approve する
revert|5319e7|緊急避難口: CI を止めて approve する
prototype|fbca04|Issue Worker: モックで良い試作を draft PR にする
implementation|0e8a16|Issue Worker: 本実装の PR を作る
security|e11d21|Issue Worker: 指摘箇所だけ直す修正 PR を作る
skip-autofix|c5def5|この PR ではレビュー指摘を自動修正しない (lint / test の修正は続ける)
force-autofix|c5def5|オプトアウトしていてもこの PR はレビュー指摘を自動修正する
LABELS

	owner="${GH_REPO%%/*}"
	secrets="$( { gh secret list --json name -q '.[].name' 2>/dev/null; gh secret list --org "$owner" --json name -q '.[].name' 2>/dev/null; } | sort -u || true)"
	has_secret() { printf '%s\n' "$secrets" | grep -qx "$1"; }
	say secrets "$(printf '%s\n' "$secrets" | join_lines | grep . || echo '(none)')"
	missing=""
	{ has_secret CLAUDE_CODE_OAUTH_TOKEN || has_secret ANTHROPIC_API_KEY; } || missing="$missing CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY"
	for s in OPENAI_API_KEY REVIEWER_GH_APP_ID REVIEWER_GH_APP_PRIVATE_KEY AGENT_GH_APP_ID AGENT_GH_APP_PRIVATE_KEY CLOUDFLARE_API_TOKEN; do
		has_secret "$s" || missing="$missing $s"
	done
	say secrets-missing "$(printf '%s' "$missing" | join_lines)"

	gh api "repos/$GH_REPO/rulesets" --jq '.[] | "\(.id)\t\(.name)"' 2>/dev/null | while IFS=$'\t' read -r id name; do
		[ -n "$id" ] || continue
		checks="$(gh api "repos/$GH_REPO/rulesets/$id" --jq '[.rules[]? | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] | join(", ")' 2>/dev/null || true)"
		say ruleset "$name: required checks: ${checks:-(none)}"
	done
	if protection="$(gh api "repos/$GH_REPO/branches/$DEFAULT_BRANCH/protection" --jq '.required_status_checks.contexts // [] | join(", ")' 2>/dev/null)"; then
		say branch-protection "$DEFAULT_BRANCH: required checks: ${protection:-(none)}"
	fi
fi

# One entry per action / reusable workflow: what it is for and the names of its inputs, outputs and secrets.
# The full interfaces stay in the catalog on disk, because printing them all overflows the reader's output limit.
# The summary is the first line of description:, or for a workflow, which has none, of its header comment, else its name.
summary() {
	awk -v stop="$2" '
		$0 ~ stop { exit }
		/^name:/ { title = $0; sub(/^name:[[:space:]]*/, "", title); next }
		/^#/ && desc == "" && !want { s = $0; sub(/^#[[:space:]]*/, "", s); if (s != "") desc = s; next }
		/^description:/ { s = $0; sub(/^description:[[:space:]]*/, "", s); if (s ~ /^[|>]/) want = 1; else desc = s; next }
		want && NF { s = $0; sub(/^[[:space:]]+/, "", s); desc = s; want = 0; next }
		match($0, /^[[:space:]]*(inputs|outputs|secrets):[[:space:]]*$/) {
			cur = $0; sub(/^[[:space:]]*/, "", cur); sub(/:.*/, "", cur)
			ind = match($0, /[^ ]/) - 1; next
		}
		cur != "" && NF && $0 !~ /^[[:space:]]*#/ {
			i = match($0, /[^ ]/) - 1
			if (i <= ind) cur = ""
			else if (i == ind + 2 && match($0, /^[[:space:]]*[A-Za-z0-9_-]+:/)) { k = $0; sub(/^[[:space:]]*/, "", k); sub(/:.*/, "", k); names[cur] = names[cur] " " k }
		}
		END {
			print "  " (desc != "" ? desc : title)
			for (j = 1; j <= 3; j++) { c = (j == 1 ? "inputs" : j == 2 ? "outputs" : "secrets"); if (names[c] != "") print "  " c ":" names[c] }
		}' "$1"
}

section "catalog ${ORG_REPO}@${REF}"
say catalog "$CATALOG"
say readme "$CATALOG/README.md (GitHub App / secrets / ラベル / ruleset の手順)"
for f in "$CATALOG"/actions/*/action.yml "$CATALOG"/actions/*/action.yaml; do
	[ -e "$f" ] || continue
	name="$(basename "$(dirname "$f")")"
	say action "${ORG_REPO}/actions/${name}@${REF}"
	summary "$f" '^runs:'
done
for f in "$CATALOG"/.github/workflows/*.yml "$CATALOG"/.github/workflows/*.yaml; do
	[ -e "$f" ] || continue
	grep -q 'workflow_call' "$f" || continue
	say workflow "${ORG_REPO}/.github/workflows/$(basename "$f")@${REF}"
	summary "$f" '^jobs:'
done

if [ "$GH_AUTH" = true ]; then
	INSTALL_CMD="gh api repos/${ORG_REPO}/contents/install.sh?ref=${REF} -H 'Accept: application/vnd.github.raw' | bash -s -- --ref ${REF}"
else
	INSTALL_CMD="curl -fsSL https://raw.githubusercontent.com/${ORG_REPO}/${REF}/install.sh | bash -s -- --ref ${REF}"
fi

section "next"
cat <<NEXT
上の repo の事実に合う workflow を .github/workflows/ に書く。部品は ${ORG_REPO}@${REF} の reusable workflow と
composite action。上の catalog は用途と入出力の名前だけなので、使うものは ${CATALOG} の yml を読む
(挙動・入力・出力・既定値は各 yml とそのヘッダーコメントが正)。GitHub App / secrets / ラベル / ruleset の手順は
${CATALOG}/README.md。reusable workflow の jobs: が composite action の並べ方の実例。

ci.yml の形は checks (reusable workflow の ci.yml: 前処理と review) → repo の lint / test ジョブ → CI Gate
(ci-gate.yml) で決まっていて、lint / test / build はどの repo でも呼び出し側のジョブとして書く (書き方は ci.yml の
ヘッダー)。repo のジョブは needs: checks と if: needs.checks.outputs.proceed == 'true' で緊急避難口とコンフリクトの
run を飛ばし、CI Gate の needs に全部並べる。
- まず install.sh で雛形を作る (pnpm の lint / typecheck / test ジョブ、ラベル / secrets 確認 / ruleset まで行う。
  オプションは --help)。
    ${INSTALL_CMD} --review --ruleset
  CI の失敗とレビュー指摘をエージェントに直させるなら --fix も付ける (agent App が要る)。
- 雛形の lint / test ジョブを repo に合わせて書き換え、足りないジョブ (services / container / 独自 runner /
  standalone の linter / 複数のツールチェーン) を足す。install.sh を再実行しても書き直すのは checks と CI Gate だけで、
  repo のジョブは残り、CI Gate の needs に入る。

どの形でも: 必須チェックは actions/ci-gate を呼ぶ job 1 つ ("<job 名> / CI Gate") に集約し、個別ジョブは登録しない。
hotfix-revert-approve.yml を並べる。concurrency で同じ PR の古い run を止める。permissions は job ごとに最小。
参照は @${REF} で揃える。secrets は inherit で渡す。
コマンドは上の script / task にあるものだけを使い、無いものは作らず利用者に返す。
Issue Worker / auto-merge / deploy は、この repo にその前提 (ラベル運用、wrangler 等) が見えるときだけ入れる。
自動修正を自前で組むなら、finalize 相当の job で actions/decide-fix を呼び、should-fix なら agent-fix.yml を呼ぶ。
どの形でも自動修正には呼び出し側の permissions の actions: read と agent App が要り、skip-autofix / force-autofix の
label-create はそのときだけ実行する。

書き終えたら actionlint があれば通す。利用者に渡すもの: secrets-missing のうち使う workflow が要るものと
GitHub App (README の手順)、label-create 行 (gh が使えるなら実行してよい)、
ruleset / branch protection の必須チェック "<job 名> / CI Gate" の登録 (job 名が ci なら install.sh --ruleset で作れる)。
NEXT
