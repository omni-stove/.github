#!/usr/bin/env bash
# Issue Worker の起点となる Issue を読み、ラベルから実行モードと決定論で決まる値 (ブランチ名・
# draft・PR ラベル・編集スコープ・エージェントへのタスク文) を GITHUB_OUTPUT に書く。
# actions/resolve-issue から呼ばれる。
#
# モードはラベル名で決める:
#   bug            → fix          (agent-fix/issue-<n>)
#   security       → security-fix (agent-security-fix/issue-<n>、PR に security ラベル)
#   prototype      → proto        (agent-proto/issue-<n>、draft PR、PR に prototype ラベル)
#   implementation → implement    (agent-implement/issue-<n>)
# それ以外のラベル、ALLOWED_USERS に無いユーザーが付けたラベル、閉じた Issue、prototype ラベルも
# 付いた implementation は mode を空にして skip_reason を書く。
#
# 入力 (環境変数):
#   ISSUE_NUMBER       - 対象 Issue 番号
#   LABEL              - 今回付いたラベル名
#   SCOPE_LABEL_PREFIX - 編集スコープを表すラベルの接頭辞 (例: "App:")。空なら無効
#   SCOPE_DIR          - スコープのディレクトリ (例: "apps")。ラベル App:web → apps/web
#   SENDER             - ラベルを付けたユーザーの login
#   ALLOWED_USERS      - 起動を許すユーザーの login (カンマ区切り、大文字小文字は区別しない)。空なら誰でも
#   GH_TOKEN           - gh 認証用
#   GH_CMD             - テストで gh を差し替える (既定: gh)
#   GITHUB_OUTPUT      - 出力先
# 出力 (GITHUB_OUTPUT):
#   mode / skip_reason / number / title / body / url / branch / draft / pr_labels /
#   scope_dir / scope_label / task
set -euo pipefail

: "${ISSUE_NUMBER:?ISSUE_NUMBER is required}"
: "${LABEL:?LABEL is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

GH_CMD="${GH_CMD:-gh}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

output() {
  local name="$1" value="$2" delimiter
  if [[ "$value" != *$'\n'* ]]; then
    printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
    return
  fi
  delimiter="RESOLVE_ISSUE_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')_$(openssl rand -hex 16)"
  printf '%s<<%s\n%s\n%s\n' "$name" "$delimiter" "$value" "$delimiter" >> "$GITHUB_OUTPUT"
}

skip() {
  echo "skip: $1" >&2
  output mode ""
  output skip_reason "$1"
  exit 0
}

mode=""
branch_prefix=""
draft=false
pr_labels=""
case "$LABEL" in
  bug) mode=fix; branch_prefix=agent-fix ;;
  security) mode=security-fix; branch_prefix=agent-security-fix; pr_labels=security ;;
  prototype) mode=proto; branch_prefix=agent-proto; draft=true; pr_labels=prototype ;;
  implementation) mode=implement; branch_prefix=agent-implement ;;
  *) skip "label '${LABEL}' does not start a worker" ;;
esac

if [ -n "${ALLOWED_USERS:-}" ]; then
  # GitHub の login は大文字小文字を区別しない。
  sender="$(tr '[:upper:]' '[:lower:]' <<<"${SENDER:-}")"
  allowed="$(tr '[:upper:]' '[:lower:]' <<<"$ALLOWED_USERS" | tr ',' '\n' | tr -d ' \t')"
  if [ -z "$sender" ] || ! grep -qxF -- "$sender" <<<"$allowed"; then
    skip "label '${LABEL}' was added by '${SENDER:-}', who is not in allowed-users"
  fi
fi

issue="$("$GH_CMD" issue view "$ISSUE_NUMBER" --json number,title,body,url,state,labels)"
state="$(jq -r '.state' <<<"$issue")"
[ "$state" = "OPEN" ] || skip "issue #${ISSUE_NUMBER} is ${state}"

labels="$(jq -r '.labels[].name' <<<"$issue")"
# prototype の draft PR と本実装の PR が同じ Issue から同時に出ると、どちらを見るべきか決められない。
if [ "$mode" = implement ] && grep -qxF prototype <<<"$labels"; then
  skip "issue #${ISSUE_NUMBER} also carries the prototype label"
fi

scope_dir=""
scope_label=""
if [ -n "${SCOPE_LABEL_PREFIX:-}" ]; then
  while IFS= read -r label; do
    case "$label" in
      "$SCOPE_LABEL_PREFIX"?*) scope_label="$label"; break ;;
    esac
  done <<<"$labels"
  if [ -n "$scope_label" ]; then
    scope_dir="${scope_label#"$SCOPE_LABEL_PREFIX"}"
    [ -z "${SCOPE_DIR:-}" ] || scope_dir="${SCOPE_DIR%/}/${scope_dir}"
  fi
fi

title="$(jq -r '.title' <<<"$issue")"
body="$(jq -r '.body // ""' <<<"$issue")"
task="$(cat "${SELF_DIR}/prompts/${mode}.md")"
task="${task//\{ISSUE\}/$ISSUE_NUMBER}"
task="${task//\{TITLE\}/$title}"
task="${task//\{BODY\}/$body}"
if [ -n "$scope_dir" ]; then
  task="${task}"$'\n\n'"Scope edits to \`${scope_dir}\`."
fi

output mode "$mode"
output skip_reason ""
output number "$ISSUE_NUMBER"
output title "$title"
output body "$body"
output url "$(jq -r '.url' <<<"$issue")"
output branch "${branch_prefix}/issue-${ISSUE_NUMBER}"
output draft "$draft"
output pr_labels "$pr_labels"
output scope_dir "$scope_dir"
output scope_label "$scope_label"
output task "$task"
