#!/usr/bin/env bash
# 作り直しの対象になるファイル (エージェントの編集と、PR があればその変更ファイル) を 1 行 1 パスで書き出し、
# そのパスを GITHUB_OUTPUT に path として出す。actions/agent-regen から呼ばれ、作り直しのコマンドは
# REGEN_FILES でこの一覧を受け取って作り直す範囲を絞れる。
#
# PR の変更ファイルも含めるのは、lint 落ちの原因が PR 自体の変更 (前回の push) にあると、エージェントの
# 編集だけでは作り直す範囲が決まらないため。
#
# 入力 (環境変数):
#   PR            - 既存 PR の番号 (任意。空ならエージェントの編集だけ)
#   REPO          - owner/name (PR があるとき)
#   GH_TOKEN      - PR の変更ファイル取得用。PR のコードを実行する作り直しのステップには渡さない
#   GITHUB_OUTPUT - 出力先
#   GIT_CMD / GH_CMD - テストで git / gh を差し替える (既定: git / gh)
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
GIT_CMD="${GIT_CMD:-git}"
GH_CMD="${GH_CMD:-gh}"

out="${RUNNER_TEMP:-/tmp}/agent-regen-files.txt"
{
  "${GIT_CMD}" diff --name-only HEAD
  "${GIT_CMD}" ls-files --others --exclude-standard
  if [ -n "${PR:-}" ]; then
    : "${REPO:?REPO is required}"
    # gh pr diff は差分が大きいと失敗するため、ファイル一覧 API を引く。
    "${GH_CMD}" api --paginate "repos/${REPO}/pulls/${PR}/files" --jq '.[].filename'
  fi
} | awk 'NF && !seen[$0]++' > "${out}"
echo "path=${out}" >> "${GITHUB_OUTPUT}"
