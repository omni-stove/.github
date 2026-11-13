#!/usr/bin/env bash
# 自動修正の前に PR の head へ base をマージし、コンフリクトしたらエージェントに解消させるための前後処理。
# actions/base-merge から呼ばれる。MODE=start でマージを始め、エージェントがマーカーを解消した後に
# MODE=finish でマージコミットを作る。push はしない (actions/push-agent-fix が merge-sha を受けて積む)。
#
# start はコンフリクトしたら全ファイルを stage した木を残し、マージの進行状態を捨てる (merge --quit)。
# エージェントの実行中に作業ツリーやインデックスが触られても、finish がこの木と MERGE_HEAD の SHA から
# マージコミットを組み立てられるようにするため。
# claude-code-action が base の内容で上書きする設定のパスがコンフリクトしたら、その上書きと解消を
# 区別できないので解消しない。
#
# 出力 (GITHUB_OUTPUT):
#   start:  result=clean | conflicted | unresolvable | failed
#           conflicted のとき base / base-sha / tree / files (コンフリクトしたパス。1 行 1 件)
#   finish: result=resolved | unresolved。resolved のとき merge-sha
#
# 入力 (環境変数):
#   MODE           - start | finish
#   BASE           - base ブランチ名 (空なら PR / REPO から引く)。checkout 済みの origin/BASE とマージする
#   PR / REPO      - base を引く PR
#   REF            - PR の head ブランチ名 (マージコミットの件名に使う)
#   BASE_SHA / TREE / FILES - finish 用。start の出力をそのまま渡す
#   GIT_USER_NAME / GIT_USER_EMAIL - マージコミットの author
#   GIT_CMD / GH_CMD - コマンド名 (既定: git / gh)
#   GITHUB_OUTPUT  - 出力先
set -euo pipefail

: "${MODE:?MODE is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

GIT_CMD="${GIT_CMD:-git}"
GH_CMD="${GH_CMD:-gh}"
GIT_USER_NAME="${GIT_USER_NAME:-github-actions[bot]}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"

# push-agent-fix.sh の RESTORED_CONFIG_PATHS と揃える。
RESTORED_CONFIG_PATHS=(.claude .mcp.json .claude.json .gitmodules .ripgreprc CLAUDE.md CLAUDE.local.md .husky)

finish() {
  echo "result=$1" >> "$GITHUB_OUTPUT"
  echo "$2"
  exit 0
}

is_restored_path() {
  local file="$1" path
  for path in "${RESTORED_CONFIG_PATHS[@]}"; do
    [ "$file" = "$path" ] || [[ "$file" == "$path"/* ]] && return 0
  done
  return 1
}

start() {
  BASE="${BASE:-}"
  if [ -z "$BASE" ] && [ -n "${PR:-}" ] && [ -n "${REPO:-}" ]; then
    BASE="$("${GH_CMD}" pr view "$PR" --repo "$REPO" --json baseRefName --jq '.baseRefName' 2>/dev/null || true)"
  fi
  [ -n "$BASE" ] || finish failed "::warning::could not look up the base branch; not merging it before the fix."
  # checkout は資格情報を残していないので fetch せず、checkout が取った origin/BASE とマージする。
  # push 時に push-agent-fix が最新の base をもう一度マージする。
  "${GIT_CMD}" rev-parse --verify -q "origin/${BASE}" >/dev/null \
    || finish failed "::warning::origin/${BASE} is not fetched; not merging it before the fix."

  "${GIT_CMD}" config user.name "$GIT_USER_NAME"
  "${GIT_CMD}" config user.email "$GIT_USER_EMAIL"
  if "${GIT_CMD}" merge --no-commit --no-ff "origin/${BASE}"; then
    "${GIT_CMD}" merge --abort
    finish clean "origin/${BASE} merges cleanly; push-agent-fix merges it at push time."
  fi

  local files file
  files="$("${GIT_CMD}" diff --name-only --diff-filter=U)"
  if [ -z "$files" ]; then
    "${GIT_CMD}" merge --abort || true
    finish failed "::warning::merging origin/${BASE} failed without conflicted files; not merging it before the fix."
  fi
  while IFS= read -r file; do
    if is_restored_path "$file"; then
      "${GIT_CMD}" merge --abort
      finish unresolvable "${file} conflicted, but claude-code-action overwrites it from the base; leaving it to a human."
    fi
  done <<<"$files"

  local base_sha tree
  base_sha="$("${GIT_CMD}" rev-parse MERGE_HEAD)"
  "${GIT_CMD}" add -A
  tree="$("${GIT_CMD}" write-tree)"
  "${GIT_CMD}" merge --quit
  {
    echo "base=${BASE}"
    echo "base-sha=${base_sha}"
    echo "tree=${tree}"
    echo "files<<__FILES__"
    printf '%s\n' "$files"
    echo "__FILES__"
  } >> "$GITHUB_OUTPUT"
  echo "Merging origin/${BASE} conflicted in:"
  sed 's/^/  /' <<<"$files"
  finish conflicted "Left conflict markers for the agent to resolve."
}

finish_merge() {
  : "${BASE_SHA:?BASE_SHA is required}"
  : "${TREE:?TREE is required}"
  : "${FILES:?FILES is required}"

  # マージコミットに解消以外を混ぜないよう、コンフリクトしていないパスの変更は start の木に戻す。
  # claude-code-action が base の内容で上書きした設定もここで戻る。
  local file
  "${GIT_CMD}" add -A
  while IFS= read -r -d '' file; do
    if printf '%s\n' "$FILES" | grep -qxF -- "$file"; then
      continue
    fi
    if "${GIT_CMD}" cat-file -e "${TREE}:${file}" 2>/dev/null; then
      "${GIT_CMD}" checkout "$TREE" -- "$file"
    else
      "${GIT_CMD}" rm -q --cached -- "$file"
      rm -f -- "$file"
    fi
  done < <("${GIT_CMD}" diff --cached --name-only --no-renames -z "$TREE")

  local unresolved=""
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    # ======= は Markdown などの本文にも現れるので、両端のマーカーだけを見る。
    if [ -f "$file" ] && grep -qE '^(<<<<<<<|>>>>>>>)( |$)' -- "$file"; then
      unresolved="${unresolved}${file} "
    fi
  done <<<"$FILES"
  if [ -n "$unresolved" ]; then
    finish unresolved "::warning::conflict markers remain in: ${unresolved% }"
  fi

  local tree merge_sha
  "${GIT_CMD}" add -A
  tree="$("${GIT_CMD}" write-tree)"
  "${GIT_CMD}" config user.name "$GIT_USER_NAME"
  "${GIT_CMD}" config user.email "$GIT_USER_EMAIL"
  merge_sha="$("${GIT_CMD}" commit-tree "$tree" -p HEAD -p "$BASE_SHA" -m "Merge ${BASE:-base} into ${REF:-HEAD}")"
  "${GIT_CMD}" reset -q --hard "$merge_sha"
  echo "merge-sha=${merge_sha}" >> "$GITHUB_OUTPUT"
  finish resolved "Committed the resolved merge ${merge_sha}."
}

case "$MODE" in
  start) start ;;
  finish) finish_merge ;;
  *) echo "::error::MODE は start / finish (got: ${MODE})"; exit 1 ;;
esac
