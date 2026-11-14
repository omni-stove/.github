#!/usr/bin/env bash
# CI Gate を通った head に base をマージしてコンフリクトを解消しただけの push かを判定する。
# actions/check-conflict-resolution から呼ばれる。true なら precheck.yml が後続の CI を飛ばす。
#
# 次の全てを満たすときだけ only=true にし、それ以外と判定の途中の失敗は false (CI を回す) に倒す:
#   - HEAD がマージコミットで、第 1 親が push 前の head (BEFORE)、第 2 親が origin/BASE に含まれる
#   - 2 つの親の自動マージがコンフリクトし、HEAD がその結果と変えているのはコンフリクトしたパスだけ
#     (きれいにマージできる base の取り込みは解消ではなく、まだ誰も検証していない組み合わせなので回す)
#   - 解消したパスにコンフリクトのマーカーが残っていない
#   - BEFORE の CI Gate のチェックが success
#
# 入力 (環境変数):
#   BEFORE         - push 前の head (github.event.before)
#   HEAD_SHA       - push 後の head。checkout 済みで、origin/BASE と全履歴が取れていること
#   BASE           - base ブランチ名
#   REPO           - owner/name (チェックを引く)
#   CHECK_NAME     - CI Gate のチェック名 (既定: CI Gate。"<job> / CI Gate" も一致する)
#   GIT_CMD / GH_CMD - コマンド名 (既定: git / gh)
#   GITHUB_OUTPUT  - 出力先 (only=true | false)
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

GIT_CMD="${GIT_CMD:-git}"
GH_CMD="${GH_CMD:-gh}"
CHECK_NAME="${CHECK_NAME:-CI Gate}"

result() {
  echo "only=$1" >> "$GITHUB_OUTPUT"
  echo "$2"
  exit 0
}

run_ci() {
  result false "$1; running CI."
}

[ -n "${BEFORE:-}" ] && [ -n "${HEAD_SHA:-}" ] && [ -n "${BASE:-}" ] && [ -n "${REPO:-}" ] \
  || run_ci "BEFORE / HEAD_SHA / BASE / REPO is missing"
[[ "$BEFORE" =~ ^0+$ ]] && run_ci "no previous head"

read -r _ p1 p2 extra <<<"$("${GIT_CMD}" rev-list --parents -n 1 "$HEAD_SHA" 2>/dev/null || true)"
[ -n "${p2:-}" ] && [ -z "${extra:-}" ] || run_ci "HEAD is not a two-parent merge"
[ "$p1" = "$("${GIT_CMD}" rev-parse -q --verify "${BEFORE}^{commit}" 2>/dev/null || true)" ] \
  || run_ci "the first parent of HEAD is not the previous head ${BEFORE}"
"${GIT_CMD}" merge-base --is-ancestor "$p2" "origin/${BASE}" 2>/dev/null \
  || run_ci "the second parent of HEAD is not on origin/${BASE}"

status=0
merged="$("${GIT_CMD}" merge-tree --write-tree --name-only --no-messages "$p1" "$p2")" || status=$?
case "$status" in
  0) run_ci "the base merges cleanly, so the merge is not a conflict resolution" ;;
  1) ;;
  *) run_ci "git merge-tree failed" ;;
esac
auto_tree="$(head -n 1 <<<"$merged")"
conflicted="$(tail -n +2 <<<"$merged" | sed '/^$/d' | sort -u)"
[ -n "$conflicted" ] || run_ci "git merge-tree reported no conflicted paths"

changed="$("${GIT_CMD}" diff --name-only --no-renames "$auto_tree" "${HEAD_SHA}^{tree}" | sort -u)"
outside="$(comm -23 <(printf '%s\n' "$changed") <(printf '%s\n' "$conflicted") | sed '/^$/d')"
[ -z "$outside" ] || run_ci "the merge changes paths that did not conflict: $(paste -sd ' ' - <<<"$outside")"

while IFS= read -r file; do
  # ======= は Markdown などの本文にも現れるので、両端のマーカーだけを見る。
  if "${GIT_CMD}" cat-file -e "${HEAD_SHA}:${file}" 2>/dev/null \
    && "${GIT_CMD}" cat-file -p "${HEAD_SHA}:${file}" | grep -qE '^(<<<<<<<|>>>>>>>)( |$)'; then
    run_ci "conflict markers remain in ${file}"
  fi
done <<<"$conflicted"

# filter=latest (既定) で同名のチェックは最新の 1 件になる。再実行で通ったものを拾うため。
conclusions="$("${GH_CMD}" api "repos/${REPO}/commits/${BEFORE}/check-runs?per_page=100" \
  --jq "[.check_runs[] | select(.name == \"${CHECK_NAME}\" or (.name | endswith(\" / ${CHECK_NAME}\"))) | .conclusion // \"pending\"] | join(\" \")" \
  2>/dev/null)" || run_ci "could not read the checks of ${BEFORE}"
[ -n "$conclusions" ] || run_ci "${BEFORE} has no ${CHECK_NAME} check"
for conclusion in $conclusions; do
  [ "$conclusion" = "success" ] || run_ci "${CHECK_NAME} of ${BEFORE} is ${conclusion}"
done

echo "Resolved conflicts in:"
sed 's/^/  /' <<<"$conflicted"
result true "HEAD only resolves the conflicts of merging origin/${BASE} into ${BEFORE}, whose ${CHECK_NAME} passed; skipping CI."
