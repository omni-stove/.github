#!/usr/bin/env bash
# CI の作業ツリーにある変更を 1 コミットにまとめ、ブランチへ push して PR を作る。
# 文面 (コミットメッセージ・title・body) は呼び出し側が決めて渡す。最終行に PR の URL を stdout へ出す。
#
# 引数: $1 = branch 名, $2 = base ブランチ, $3 = コミットメッセージ, $4 = title, $5 = body
# オプション (任意・末尾に何度でも):
#   --label <name>  PR に付けるラベル。複数回指定可。無いラベルは警告して飛ばす
#   --draft         ドラフト PR として作成する
#
# push 前に最新の base へ rebase する。rebase がコンフリクトしたら中断し、rebase せずに push する。
# 同じブランチが remote に先行していれば (同じ Issue の再実行) マージしてから push し、その
# ブランチの open PR が既にあれば作らずにその URL を返す。マージがコンフリクトしたら exit 3。
#
# 環境変数:
#   GIT_USER_NAME / GIT_USER_EMAIL - git identity が未設定のときに使う
#   GH_TOKEN                       - gh 認証用
set -euo pipefail

if [[ $# -lt 5 ]]; then
  echo "usage: create-pr.sh <branch> <base> <message> <title> <body> [--label <name>]... [--draft]" >&2
  exit 2
fi

branch="$1"
base="$2"
message="$3"
title="$4"
body="$5"
shift 5

labels=()
create_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)
      labels+=("$2")
      shift 2
      ;;
    --draft)
      create_args+=(--draft)
      shift
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# CI runner には git identity が無い。ローカル実行のユーザー設定は上書きしない。
if ! git config user.email >/dev/null; then
  git config user.name "${GIT_USER_NAME:-github-actions[bot]}"
  git config user.email "${GIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
fi

if [ "$(git branch --show-current)" != "$branch" ]; then
  git checkout -B "$branch"
fi

# git diff --quiet は untracked を見ないため、新規ファイルのみの差分を取りこぼす。
if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit --no-verify -m "$message"
fi

# エージェントの実行中に base が進んでいると、PR が古い base の上に乗って CI が最新の base と
# 噛み合わない。ブランチは base から切った直線の履歴なので、rebase してもマージコミットを平坦化しない。
# コンフリクトは人間が PR 上で解くほうが確実なので、PR を作らずに終えることはしない。
if git fetch origin "$base"; then
  if ! git rebase FETCH_HEAD; then
    git rebase --abort || echo "::warning::rebase --abort failed; the repository may be left mid-rebase." >&2
    echo "::warning::rebase onto the latest ${base} conflicted; pushing without rebasing." >&2
  fi
else
  echo "::warning::fetching ${base} failed; pushing without rebasing." >&2
fi

# 同じ Issue の再実行では remote にブランチが残っている。non-fast-forward なら remote 側を
# マージして push する。rebase にしないのは、ブランチに base のマージコミットが含まれていると
# rebase がそれを平坦化して base のコミットを複製するため。
# push の失敗種別はメッセージで判定するため、翻訳されないよう LC_ALL=C で固定する。
pushed=true
push_out="$(LC_ALL=C git push -u origin "$branch" 2>&1)" || pushed=false
[ -z "$push_out" ] || printf '%s\n' "$push_out" >&2
if [ "$pushed" = false ]; then
  grep -qE 'non-fast-forward|fetch first|tip of your current branch is behind' <<<"$push_out" || exit 1
  echo "==> push rejected (remote ahead); merging origin/${branch}" >&2
  git fetch origin "$branch"
  if ! git merge --no-edit FETCH_HEAD; then
    echo "==> merge conflict with origin/${branch}; resolve it by hand." >&2
    exit 3
  fi
  # CI のコードレビューは head がマージコミットの push をスキップし、レビュー結果を起点とする
  # 自動修正も走らなくなるため、空コミットを積んで head をマージコミットでなくする。
  if git rev-parse -q --verify 'HEAD^2' >/dev/null; then
    git commit --allow-empty --no-verify -m "chore: trigger code review after merge"
  fi
  git push -u origin "$branch"
fi

pr_url="$(gh pr list --head "$branch" --base "$base" --state open --json url --jq '.[0].url // empty')"
if [ -n "$pr_url" ]; then
  echo "==> PR already open for ${branch}; pushed onto it" >&2
else
  pr_url="$(gh pr create --base "$base" --head "$branch" --title "$title" --body "$body" ${create_args[@]+"${create_args[@]}"})"
fi

# gh pr create --label は無いラベルで PR 作成ごと失敗するため、作った後に 1 つずつ付ける。
for label in ${labels[@]+"${labels[@]}"}; do
  gh pr edit "$pr_url" --add-label "$label" >/dev/null \
    || echo "::warning::label '${label}' could not be added to ${pr_url}" >&2
done

echo "$pr_url"
