#!/usr/bin/env bash
# エージェントの編集後に lockfile / 生成物の作り直しが要るかを GITHUB_OUTPUT に needs_regen=true|false で書く。
# actions/agent-regen から呼ばれる。
#
# 生成元はリポジトリごとに違いパスで列挙しきれないため、エージェント自身の申告 (構造化出力の
# needs_regen) を見る。lockfile が要るかは package.json / pnpm-workspace.yaml の変更で確実に分かるので、
# 申告に関係なく拾う。CI の失敗ログに lockfile の不一致か生成物の差分 (`git diff --exit-code` の出力) が
# あれば、申告漏れに備えて申告に関係なく作り直す。
#
# 入力 (環境変数):
#   STRUCTURED    - エージェントの structured_output (JSON 文字列)
#   CI_FAILURE    - 自動修正のきっかけになった CI 失敗ログ (任意)
#   GITHUB_OUTPUT - 出力先
#   GIT_CMD       - テストで git を差し替える (既定: git)
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
GIT_CMD="${GIT_CMD:-git}"

changed_files() {
  "${GIT_CMD}" diff --name-only HEAD
  "${GIT_CMD}" ls-files --others --exclude-standard
}

needs=false
if [ "$(printf '%s' "${STRUCTURED:-}" | jq -r '.needs_regen == true' 2>/dev/null || echo false)" = "true" ]; then
  needs=true
  echo "agent reported needs_regen."
# job ログの各行には実行時刻が前置されるため、行頭だけでなく時刻の直後の diff --git も拾う。
elif printf '%s\n' "${CI_FAILURE:-}" | grep -qE 'ERR_PNPM_OUTDATED_LOCKFILE|(^|Z )diff --git a/'; then
  needs=true
  echo "CI failed on an outdated lockfile or generated outputs."
else
  while IFS= read -r f; do
    case "$f" in
      package.json | */package.json | pnpm-workspace.yaml)
        needs=true
        echo "lockfile input changed: ${f}"
        break
        ;;
    esac
  done < <(changed_files)
fi
echo "needs_regen=${needs}" >> "${GITHUB_OUTPUT}"
