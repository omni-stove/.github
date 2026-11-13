#!/usr/bin/env bash
# HEAD から遡って自動修正コミット (件名が COMMIT_PREFIX で始まる) が連続している数を数え、
# MAX_CONSECUTIVE 以上なら skip=true を出す (修正 → push → 再 CI の無限ループ防止)。
# 人間のコミットが挟まれば数え直しになる。actions/fix-context から呼ばれる。
# PR ブランチの first-parent をマージコミットを飛ばして数えるので、base のマージだけでは数え直しにならない。
#
# 入力 (環境変数):
#   MAX_CONSECUTIVE - 連続上限 (既定: 3)
#   COMMIT_PREFIX   - 自動修正コミットの件名の接頭辞 (既定: [agent-fix])
#   GIT_CMD         - git コマンド名 (既定: git)
#   GITHUB_OUTPUT   - 出力先 (skip / count)
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

MAX_CONSECUTIVE="${MAX_CONSECUTIVE:-3}"
COMMIT_PREFIX="${COMMIT_PREFIX:-[agent-fix]}"
GIT_CMD="${GIT_CMD:-git}"

count=0
while IFS= read -r subject; do
  case "$subject" in
    "$COMMIT_PREFIX"*) count=$((count + 1)) ;;
    *) break ;;
  esac
# 自動修正は毎回 base のマージの上に積まれるため、マージコミットで止めると連続が途切れて上限に届かない。
done < <("${GIT_CMD}" log --first-parent --no-merges -n "$MAX_CONSECUTIVE" --pretty=%s)

echo "consecutive ${COMMIT_PREFIX} commits: ${count} (max: ${MAX_CONSECUTIVE})"
echo "count=${count}" >> "$GITHUB_OUTPUT"
if [ "$count" -ge "$MAX_CONSECUTIVE" ]; then
  echo "skip=true" >> "$GITHUB_OUTPUT"
else
  echo "skip=false" >> "$GITHUB_OUTPUT"
fi
